import crypto from 'crypto';
import { SupabaseFeatureFlagRepository } from '../../repositories/featureFlagRepository.js';
import { FeatureFlagService } from '../../services/featureFlagService.js';
import { supabase } from '../../utils/supabase.js';
import { assertLivePayoutActivationConfigured, configuredPayoutAdapter } from './payoutAdapters.js';
import { PayoutAdapter, PayoutSubmissionCommand, ProviderPayoutResult } from './payoutTypes.js';

interface CreatePayoutInput {
  withdrawalRequestId: string;
  organizationId: string;
  actorId: string;
  correlationId: string;
  internalReference: string;
  amountMinor: number;
  feeAmountMinor: number;
  accountNumber: string;
  bankCode: string;
  accountName: string;
}

const sha256 = (value: string | Buffer): string => crypto.createHash('sha256').update(value).digest('hex');
const maskedAccount = (accountNumber: string): string => `******${accountNumber.slice(-4)}`;

const publicPayout = (payout: any) => ({
  id: payout.id,
  internalReference: payout.internal_reference,
  provider: payout.provider_name,
  providerEnvironment: payout.provider_environment,
  providerReference: payout.provider_reference,
  amountMinor: Number(payout.amount_minor),
  feeAmountMinor: Number(payout.fee_amount_minor),
  currency: payout.currency,
  beneficiary: payout.beneficiary_masked,
  state: payout.state,
  failureCode: payout.failure_code,
  createdAt: payout.created_at,
  updatedAt: payout.updated_at,
});

export class PayoutService {
  constructor(
    private readonly adapterFactory: () => PayoutAdapter = configuredPayoutAdapter,
    private readonly featureFlags = new FeatureFlagService(new SupabaseFeatureFlagRepository()),
  ) {}

  private async assertLiveRoutingEnabled(adapter: PayoutAdapter, organizationId: string, actorId?: string): Promise<void> {
    if (adapter.environment !== 'live') return;
    assertLivePayoutActivationConfigured();
    const runtimeEnvironment = process.env.NODE_ENV;
    const environment = runtimeEnvironment === 'production' || runtimeEnvironment === 'staging' || runtimeEnvironment === 'test'
      ? runtimeEnvironment
      : 'development';
    const decision = await this.featureFlags.evaluate('integration.interswitch.live', {
      environment,
      tenantId: organizationId,
      actorId,
    });
    if (!decision.enabled) throw new Error('Live payout provider is disabled for this organization');
  }

  async validateDestination(organizationId: string, actorId: string, accountNumber: string, bankCode: string) {
    const adapter = this.adapterFactory();
    await this.assertLiveRoutingEnabled(adapter, organizationId, actorId);
    return adapter.validateDestination(accountNumber, bankCode);
  }

  async createAndSubmit(input: CreatePayoutInput) {
    const adapter = this.adapterFactory();
    await this.assertLiveRoutingEnabled(adapter, input.organizationId, input.actorId);
    const beneficiaryFingerprint = sha256(`${input.bankCode}:${input.accountNumber}`);
    const { data: payout, error } = await supabase.rpc('create_wallet_payout', {
      p_withdrawal_request_id: input.withdrawalRequestId,
      p_provider_name: adapter.name,
      p_provider_environment: adapter.environment,
      p_beneficiary_fingerprint: beneficiaryFingerprint,
      p_beneficiary_masked: maskedAccount(input.accountNumber),
      p_correlation_id: input.correlationId,
      p_actor_id: input.actorId,
    });
    if (error || !payout) throw error ?? new Error('Payout could not be created');
    if (payout.state !== 'reserved') return publicPayout(payout);

    const command: PayoutSubmissionCommand = {
      internalReference: input.internalReference,
      amountMinor: input.amountMinor,
      currency: 'NGN',
      narration: `Micro Fams payout ${input.internalReference}`,
      destination: {
        accountNumber: input.accountNumber,
        bankCode: input.bankCode,
        accountName: input.accountName,
      },
    };
    const requestHash = sha256(JSON.stringify({
      internalReference: command.internalReference,
      amountMinor: command.amountMinor,
      currency: command.currency,
      beneficiaryFingerprint,
      provider: adapter.name,
      environment: adapter.environment,
    }));

    let result: ProviderPayoutResult;
    try {
      result = await adapter.submit(command);
    } catch {
      const pending = await this.markSubmitted(payout.id, requestHash, undefined, true);
      return publicPayout(pending);
    }
    return this.applyProviderResult(payout.id, requestHash, result);
  }

