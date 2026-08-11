import crypto from 'crypto';
import { SupabaseFeatureFlagRepository } from '../../repositories/featureFlagRepository.js';
import { FeatureFlagService } from '../../services/featureFlagService.js';
import { supabase } from '../../utils/supabase.js';
import { assertLivePayoutActivationConfigured, configuredPayoutAdapter } from './payoutAdapters.js';
import { PayoutAdapter, PayoutSubmissionCommand, ProviderPayoutResult } from './payoutTypes.js';
import { financialRuleService } from './financialRuleService.js';

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

// The shared payout stack settles three sources through the same provider
// transition graph; only the terminal-posting function differs per source. A
// wallet withdrawal posts with a short parameter set; a booking settlement and a
// group treasury external disbursement each revalidate the full provider
// identity, so they share the wider success signature.
const SUCCESS_FUNCTIONS: Record<string, string> = {
  booking_settlement: 'succeed_booking_supplier_payout',
  group_treasury: 'succeed_group_treasury_payout',
  loan_disbursement: 'succeed_loan_disbursement_payout',
  wallet_withdrawal: 'succeed_wallet_payout',
};
const FAILURE_FUNCTIONS: Record<string, string> = {
  booking_settlement: 'fail_booking_supplier_payout',
  group_treasury: 'fail_group_treasury_payout',
  loan_disbursement: 'fail_loan_disbursement_payout',
  wallet_withdrawal: 'fail_wallet_payout',
};
const FULL_SUCCESS_SHAPE = new Set([
  'booking_settlement', 'group_treasury', 'loan_disbursement',
]);

export class PayoutService {
  constructor(
    private readonly adapterFactory: () => PayoutAdapter = configuredPayoutAdapter,
    private readonly featureFlags = new FeatureFlagService(new SupabaseFeatureFlagRepository()),
  ) {}

  async assertRoutingEnabled(
    adapter: PayoutAdapter,
    organizationId: string,
    actorId?: string,
  ): Promise<void> {
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
    await this.assertRoutingEnabled(adapter, organizationId, actorId);
    return adapter.validateDestination(accountNumber, bankCode);
  }

