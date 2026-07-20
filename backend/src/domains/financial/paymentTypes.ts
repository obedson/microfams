export type PaymentProviderEnvironment = 'deterministic' | 'sandbox' | 'live';
export type PaymentState =
  | 'created'
  | 'requires_action'
  | 'processing'
  | 'succeeded'
  | 'failed'
  | 'cancelled'
  | 'expired'
  | 'partially_refunded'
  | 'refunded';

export type ProviderPaymentStatus =
  | 'requires_action'
  | 'processing'
  | 'succeeded'
  | 'failed'
  | 'cancelled'
  | 'expired';

export type RefundState = 'created' | 'submitted' | 'processing' | 'succeeded' | 'failed' | 'cancelled';

export interface InitializePaymentCommand {
  internalReference: string;
  amountMinor: number;
  currency: 'NGN';
  customerEmail: string;
  callbackUrl: string;
  metadata: Record<string, string>;
}

export interface ProviderPaymentResult {
  providerReference?: string;
  status: ProviderPaymentStatus;
  amountMinor: number;
  currency: 'NGN';
  authorizationUrl?: string;
  accessCode?: string;
  failureCode?: string;
  failureReason?: string;
  paidAt?: string;
}

export interface ProviderRefundResult {
  providerReference?: string;
  status: Exclude<RefundState, 'created'>;
  amountMinor: number;
  currency: 'NGN';
  failureCode?: string;
  failureReason?: string;
}

export interface VerifiedPaymentProviderEvent {
  providerEventId?: string;
  eventType: string;
  internalReference: string;
  providerReference?: string;
  status: ProviderPaymentStatus | 'reversed';
  amountMinor: number;
  currency: 'NGN';
  occurredAt?: string;
  failureCode?: string;
  failureReason?: string;
}

export interface PaymentAdapter {
  readonly name: string;
  readonly environment: PaymentProviderEnvironment;
  initialize(command: InitializePaymentCommand): Promise<ProviderPaymentResult>;
  query(internalReference: string): Promise<ProviderPaymentResult>;
  refund(command: {
    internalReference: string;
    providerPaymentReference: string;
    amountMinor: number;
    currency: 'NGN';
    reason: string;
  }): Promise<ProviderRefundResult>;
  queryRefund(providerRefundReference: string): Promise<ProviderRefundResult>;
  verifyAndParseWebhook(rawBody: Buffer, signature: string): VerifiedPaymentProviderEvent;
}

export class PaymentConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PaymentConfigurationError';
  }
}

export class PaymentSubmissionUnknownError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PaymentSubmissionUnknownError';
  }
}

export class InvalidPaymentProviderEventError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'InvalidPaymentProviderEventError';
  }
}
