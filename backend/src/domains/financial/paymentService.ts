import crypto from 'crypto';
import { BookingModel } from '../../models/Booking.js';
import { ContributionModel } from '../../models/Contribution.js';
import { GroupModel } from '../../models/Group.js';
import { SupabaseFeatureFlagRepository } from '../../repositories/featureFlagRepository.js';
import { ReceiptService } from '../../services/receiptService.js';
import { FeatureFlagService } from '../../services/featureFlagService.js';
import { supabase } from '../../utils/supabase.js';
import { logger } from '../../utils/logger.js';
import {
  assertLivePaymentActivationConfigured,
  configuredPaymentAdapter,
} from './paymentAdapters.js';
import {
  PaymentAdapter,
  ProviderPaymentResult,
  ProviderRefundResult,
} from './paymentTypes.js';
import { financialRuleService } from './financialRuleService.js';

type PaymentSourceType = 'booking' | 'marketplace_order' | 'wallet' | 'group_membership' | 'contribution';

interface InitializeInput {
  organizationId: string;
  sourceType: PaymentSourceType;
  sourceId: string;
  payerId: string;
  actorId: string;
  correlationId: string;
  internalReference: string;
  idempotencyKey: string;
  amountMinor: number;
  customerEmail: string;
  callbackUrl: string;
  metadata?: Record<string, string>;
}

interface BookingRetryInput {
  organizationId: string;
  bookingId: string;
  payerId: string;
  actorId: string;
  correlationId: string;
  internalReference: string;
  idempotencyKey: string;
  amountMinor: number;
  customerEmail: string;
  callbackUrl: string;
  maxRetries: number;
}

export interface PaymentRecoveryResult {
  processed: number;
  cancelled: number;
  deferred: number;
  errors: Array<{ paymentId: string; reason: string }>;
}

interface RefundInput {
  paymentId: string;
  organizationId: string;
  actorId: string;
  internalReference: string;
  idempotencyKey: string;
  amountMinor: number;
  reasonCode: string;
  reason: string;
  approvalReference?: string;
}

const sha256 = (value: string | Buffer): string =>
  crypto.createHash('sha256').update(value).digest('hex');

const publicPayment = (payment: any) => ({
  id: payment.id,
  organizationId: payment.organization_id,
  sourceType: payment.source_type,
  sourceId: payment.source_id,
  internalReference: payment.internal_reference,
  provider: payment.provider_name,
  providerEnvironment: payment.provider_environment,
  providerReference: payment.provider_reference,
  amountMinor: Number(payment.amount_minor),
  currency: payment.currency,
  state: payment.state,
  attemptNumber: Number(payment.attempt_number ?? 1),
  retryOfPaymentId: payment.retry_of_payment_id ?? null,
  failureCode: payment.failure_code,
  actionExpiresAt: payment.action_expires_at,
  createdAt: payment.created_at,
  updatedAt: payment.updated_at,
  authorizationUrl: undefined as string | undefined,
  accessCode: undefined as string | undefined,
  idempotencyReplay: false,
});

const publicRefund = (refund: any) => ({
  id: refund.id,
  paymentId: refund.payment_id,
  internalReference: refund.internal_reference,
  providerReference: refund.provider_reference,
  amountMinor: Number(refund.amount_minor),
  currency: refund.currency,
  state: refund.state,
  failureCode: refund.failure_code,
  createdAt: refund.created_at,
  updatedAt: refund.updated_at,
});

export class PaymentService {
  constructor(
    private readonly adapterFactory: () => PaymentAdapter = configuredPaymentAdapter,
    private readonly featureFlags = new FeatureFlagService(new SupabaseFeatureFlagRepository()),
  ) {}

  private async assertLiveRoutingEnabled(
    adapter: PaymentAdapter,
    organizationId: string,
    actorId?: string,
  ): Promise<void> {
    if (adapter.environment !== 'live') return;
    assertLivePaymentActivationConfigured();
    const runtime = process.env.NODE_ENV;
    const environment = runtime === 'production' || runtime === 'staging' || runtime === 'test'
      ? runtime
      : 'development';
    const decision = await this.featureFlags.evaluate('integration.paystack.live', {
      environment,
      tenantId: organizationId,
      actorId,
    });
    if (!decision.enabled) throw new Error('Live payment provider is disabled for this organization');
  }

