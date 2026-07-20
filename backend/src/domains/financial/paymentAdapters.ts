import crypto from 'crypto';
import { PaystackService } from '../../services/paystackService.js';
import {
  InitializePaymentCommand,
  InvalidPaymentProviderEventError,
  PaymentAdapter,
  PaymentConfigurationError,
  PaymentProviderEnvironment,
  ProviderPaymentResult,
  ProviderRefundResult,
  VerifiedPaymentProviderEvent,
} from './paymentTypes.js';

const asPositiveMinor = (value: unknown): number => {
  const amount = Number(value);
  if (!Number.isSafeInteger(amount) || amount <= 0) {
    throw new InvalidPaymentProviderEventError('Provider payment amount is invalid');
  }
  return amount;
};

const paymentStatus = (value: unknown): ProviderPaymentResult['status'] => {
  const status = String(value ?? '').toLowerCase();
  if (['success', 'succeeded', 'completed'].includes(status)) return 'succeeded';
  if (['failed', 'abandoned'].includes(status)) return 'failed';
  if (['cancelled', 'canceled'].includes(status)) return 'cancelled';
  if (status === 'expired') return 'expired';
  if (['pending', 'processing', 'ongoing', 'queued'].includes(status)) return 'processing';
  return 'requires_action';
};

const refundStatus = (value: unknown): ProviderRefundResult['status'] => {
  const status = String(value ?? '').toLowerCase();
  if (['processed', 'success', 'succeeded', 'completed'].includes(status)) return 'succeeded';
  if (['failed', 'rejected'].includes(status)) return 'failed';
  if (['cancelled', 'canceled'].includes(status)) return 'cancelled';
  if (['pending', 'processing'].includes(status)) return 'processing';
  return 'submitted';
};

const timingSafeHex = (rawBody: Buffer, signature: string, secret: string): boolean => {
  const expected = crypto.createHmac('sha512', secret).update(rawBody).digest();
  let received: Buffer;
  try {
    received = Buffer.from(signature, 'hex');
  } catch {
    return false;
  }
  return received.length === expected.length && crypto.timingSafeEqual(received, expected);
};

export class DeterministicPaymentAdapter implements PaymentAdapter {
  readonly name = 'deterministic';
  readonly environment = 'deterministic' as const;
  private readonly paymentOutcomes = new Map<string, ProviderPaymentResult>();
  private readonly refundOutcomes = new Map<string, ProviderRefundResult>();

  setPaymentOutcome(internalReference: string, result: ProviderPaymentResult): void {
    this.paymentOutcomes.set(internalReference, result);
  }

  setRefundOutcome(internalReference: string, result: ProviderRefundResult): void {
    this.refundOutcomes.set(internalReference, result);
  }

  async initialize(command: InitializePaymentCommand): Promise<ProviderPaymentResult> {
    return this.paymentOutcomes.get(command.internalReference) ?? {
      providerReference: `DET-PAY-${command.internalReference}`,
      status: 'requires_action',
      amountMinor: command.amountMinor,
      currency: command.currency,
      authorizationUrl: `https://deterministic.invalid/pay/${encodeURIComponent(command.internalReference)}`,
      accessCode: `DET-${command.internalReference}`,
    };
  }

  async query(internalReference: string): Promise<ProviderPaymentResult> {
    const result = this.paymentOutcomes.get(internalReference);
    if (!result) throw new PaymentConfigurationError('No deterministic payment outcome is configured');
    return result;
  }

  async refund(command: {
    internalReference: string;
    amountMinor: number;
    providerPaymentReference: string;
    currency: 'NGN';
    reason: string;
  }): Promise<ProviderRefundResult> {
    return this.refundOutcomes.get(command.internalReference) ?? {
      providerReference: `DET-REF-${command.internalReference}`,
      status: 'processing',
      amountMinor: command.amountMinor,
      currency: command.currency,
    };
  }

  async queryRefund(providerRefundReference: string): Promise<ProviderRefundResult> {
    const result = [...this.refundOutcomes.values()]
      .find((candidate) => candidate.providerReference === providerRefundReference);
    if (!result) throw new PaymentConfigurationError('No deterministic refund outcome is configured');
    return result;
  }

  verifyAndParseWebhook(rawBody: Buffer, signature: string): VerifiedPaymentProviderEvent {
    const secret = process.env.DETERMINISTIC_PAYMENT_WEBHOOK_SECRET;
    if (!secret) throw new PaymentConfigurationError('Deterministic payment webhook secret is not configured');
    if (!timingSafeHex(rawBody, signature, secret)) {
      throw new InvalidPaymentProviderEventError('Invalid provider webhook signature');
    }
    return parsePaystackPaymentEvent(JSON.parse(rawBody.toString('utf8')));
  }
}

export class PaystackPaymentAdapter implements PaymentAdapter {
  readonly name = 'paystack';
  constructor(readonly environment: Extract<PaymentProviderEnvironment, 'sandbox' | 'live'>) {}

