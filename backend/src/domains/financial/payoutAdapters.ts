import crypto from 'crypto';
import { interswitchService } from '../../services/interswitchService.js';
import {
  InvalidProviderEventError,
  PayoutAdapter,
  PayoutConfigurationError,
  PayoutProviderEnvironment,
  PayoutSubmissionCommand,
  ProviderPayoutResult,
  VerifiedProviderEvent,
} from './payoutTypes.js';

const mapProviderStatus = (status: unknown): ProviderPayoutResult['status'] => {
  const value = String(status || '').toLowerCase();
  if (['success', 'succeeded', 'completed'].includes(value)) return 'succeeded';
  if (['failed', 'rejected'].includes(value)) return 'failed';
  if (['submitted', 'accepted'].includes(value)) return 'submitted';
  return 'processing';
};

const asPositiveMinor = (value: unknown): number => {
  const amount = Number(value);
  if (!Number.isSafeInteger(amount) || amount <= 0) throw new InvalidProviderEventError('Provider amount is invalid');
  return amount;
};

export class DeterministicPayoutAdapter implements PayoutAdapter {
  readonly name = 'deterministic';
  readonly environment = 'deterministic' as const;
  private readonly outcomes = new Map<string, ProviderPayoutResult>();

  setOutcome(internalReference: string, result: ProviderPayoutResult): void {
    this.outcomes.set(internalReference, result);
  }

  async validateDestination(_accountNumber: string, bankCode: string) {
    return { accountName: 'Synthetic Test Beneficiary', bankCode };
  }

  async submit(command: PayoutSubmissionCommand): Promise<ProviderPayoutResult> {
    return this.outcomes.get(command.internalReference) ?? {
      providerReference: `DET-${command.internalReference}`,
      status: 'processing',
      amountMinor: command.amountMinor,
      currency: command.currency,
    };
  }

  async query(internalReference: string): Promise<ProviderPayoutResult> {
    const result = this.outcomes.get(internalReference);
    if (!result) throw new PayoutConfigurationError('No deterministic payout outcome is configured');
    return result;
  }

  verifyAndParseWebhook(rawBody: Buffer, signature: string): VerifiedProviderEvent {
    const secret = process.env.DETERMINISTIC_PAYOUT_WEBHOOK_SECRET;
    if (!secret) throw new PayoutConfigurationError('Deterministic payout webhook secret is not configured');
    const expected = crypto.createHmac('sha256', secret).update(rawBody).digest();
    const received = Buffer.from(signature, 'hex');
    if (received.length !== expected.length || !crypto.timingSafeEqual(received, expected)) {
      throw new InvalidProviderEventError('Invalid provider webhook signature');
    }
    return parseNormalizedEvent(JSON.parse(rawBody.toString('utf8')));
  }
}

export class InterswitchPayoutAdapter implements PayoutAdapter {
  readonly name = 'interswitch';
  constructor(readonly environment: Extract<PayoutProviderEnvironment, 'sandbox' | 'live'>) {}

  validateDestination(accountNumber: string, bankCode: string) {
    return interswitchService.nameEnquiry(accountNumber, bankCode);
  }

  async submit(command: PayoutSubmissionCommand): Promise<ProviderPayoutResult> {
    const result = await interswitchService.singleTransfer({
      accountNumber: command.destination.accountNumber,
      bankCode: command.destination.bankCode,
      amount: command.amountMinor,
      reference: command.internalReference,
      narration: command.narration,
    });
    return {
      providerReference: result.transferRef,
      status: mapProviderStatus(result.status),
      amountMinor: command.amountMinor,
      currency: command.currency,
    };
  }

  async query(internalReference: string): Promise<ProviderPayoutResult> {
    const result = await interswitchService.queryTransactionStatus(internalReference);
    return {
      status: mapProviderStatus(result.status),
      amountMinor: asPositiveMinor(result.amount),
      currency: 'NGN',
    };
  }

  verifyAndParseWebhook(rawBody: Buffer, signature: string): VerifiedProviderEvent {
    if (!interswitchService.verifyWebhookSignature(rawBody.toString('utf8'), signature)) {
      throw new InvalidProviderEventError('Invalid provider webhook signature');
    }
    return parseNormalizedEvent(JSON.parse(rawBody.toString('utf8')));
  }
}

export const parseNormalizedEvent = (payload: any): VerifiedProviderEvent => {
  const internalReference = payload.internalReference ?? payload.transactionReference ?? payload.transferReference ?? payload.reference;
  if (typeof internalReference !== 'string' || internalReference.length < 8) {
    throw new InvalidProviderEventError('Provider event reference is invalid');
  }
  const currency = String(payload.currency ?? 'NGN').toUpperCase();
  if (currency !== 'NGN') throw new InvalidProviderEventError('Provider event currency is unsupported');
  return {
    providerEventId: payload.eventId ? String(payload.eventId) : undefined,
    eventType: String(payload.eventType ?? payload.type ?? 'payout.status'),
    internalReference,
    providerReference: payload.providerReference ?? payload.interswitchReference,
    status: mapProviderStatus(payload.status),
    amountMinor: asPositiveMinor(payload.amountMinor ?? payload.amount),
    currency: 'NGN',
    failureCode: payload.failureCode ? String(payload.failureCode) : undefined,
    failureReason: payload.failureReason ? String(payload.failureReason) : undefined,
    occurredAt: payload.occurredAt ? String(payload.occurredAt) : undefined,
  };
};

export const assertLivePayoutActivationConfigured = (): void => {
  if (!process.env.INTERSWITCH_LIVE_APPROVAL_ID || process.env.PAYOUT_RECONCILIATION_CERTIFIED !== 'true') {
    throw new PayoutConfigurationError('Live payouts require approval metadata and reconciliation certification');
  }
};

export const configuredPayoutAdapter = (): PayoutAdapter => {
  const mode = (process.env.PAYOUT_PROVIDER_MODE ?? (process.env.NODE_ENV === 'production' ? 'sandbox' : 'deterministic')) as PayoutProviderEnvironment;
  if (!['deterministic', 'sandbox', 'live'].includes(mode)) {
    throw new PayoutConfigurationError('Payout provider mode is invalid');
  }
  if (mode === 'deterministic') {
    if (process.env.NODE_ENV === 'production') throw new PayoutConfigurationError('Deterministic payouts cannot run in production');
    return new DeterministicPayoutAdapter();
  }
  if (!process.env.INTERSWITCH_CLIENT_ID || !process.env.INTERSWITCH_CLIENT_SECRET || !process.env.INTERSWITCH_WEBHOOK_SECRET) {
    throw new PayoutConfigurationError('Interswitch payout credentials are incomplete');
  }
  return new InterswitchPayoutAdapter(mode);
};