  async createAndInitialize(input: InitializeInput) {
    if (!Number.isSafeInteger(input.amountMinor) || input.amountMinor <= 0) {
      throw new Error('Payment amount must be a positive safe integer in minor units');
    }
    const adapter = this.adapterFactory();
    await this.assertLiveRoutingEnabled(adapter, input.organizationId, input.actorId);
    await financialRuleService.enforce({
      organizationId: input.organizationId,
      actorId: input.actorId,
      commandType: 'payment.initialize',
      commandId: input.idempotencyKey,
      product: 'payments',
      channel: input.sourceType,
      amountMinor: input.amountMinor,
      currency: 'NGN',
    });
    const { data: payment, error } = await supabase.rpc('create_payment_intent', {
      p_organization_id: input.organizationId,
      p_source_type: input.sourceType,
      p_source_id: input.sourceId,
      p_payer_id: input.payerId,
      p_internal_reference: input.internalReference,
      p_idempotency_key: input.idempotencyKey,
      p_provider_name: adapter.name,
      p_provider_environment: adapter.environment,
      p_currency: 'NGN',
      p_amount_minor: input.amountMinor,
      p_correlation_id: input.correlationId,
      p_actor_id: input.actorId,
    });
    if (error || !payment) throw error ?? new Error('Payment intent could not be created');
    return this.initializeCreatedPayment(payment, input, adapter);
  }

  async retryBookingPayment(input: BookingRetryInput) {
    if (!Number.isSafeInteger(input.amountMinor) || input.amountMinor <= 0) {
      throw new Error('Payment amount must be a positive safe integer in minor units');
    }
    if (!Number.isInteger(input.maxRetries) || input.maxRetries < 0 || input.maxRetries > 20) {
      throw new Error('Payment retry policy is invalid');
    }
    const adapter = this.adapterFactory();
    await this.assertLiveRoutingEnabled(adapter, input.organizationId, input.actorId);
    await financialRuleService.enforce({
      organizationId: input.organizationId,
      actorId: input.actorId,
      commandType: 'payment.retry',
      commandId: input.idempotencyKey,
      product: 'payments',
      channel: 'booking',
      amountMinor: input.amountMinor,
      currency: 'NGN',
    });
    const { data: payment, error } = await supabase.rpc('create_booking_payment_retry', {
      p_organization_id: input.organizationId,
      p_booking_id: input.bookingId,
      p_payer_id: input.payerId,
      p_internal_reference: input.internalReference,
      p_idempotency_key: input.idempotencyKey,
      p_provider_name: adapter.name,
      p_provider_environment: adapter.environment,
      p_amount_minor: input.amountMinor,
      p_correlation_id: input.correlationId,
      p_actor_id: input.actorId,
      p_max_retries: input.maxRetries,
    });
    if (error || !payment) throw error ?? new Error('Booking payment retry could not be created');
    return this.initializeCreatedPayment(payment, {
      organizationId: input.organizationId,
      sourceType: 'booking',
      sourceId: input.bookingId,
      payerId: input.payerId,
      actorId: input.actorId,
      correlationId: input.correlationId,
      internalReference: input.internalReference,
      idempotencyKey: input.idempotencyKey,
      amountMinor: input.amountMinor,
      customerEmail: input.customerEmail,
      callbackUrl: input.callbackUrl,
      metadata: { booking_id: input.bookingId, recovery: 'retry' },
    }, adapter);
  }