  async ingestWebhook(rawBody: Buffer, signature: string) {
    const adapter = this.adapterFactory();
    const event = adapter.verifyAndParseWebhook(rawBody, signature);
    const { data: payout, error: payoutError } = await supabase
      .from('payouts')
      .select('*')
      .eq('provider_name', adapter.name)
      .eq('provider_environment', adapter.environment)
      .eq('internal_reference', event.internalReference)
      .single();
    if (payoutError || !payout) throw new Error('Provider event payout was not found');

    const eventHash = sha256(rawBody);
    const { data: storedEvent, error: eventError } = await supabase.rpc('record_provider_event', {
      p_organization_id: payout.organization_id,
      p_payout_id: payout.id,
      p_provider_name: adapter.name,
      p_provider_environment: adapter.environment,
      p_provider_event_id: event.providerEventId ?? null,
      p_event_type: event.eventType,
      p_raw_event_hash: eventHash,
      p_normalized_payload: {
        internalReference: event.internalReference,
        providerReference: event.providerReference,
        status: event.status,
        amountMinor: event.amountMinor,
        currency: event.currency,
        occurredAt: event.occurredAt,
      },
      p_occurred_at: event.occurredAt ?? null,
    });
    if (eventError || !storedEvent) throw eventError ?? new Error('Provider event could not be recorded');
    return {
      eventId: storedEvent.id,
      processingState: storedEvent.processing_state,
      duplicate: storedEvent.processing_state !== 'received',
    };
  }

  async processProviderEvent(eventId: string) {
    const { data: event, error } = await supabase
      .from('provider_events')
      .select('*, payouts!inner(*)')
      .eq('id', eventId)
      .single();
    if (error || !event) throw new Error('Provider event not found');
    if (event.processing_state === 'processed') return publicPayout(event.payouts);
    if (event.processing_state !== 'received') throw new Error('Provider event is not processable');
    const payload = event.normalized_payload;
    const amountMinor = Number(payload.amountMinor);
    if (!Number.isSafeInteger(amountMinor) || amountMinor <= 0 || payload.currency !== 'NGN') {
      throw new Error('Stored provider event money is invalid');
    }
    const updated = await this.applyProviderResult(event.payout_id, event.raw_event_hash, {
      providerReference: payload.providerReference,
      status: payload.status,
      amountMinor,
      currency: payload.currency,
    });
    const { error: finishError } = await supabase.rpc('finish_provider_event', {
      p_event_id: event.id,
      p_state: 'processed',
      p_rejection_reason: null,
    });
    if (finishError) throw finishError;
    return updated;
  }

  async queryAndApply(payoutId: string) {
    const { data: payout, error } = await supabase.from('payouts').select('*').eq('id', payoutId).single();
    if (error || !payout) throw new Error('Payout not found');
    if (!['submitted', 'processing'].includes(payout.state)) return publicPayout(payout);
    const adapter = this.adapterFactory();
    if (adapter.name !== payout.provider_name || adapter.environment !== payout.provider_environment) {
      throw new Error('Configured payout adapter does not match the stored payout');
    }
    const result = await adapter.query(payout.internal_reference);
    return this.applyProviderResult(payout.id, sha256(`query:${payout.id}:${result.status}`), result);
  }

  private async applyProviderResult(payoutId: string, requestHash: string, result: ProviderPayoutResult) {
    if (result.status === 'failed') {
      const submitted = await this.markSubmitted(payoutId, requestHash, result.providerReference, false);
      const { data, error } = await supabase.rpc('fail_wallet_payout', {
        p_payout_id: submitted.id,
        p_failure_code: result.failureCode ?? 'PROVIDER_FAILED',
        p_failure_reason: result.failureReason ?? 'Provider reported payout failure',
      });
      if (error || !data) throw error ?? new Error('Payout failure could not be applied');
      return publicPayout(data);
    }

    const submitted = await this.markSubmitted(
      payoutId,
      requestHash,
      result.providerReference,
      result.status === 'processing',
    );
    if (result.status !== 'succeeded') return publicPayout(submitted);
    const { data, error } = await supabase.rpc('succeed_wallet_payout', {
      p_payout_id: submitted.id,
      p_provider_reference: result.providerReference ?? submitted.provider_reference ?? submitted.internal_reference,
      p_amount_minor: result.amountMinor,
      p_currency: result.currency,
    });
    if (error || !data) throw error ?? new Error('Payout success could not be applied');
    return publicPayout(data);
  }

  private async markSubmitted(
    payoutId: string,
    requestHash: string,
    providerReference: string | undefined,
    processing: boolean,
  ) {
    const { data, error } = await supabase.rpc('mark_payout_submitted', {
      p_payout_id: payoutId,
      p_request_hash: requestHash,
      p_provider_reference: providerReference ?? null,
      p_processing: processing,
    });
    if (error || !data) throw error ?? new Error('Payout submission state could not be recorded');
    return data;
  }
}

export const payoutService = new PayoutService();