  async initialize(command: InitializePaymentCommand): Promise<ProviderPaymentResult> {
    const response = await PaystackService.initializeTransaction({
      email: command.customerEmail,
      amount: command.amountMinor,
      currency: command.currency,
      reference: command.internalReference,
      callback_url: command.callbackUrl,
      metadata: command.metadata,
    });
    const data = response.data;
    return {
      providerReference: data.reference ?? command.internalReference,
      status: 'requires_action',
      amountMinor: command.amountMinor,
      currency: command.currency,
      authorizationUrl: data.authorization_url,
      accessCode: data.access_code,
    };
  }

  async query(internalReference: string): Promise<ProviderPaymentResult> {
    const response = await PaystackService.verifyTransaction(internalReference);
    const data = response.data;
    return {
      providerReference: data.reference,
      status: paymentStatus(data.status),
      amountMinor: asPositiveMinor(data.amount),
      currency: String(data.currency ?? 'NGN').toUpperCase() as 'NGN',
      paidAt: data.paid_at,
      failureReason: data.gateway_response,
    };
  }

  async refund(command: {
    internalReference: string;
    providerPaymentReference: string;
    amountMinor: number;
    currency: 'NGN';
    reason: string;
  }): Promise<ProviderRefundResult> {
    const response = await PaystackService.createRefund({
      transaction: command.providerPaymentReference,
      amount: command.amountMinor,
      merchant_note: command.reason,
    });
    const data = response.data;
    return {
      providerReference: data?.id ? String(data.id) : data?.refund_reference,
      status: refundStatus(data?.status),
      amountMinor: asPositiveMinor(data?.amount ?? command.amountMinor),
      currency: command.currency,
    };
  }

  async queryRefund(providerRefundReference: string): Promise<ProviderRefundResult> {
    const response = await PaystackService.fetchRefund(providerRefundReference);
    const data = response.data;
    return {
      providerReference: data?.id ? String(data.id) : providerRefundReference,
      status: refundStatus(data?.status),
      amountMinor: asPositiveMinor(data?.amount),
      currency: String(data?.currency ?? 'NGN').toUpperCase() as 'NGN',
    };
  }

  verifyAndParseWebhook(rawBody: Buffer, signature: string): VerifiedPaymentProviderEvent {
    const secret = process.env.PAYSTACK_SECRET_KEY;
    if (!secret) throw new PaymentConfigurationError('Paystack webhook secret is not configured');
    if (!timingSafeHex(rawBody, signature, secret)) {
      throw new InvalidPaymentProviderEventError('Invalid provider webhook signature');
    }
    return parsePaystackPaymentEvent(JSON.parse(rawBody.toString('utf8')));
  }
}

export const parsePaystackPaymentEvent = (payload: any): VerifiedPaymentProviderEvent => {
  const data = payload.data ?? payload;
  const internalReference = data.reference ?? data.transaction_reference;
  if (typeof internalReference !== 'string' || internalReference.length < 8) {
    throw new InvalidPaymentProviderEventError('Provider payment reference is invalid');
  }
  const currency = String(data.currency ?? 'NGN').toUpperCase();
  if (currency !== 'NGN') throw new InvalidPaymentProviderEventError('Provider payment currency is unsupported');
  const eventType = String(payload.event ?? payload.eventType ?? 'payment.status');
  return {
    providerEventId: data.id ? String(data.id) : undefined,
    eventType,
    internalReference,
    providerReference: data.reference ?? data.provider_reference,
    status: eventType.includes('reversal') || eventType.includes('chargeback')
      ? 'reversed'
      : paymentStatus(data.status ?? (eventType === 'charge.success' ? 'success' : undefined)),
    amountMinor: asPositiveMinor(data.amountMinor ?? data.amount),
    currency: 'NGN',
    occurredAt: data.paid_at ?? data.occurredAt ?? payload.created_at,
    failureCode: data.gateway_response ? String(data.gateway_response) : undefined,
    failureReason: data.message ? String(data.message) : undefined,
  };
};

export const assertLivePaymentActivationConfigured = (): void => {
  if (!process.env.PAYSTACK_LIVE_APPROVAL_ID || process.env.PAYMENT_RECONCILIATION_CERTIFIED !== 'true') {
    throw new PaymentConfigurationError('Live payments require approval metadata and reconciliation certification');
  }
};

export const configuredPaymentAdapter = (): PaymentAdapter => {
  const mode = (process.env.PAYMENT_PROVIDER_MODE
    ?? (process.env.NODE_ENV === 'production' ? 'sandbox' : 'deterministic')) as PaymentProviderEnvironment;
  if (!['deterministic', 'sandbox', 'live'].includes(mode)) {
    throw new PaymentConfigurationError('Payment provider mode is invalid');
  }
  if (mode === 'deterministic') {
    if (process.env.NODE_ENV === 'production') {
      throw new PaymentConfigurationError('Deterministic payments cannot run in production');
    }
    return new DeterministicPaymentAdapter();
  }
  if (!process.env.PAYSTACK_SECRET_KEY) throw new PaymentConfigurationError('Paystack credentials are incomplete');
  return new PaystackPaymentAdapter(mode);
};