  async recoverExpiredBookingPayments(limit = 100): Promise<PaymentRecoveryResult> {
    const safeLimit = Math.min(Math.max(Math.trunc(limit), 1), 500);
    const result: PaymentRecoveryResult = { processed: 0, cancelled: 0, deferred: 0, errors: [] };
    const { data: candidates, error } = await supabase
      .from('payments')
      .select('*')
      .eq('source_type', 'booking')
      .in('state', ['requires_action', 'processing', 'failed'])
      .not('action_expires_at', 'is', null)
      .lte('action_expires_at', new Date().toISOString())
      .order('action_expires_at', { ascending: true })
      .limit(safeLimit);
    if (error) throw error;

    for (const candidate of candidates ?? []) {
      result.processed += 1;
      let current = publicPayment(candidate);
      if (current.state === 'requires_action' || current.state === 'processing') {
        try {
          current = await this.queryAndApply(current.id);
        } catch (queryError) {
          result.deferred += 1;
          result.errors.push({
            paymentId: current.id,
            reason: queryError instanceof Error ? queryError.message : 'Provider status query failed',
          });
          continue;
        }
      }
      if (current.state === 'succeeded' || current.state === 'partially_refunded' || current.state === 'refunded') {
        continue;
      }
      if (current.state === 'processing') {
        result.deferred += 1;
        continue;
      }
      try {
        const { error: cancelError } = await supabase.rpc('cancel_expired_booking_payment', {
          p_payment_id: current.id,
        });
        if (cancelError) throw cancelError;
        result.cancelled += 1;
      } catch (cancelError) {
        result.errors.push({
          paymentId: current.id,
          reason: cancelError instanceof Error ? cancelError.message : 'Timeout cancellation failed',
        });
      }
    }
    return result;
  }

  async ingestWebhook(rawBody: Buffer, signature: string) {
    const adapter = this.adapterFactory();
    const event = adapter.verifyAndParseWebhook(rawBody, signature);
    const { data: payment, error: paymentError } = await supabase
      .from('payments')
      .select('*')
      .eq('provider_name', adapter.name)
      .eq('provider_environment', adapter.environment)
      .eq('internal_reference', event.internalReference)
      .single();
    if (paymentError || !payment) throw new Error('Provider event payment was not found');
    const { data: stored, error } = await supabase.rpc('record_payment_provider_event', {
      p_organization_id: payment.organization_id,
      p_payment_id: payment.id,
      p_provider_name: adapter.name,
      p_provider_environment: adapter.environment,
      p_provider_event_id: event.providerEventId ?? null,
      p_event_type: event.eventType,
      p_raw_event_hash: sha256(rawBody),
      p_normalized_payload: {
        internalReference: event.internalReference,
        providerReference: event.providerReference,
        status: event.status,
        amountMinor: event.amountMinor,
        currency: event.currency,
        occurredAt: event.occurredAt,
        failureCode: event.failureCode,
        failureReason: event.failureReason,
      },
      p_occurred_at: event.occurredAt ?? null,
    });
    if (error || !stored) throw error ?? new Error('Payment provider event could not be recorded');
    return {
      eventId: stored.id,
      processingState: stored.processing_state,
      duplicate: stored.processing_state !== 'received',
    };
  }

  async processProviderEvent(eventId: string) {
    const { data: event, error } = await supabase
      .from('payment_provider_events')
      .select('*, payments!inner(*)')
      .eq('id', eventId)
      .single();
    if (error || !event) throw new Error('Payment provider event not found');
    if (event.processing_state === 'processed') return publicPayment(event.payments);
    if (event.processing_state !== 'received') throw new Error('Payment provider event is not processable');
    const payload = event.normalized_payload;
    const amountMinor = Number(payload.amountMinor);
    if (!Number.isSafeInteger(amountMinor) || amountMinor <= 0 || payload.currency !== 'NGN') {
      throw new Error('Stored payment provider event money is invalid');
    }
    try {
      let updated: any;
      if (payload.status === 'reversed') {
        const { error: reversalError } = await supabase.rpc('reverse_inbound_payment', {
          p_payment_id: event.payment_id,
          p_provider_event_id: event.provider_event_id ?? event.raw_event_hash,
          p_internal_reference: `REV-${event.payment_id}-${event.id}`,
          p_amount_minor: amountMinor,
          p_reason: 'Provider reported payment reversal',
          p_occurred_at: payload.occurredAt ?? event.received_at,
        });
        if (reversalError) throw reversalError;
        updated = publicPayment(event.payments);
      } else {
        updated = await this.applyProviderResult(event.payment_id, payload);
        if (updated.state === 'succeeded') await this.fulfillSource(updated);
      }
      await this.finishEvent(event.id, 'processed');
      return updated;
    } catch (processingError) {
      const { data: current } = await supabase.from('payments')
        .select('state')
        .eq('id', event.payment_id)
        .single();
      if (!current || !['succeeded', 'partially_refunded', 'refunded'].includes(current.state)) {
        await this.finishEvent(
          event.id,
          'rejected',
          processingError instanceof Error ? processingError.message : 'Payment event processing failed',
        );
      }
      throw processingError;
    }
  }