  async createAndSubmit(input: CreatePayoutInput) {
    const adapter = this.adapterFactory();
    await this.assertRoutingEnabled(adapter, input.organizationId, input.actorId);
    const beneficiaryFingerprint = sha256(`${input.bankCode}:${input.accountNumber}`);
    await financialRuleService.enforce({
      organizationId: input.organizationId,
      actorId: input.actorId,
      commandType: 'payout.submit',
      commandId: input.internalReference,
      product: 'payouts',
      channel: 'bank_transfer',
      amountMinor: input.amountMinor,
      currency: 'NGN',
      beneficiaryFingerprint,
    });
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

  async submitBookingPayout(input: {
    payout: any;
    organizationId: string;
    actorId: string;
    accountNumber: string;
    bankCode: string;
    accountName: string;
  }) {
    const adapter = this.adapterFactory();
    await this.assertRoutingEnabled(adapter, input.organizationId, input.actorId);
    if (adapter.name !== input.payout.provider_name
      || adapter.environment !== input.payout.provider_environment
    ) throw new Error('Configured payout adapter does not match the stored payout');
    if (input.payout.state !== 'reserved') return publicPayout(input.payout);

    const command: PayoutSubmissionCommand = {
      internalReference: input.payout.internal_reference,
      amountMinor: Number(input.payout.amount_minor),
      currency: input.payout.currency,
      narration: `Micro Fams booking supplier payout ${input.payout.internal_reference}`,
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
      beneficiaryFingerprint: input.payout.beneficiary_fingerprint,
      provider: adapter.name,
      environment: adapter.environment,
    }));
    let result: ProviderPayoutResult;
    try {
      result = await adapter.submit(command);
    } catch {
      const pending = await this.markSubmitted(
        input.payout.id,
        requestHash,
        undefined,
        true,
      );
      return publicPayout(pending);
    }
    return this.applyProviderResult(input.payout.id, requestHash, result);
  }

  // GT-06B: submit a reserved group treasury payout to the provider. Identical
  // in shape to a booking supplier submission — the shared adapter is source-
  // agnostic — but a provider that never answers leaves the payout in
  // 'processing' with the reservation still active, which is the timeout the
  // sync and webhook paths later resolve rather than a lost disbursement.
  async submitGroupTreasuryPayout(input: {
    payout: any;
    organizationId: string;
    actorId: string;
    accountNumber: string;
    bankCode: string;
    accountName: string;
  }) {
    const adapter = this.adapterFactory();
    await this.assertRoutingEnabled(adapter, input.organizationId, input.actorId);
    if (adapter.name !== input.payout.provider_name
      || adapter.environment !== input.payout.provider_environment
    ) throw new Error('Configured payout adapter does not match the stored payout');
    if (input.payout.state !== 'reserved') return publicPayout(input.payout);

    const command: PayoutSubmissionCommand = {
      internalReference: input.payout.internal_reference,
      amountMinor: Number(input.payout.amount_minor),
      currency: input.payout.currency,
      narration: `Micro Fams group treasury payout ${input.payout.internal_reference}`,
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
      beneficiaryFingerprint: input.payout.beneficiary_fingerprint,
      provider: adapter.name,
      environment: adapter.environment,
    }));
    let result: ProviderPayoutResult;
    try {
      result = await adapter.submit(command);
    } catch {
      const pending = await this.markSubmitted(
        input.payout.id,
        requestHash,
        undefined,
        true,
      );
      return publicPayout(pending);
    }
    return this.applyProviderResult(input.payout.id, requestHash, result);
  }

  // CRD-05 uses the same provider state machine but posts the loan receivable
  // only in its loan-specific confirmed-success database function.
  async submitLoanDisbursementPayout(input: {
    payout: any;
    organizationId: string;
    actorId: string;
    destination: PayoutSubmissionCommand['destination'];
  }) {
    const adapter = this.adapterFactory();
    await this.assertRoutingEnabled(adapter, input.organizationId, input.actorId);
    if (adapter.name !== input.payout.provider_name
      || adapter.environment !== input.payout.provider_environment
    ) throw new Error('Configured payout adapter does not match the stored payout');
    if (input.payout.source_type !== 'loan_disbursement') {
      throw new Error('Stored payout is not a loan disbursement');
    }
    if (input.payout.state !== 'reserved') return publicPayout(input.payout);

    const command: PayoutSubmissionCommand = {
      internalReference: input.payout.internal_reference,
      amountMinor: Number(input.payout.amount_minor),
      currency: input.payout.currency,
      narration: `Micro Fams loan disbursement ${input.payout.internal_reference}`,
      destination: input.destination,
    };
    const requestHash = sha256(JSON.stringify({
      internalReference: command.internalReference,
      amountMinor: command.amountMinor,
      currency: command.currency,
      beneficiaryFingerprint: input.payout.beneficiary_fingerprint,
      provider: adapter.name,
      environment: adapter.environment,
    }));
    let result: ProviderPayoutResult;
    try {
      result = await adapter.submit(command);
    } catch {
      const pending = await this.markSubmitted(
        input.payout.id, requestHash, undefined, true,
      );
      return publicPayout(pending);
    }
    return this.applyProviderResult(input.payout.id, requestHash, result);
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
    if (result.status === 'succeeded') {
      const lateSuccess = await this.recordLateSuccess(payoutId, requestHash, result);
      if (lateSuccess) return lateSuccess;
    }
    if (result.status === 'failed') {
      const submitted = await this.markSubmitted(payoutId, requestHash, result.providerReference, false);
      const failureFunction = FAILURE_FUNCTIONS[submitted.source_type] ?? 'fail_wallet_payout';
      const { data, error } = await supabase.rpc(failureFunction, {
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
    const providerReference = result.providerReference
      ?? submitted.provider_reference
      ?? submitted.internal_reference;
    const successCommand = FULL_SUCCESS_SHAPE.has(submitted.source_type)
      ? {
        p_payout_id: submitted.id,
        p_internal_reference: submitted.internal_reference,
        p_provider_reference: providerReference,
        p_amount_minor: result.amountMinor,
        p_currency: result.currency,
        p_beneficiary_fingerprint: submitted.beneficiary_fingerprint,
        p_organization_id: submitted.organization_id,
        p_provider_name: submitted.provider_name,
        p_provider_environment: submitted.provider_environment,
      }
      : {
        p_payout_id: submitted.id,
        p_provider_reference: providerReference,
        p_amount_minor: result.amountMinor,
        p_currency: result.currency,
      };
    const successFunction = SUCCESS_FUNCTIONS[submitted.source_type] ?? 'succeed_wallet_payout';
    const { data, error } = await supabase.rpc(successFunction, successCommand);
    if (error || !data) throw error ?? new Error('Payout success could not be applied');
    return publicPayout(data);
  }

  // A provider that confirms success after the payout already reached a terminal
  // failed/cancelled state is a reconciliation exception, never a replayed
  // disbursement. Booking and group treasury each own a "record without
  // repaying" function; a wallet withdrawal has none, so the caller falls
  // through to the normal success path.
  private async recordLateSuccess(
    payoutId: string,
    requestHash: string,
    result: ProviderPayoutResult,
  ) {
    const { data: payout, error: payoutError } = await supabase
      .from('payouts')
      .select('*')
      .eq('id', payoutId)
      .single();
    if (payoutError || !payout) {
      throw payoutError ?? new Error('Payout not found');
    }
    if (!['failed', 'cancelled'].includes(payout.state)) return null;
    if (payout.source_type === 'booking_settlement') {
      return this.recordLateBookingSuccess(payout, requestHash, result);
    }
    if (payout.source_type === 'group_treasury') {
      return this.recordLateGroupTreasurySuccess(payout, requestHash, result);
    }
    if (payout.source_type === 'loan_disbursement') {
      return this.recordLateLoanDisbursementSuccess(payout, requestHash, result);
    }
    return null;
  }

  private async recordLateBookingSuccess(
    payout: any,
    requestHash: string,
    result: ProviderPayoutResult,
  ) {
    const providerReference = result.providerReference
      ?? payout.provider_reference;
    if (!providerReference) {
      throw new Error('Late booking payout success requires a provider reference');
    }
    const { data: exception, error } = await supabase.rpc(
      'record_booking_late_payout_success',
      {
        p_payout_id: payout.id,
        p_organization_id: payout.organization_id,
        p_provider_reference: providerReference,
        p_amount_minor: result.amountMinor,
        p_currency: result.currency,
        p_beneficiary_fingerprint: payout.beneficiary_fingerprint,
        p_provider_name: payout.provider_name,
        p_provider_environment: payout.provider_environment,
        p_evidence_snapshot: {
          source: 'provider_result',
          status: result.status,
          request_hash: requestHash,
          failure_code: payout.failure_code,
          observed_at: new Date().toISOString(),
        },
      },
    );
    if (error || !exception) {
      throw error ?? new Error('Late booking payout success could not be recorded');
    }
    return {
      ...publicPayout(payout),
      lateSuccessExceptionId: exception.id,
      reconciliationRequired: true,
    };
  }

  private async recordLateGroupTreasurySuccess(
    payout: any,
    requestHash: string,
    result: ProviderPayoutResult,
  ) {
    const providerReference = result.providerReference
      ?? payout.provider_reference;
    if (!providerReference) {
      throw new Error('Late group treasury payout success requires a provider reference');
    }
    const { data: exception, error } = await supabase.rpc(
      'record_group_treasury_late_payout_success',
      {
        p_payout_id: payout.id,
        p_organization_id: payout.organization_id,
        p_provider_reference: providerReference,
        p_amount_minor: result.amountMinor,
        p_currency: result.currency,
        p_beneficiary_fingerprint: payout.beneficiary_fingerprint,
        p_provider_name: payout.provider_name,
        p_provider_environment: payout.provider_environment,
        p_evidence_snapshot: {
          source: 'provider_result',
          status: result.status,
          request_hash: requestHash,
          failure_code: payout.failure_code,
          observed_at: new Date().toISOString(),
        },
      },
    );
    if (error || !exception) {
      throw error ?? new Error('Late group treasury payout success could not be recorded');
    }
    return {
      ...publicPayout(payout),
      lateSuccessExceptionId: exception.id,
      reconciliationRequired: true,
    };
  }

  private async recordLateLoanDisbursementSuccess(
    payout: any,
    requestHash: string,
    result: ProviderPayoutResult,
  ) {
    const providerReference = result.providerReference ?? payout.provider_reference;
    if (!providerReference) {
      throw new Error('Late loan disbursement success requires a provider reference');
    }
    const { data: exception, error } = await supabase.rpc(
      'record_loan_late_payout_success',
      {
        p_payout_id: payout.id,
        p_organization_id: payout.organization_id,
        p_provider_reference: providerReference,
        p_amount_minor: result.amountMinor,
        p_currency: result.currency,
        p_beneficiary_fingerprint: payout.beneficiary_fingerprint,
        p_provider_name: payout.provider_name,
        p_provider_environment: payout.provider_environment,
        p_evidence_snapshot: {
          source: 'provider_result',
          status: result.status,
          request_hash: requestHash,
          failure_code: payout.failure_code,
          observed_at: new Date().toISOString(),
        },
      },
    );
    if (error || !exception) {
      throw error ?? new Error('Late loan disbursement success could not be recorded');
    }
    return {
      ...publicPayout(payout),
      lateSuccessExceptionId: exception.id,
      reconciliationRequired: true,
    };
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
