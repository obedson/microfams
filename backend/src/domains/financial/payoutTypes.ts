export type PayoutProviderEnvironment = 'deterministic' | 'sandbox' | 'live';
export type PayoutState =
  | 'created'
  | 'reserved'
  | 'submitted'
  | 'processing'
  | 'succeeded'
  | 'failed'
  | 'reversed'
  | 'cancelled';

export type ProviderPayoutStatus = 'submitted' | 'processing' | 'succeeded' | 'failed';

export interface PayoutDestination {
  accountNumber: string;
  bankCode: string;
  accountName: string;
}

export interface PayoutSubmissionCommand {
  internalReference: string;
  amountMinor: number;
  currency: 'NGN';
  narration: string;
  destination: PayoutDestination;
}

export interface ProviderPayoutResult {
  providerReference?: string;
  status: ProviderPayoutStatus;
  amountMinor: number;
  currency: 'NGN';
  failureCode?: string;
  failureReason?: string;
}

export interface VerifiedProviderEvent extends ProviderPayoutResult {
  providerEventId?: string;
  eventType: string;
  internalReference: string;
  occurredAt?: string;
}

export interface PayoutAdapter {
  readonly name: string;
  readonly environment: PayoutProviderEnvironment;
  validateDestination(accountNumber: string, bankCode: string): Promise<{ accountName: string; bankCode: string }>;
  submit(command: PayoutSubmissionCommand): Promise<ProviderPayoutResult>;
  query(internalReference: string): Promise<ProviderPayoutResult>;
  verifyAndParseWebhook(rawBody: Buffer, signature: string): VerifiedProviderEvent;
}

export class PayoutConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PayoutConfigurationError';
  }
}

export class PayoutSubmissionUnknownError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PayoutSubmissionUnknownError';
  }
}

export class InvalidProviderEventError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'InvalidProviderEventError';
  }
}