  async queryAndApply(paymentId: string) {
    const { data: payment, error } = await supabase.from('payments').select('*').eq('id', paymentId).single();
    if (error || !payment) throw new Error('Payment not found');
    if (!['requires_action', 'processing'].includes(payment.state)) {
      const existing = publicPayment(payment);
      if (existing.state === 'succeeded') await this.fulfillSource(existing);
      return existing;
    }
    const adapter = this.adapterFactory();
    if (adapter.name !== payment.provider_name || adapter.environment !== payment.provider_environment) {
      throw new Error('Configured payment adapter does not match the stored payment');
    }
    const result = await adapter.query(payment.internal_reference);
    const updated = await this.applyProviderResult(payment.id, result);
    if (updated.state === 'succeeded') await this.fulfillSource(updated);
    return updated;
  }

  async requestRefund(input: RefundInput) {
    const { data: payment, error: paymentError } = await supabase
      .from('payments')
      .select('*')
      .eq('id', input.paymentId)
      .eq('organization_id', input.organizationId)
      .single();
    if (paymentError || !payment) throw new Error('Payment not found');
    const { data: refund, error } = await supabase.rpc('create_payment_refund', {
      p_payment_id: input.paymentId,
      p_internal_reference: input.internalReference,
      p_idempotency_key: input.idempotencyKey,
      p_amount_minor: input.amountMinor,
      p_reason_code: input.reasonCode,
      p_reason: input.reason,
      p_actor_id: input.actorId,
      p_approval_reference: input.approvalReference ?? null,
    });
    if (error || !refund) throw error ?? new Error('Refund could not be created');
    if (refund.state !== 'created') return publicRefund(refund);
    return this.submitRefund(refund.id, input.organizationId, input.actorId);
  }

  async submitRefund(refundId: string, organizationId: string, actorId?: string) {
    const { data: refund, error } = await supabase
      .from('payment_refunds')
      .select('*, payments!inner(*)')
      .eq('id', refundId)
      .eq('organization_id', organizationId)
      .single();
    if (error || !refund) throw new Error('Refund not found');
    if (refund.state !== 'created') return publicRefund(refund);
    const payment = refund.payments;
    const adapter = this.adapterFactory();
    if (adapter.name !== payment.provider_name || adapter.environment !== payment.provider_environment) {
      throw new Error('Configured payment adapter does not match the stored refund');
    }
    await this.assertLiveRoutingEnabled(adapter, organizationId, actorId);
    let result: ProviderRefundResult;
    try {
      result = await adapter.refund({
        internalReference: refund.internal_reference,
        providerPaymentReference: payment.provider_reference ?? payment.internal_reference,
        amountMinor: Number(refund.amount_minor),
        currency: refund.currency,
        reason: refund.reason,
      });
    } catch {
      result = { status: 'processing', amountMinor: Number(refund.amount_minor), currency: refund.currency };
    }
    if (result.amountMinor !== Number(refund.amount_minor) || result.currency !== refund.currency) {
      throw new Error('Payment provider refund money mismatch');
    }
    return this.applyRefundResult(refund.id, result);
  }

  async queryRefundAndApply(refundId: string) {
    const { data: refund, error } = await supabase
      .from('payment_refunds')
      .select('*, payments!inner(provider_name, provider_environment, provider_reference, internal_reference)')
      .eq('id', refundId)
      .single();
    if (error || !refund) throw new Error('Refund not found');
    if (!['submitted', 'processing'].includes(refund.state)) return publicRefund(refund);
    const adapter = this.adapterFactory();
    const payment = refund.payments;
    if (adapter.name !== payment.provider_name || adapter.environment !== payment.provider_environment) {
      throw new Error('Configured payment adapter does not match the stored refund');
    }
    let result: ProviderRefundResult | undefined;
    try {
      result = refund.provider_reference
        ? await adapter.queryRefund(refund.provider_reference)
        : await adapter.recoverRefund({
          internalReference: refund.internal_reference,
          providerPaymentReference: payment.provider_reference ?? payment.internal_reference,
          amountMinor: Number(refund.amount_minor),
          currency: refund.currency,
        });
    } catch {
      return publicRefund(refund);
    }
    if (!result) return publicRefund(refund);
    return this.applyRefundResult(refund.id, result);
  }

  async postSettlement(input: {
    organizationId: string;
    providerName: string;
    providerEnvironment: 'deterministic' | 'sandbox' | 'live';
    providerReference: string;
    grossAmountMinor: number;
    feeAmountMinor: number;
    sourceHash: string;
    settledAt: string;
  }) {
    const { data, error } = await supabase.rpc('post_provider_settlement', {
      p_organization_id: input.organizationId,
      p_provider_name: input.providerName,
      p_provider_environment: input.providerEnvironment,
      p_provider_reference: input.providerReference,
      p_currency: 'NGN',
      p_gross_amount_minor: input.grossAmountMinor,
      p_fee_amount_minor: input.feeAmountMinor,
      p_source_hash: input.sourceHash,
      p_settled_at: input.settledAt,
    });
    if (error || !data) throw error ?? new Error('Provider settlement could not be posted');
    return data;
  }

  private async initializeCreatedPayment(
    payment: any,
    input: InitializeInput,
    adapter: PaymentAdapter,
  ) {
    if (payment.state !== 'created') {
      const { data: authorizationUrl, error } = await supabase.rpc('get_payment_authorization_url', {
        p_payment_id: payment.id,
      });
      if (error) throw error;
      return {
        ...publicPayment(payment),
        authorizationUrl: authorizationUrl ?? undefined,
        idempotencyReplay: true,
      };
    }
    const command = {
      internalReference: payment.internal_reference,
      amountMinor: Number(payment.amount_minor),
      currency: 'NGN' as const,
      customerEmail: input.customerEmail,
      callbackUrl: input.callbackUrl,
      metadata: {
        type: input.sourceType,
        source_id: input.sourceId,
        organization_id: input.organizationId,
        ...input.metadata,
      },
    };
    const requestHash = sha256(JSON.stringify({
      internalReference: command.internalReference,
      amountMinor: command.amountMinor,
      currency: command.currency,
      sourceType: input.sourceType,
      sourceId: input.sourceId,
      provider: adapter.name,
      environment: adapter.environment,
    }));
    let result: ProviderPaymentResult;
    try {
      result = await adapter.initialize(command);
    } catch {
      const processing = await this.markInitialized(payment.id, requestHash, undefined, 'processing');
      await this.syncBookingPaymentWindow(processing);
      return { ...publicPayment(processing), idempotencyReplay: false };
    }
    if (result.amountMinor !== command.amountMinor || result.currency !== command.currency) {
      throw new Error('Payment provider initialization money mismatch');
    }
    const initialized = await this.markInitialized(
      payment.id,
      requestHash,
      result.providerReference,
      result.status === 'processing' ? 'processing' : 'requires_action',
    );
    if (result.authorizationUrl) {
      const { data, error } = await supabase.rpc('record_payment_authorization_url', {
        p_payment_id: payment.id,
        p_authorization_url: result.authorizationUrl,
      });
      if (error || !data) throw error ?? new Error('Payment authorization URL could not be recorded');
    }
    await this.syncBookingPaymentWindow(initialized);
    return {
      ...publicPayment(initialized),
      authorizationUrl: result.authorizationUrl,
      idempotencyReplay: false,
      accessCode: result.accessCode,
    };
  }

  private async applyProviderResult(paymentId: string, result: ProviderPaymentResult) {
    if (result.status === 'succeeded') {
      const { data, error } = await supabase.rpc('succeed_inbound_payment', {
        p_payment_id: paymentId,
        p_provider_reference: result.providerReference ?? null,
        p_amount_minor: result.amountMinor,
        p_currency: result.currency,
      });
      if (error || !data) throw error ?? new Error('Payment success could not be applied');
      return publicPayment(data);
    }
    if (['failed', 'cancelled', 'expired'].includes(result.status)) {
      const { data, error } = await supabase.rpc('fail_inbound_payment', {
        p_payment_id: paymentId,
        p_state: result.status,
        p_failure_code: result.failureCode ?? 'PROVIDER_TERMINAL',
        p_failure_reason: result.failureReason ?? `Provider reported payment ${result.status}`,
      });
      if (error || !data) throw error ?? new Error('Payment terminal state could not be applied');
      const payment = publicPayment(data);
      await this.markSourcePaymentFailure(payment);
      return payment;
    }
    const { data: payment, error } = await supabase.from('payments').select('*').eq('id', paymentId).single();
    if (error || !payment) throw new Error('Payment not found');
    return publicPayment(payment);
  }

  private async applyRefundResult(refundId: string, result: ProviderRefundResult) {
    const { data, error } = await supabase.rpc('apply_payment_refund_result', {
      p_refund_id: refundId,
      p_provider_reference: result.providerReference ?? null,
      p_state: result.status,
      p_failure_code: result.failureCode ?? null,
      p_failure_reason: result.failureReason ?? null,
    });
    if (error || !data) throw error ?? new Error('Refund state could not be applied');
    const { error: syncError } = await supabase.rpc('sync_booking_cancellation_refund', {
      p_refund_id: refundId,
    });
    if (syncError) logger.warn('Booking cancellation refund state could not be synchronized', {
      refundId, reason: syncError.message,
    });
    return publicRefund(data);
  }

  private async markInitialized(
    paymentId: string,
    requestHash: string,
    providerReference: string | undefined,
    state: 'requires_action' | 'processing',
  ) {
    const { data, error } = await supabase.rpc('mark_payment_initialized', {
      p_payment_id: paymentId,
      p_request_hash: requestHash,
      p_provider_reference: providerReference ?? null,
      p_state: state,
      p_action_expires_at: new Date(Date.now() + 48 * 60 * 60 * 1000).toISOString(),
    });
    if (error || !data) throw error ?? new Error('Payment initialization state could not be recorded');
    return data;
  }

  private async syncBookingPaymentWindow(payment: any): Promise<void> {
    if (payment.source_type !== 'booking') return;
    const { error } = await supabase.from('bookings').update({
      payment_reference: payment.internal_reference,
      payment_status: 'pending',
      payment_timeout_at: payment.action_expires_at,
      updated_at: new Date().toISOString(),
    }).eq('id', payment.source_id)
      .eq('organization_id', payment.organization_id)
      .eq('status', 'pending_payment');
    if (error) throw error;
  }

  private async markSourcePaymentFailure(payment: ReturnType<typeof publicPayment>): Promise<void> {
    if (payment.sourceType !== 'booking') return;
    const { error } = await supabase.from('bookings').update({
      payment_status: 'failed',
      updated_at: new Date().toISOString(),
    }).eq('id', payment.sourceId)
      .eq('organization_id', payment.organizationId)
      .eq('payment_reference', payment.internalReference)
      .eq('status', 'pending_payment');
    if (error) throw error;
  }

  private async finishEvent(eventId: string, state: 'processed' | 'rejected', reason?: string) {
    const { error } = await supabase.rpc('finish_payment_provider_event', {
      p_event_id: eventId,
      p_state: state,
      p_rejection_reason: reason ?? null,
    });
    if (error) throw error;
  }

  private async fulfillSource(payment: ReturnType<typeof publicPayment>): Promise<void> {
    if (payment.sourceType === 'booking') {
      await BookingModel.completePayment(payment.sourceId, payment.internalReference);
      try {
        await new ReceiptService().generateReceipt(payment.sourceId, payment.internalReference);
      } catch (error) {
        logger.error('Receipt generation failed after journaled booking payment', {
          booking_id: payment.sourceId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
      return;
    }
    if (payment.sourceType === 'marketplace_order') {
      const { error } = await supabase.from('orders').update({
        status: 'confirmed',
        payment_status: 'paid',
        paid_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      }).eq('id', payment.sourceId)
        .eq('organization_id', payment.organizationId)
        .eq('payment_status', 'pending');
      if (error) throw error;
      return;
    }
    if (payment.sourceType === 'group_membership') {
      await GroupModel.confirmPayment(payment.sourceId);
      return;
    }
    if (payment.sourceType === 'contribution') {
      await ContributionModel.recordPayment(
        payment.sourceId,
        payment.amountMinor / 100,
        payment.internalReference,
      );
    }
  }
}

export const paymentService = new PaymentService();
