import { PaymentState, RefundState } from './paymentTypes.js';

const PAYMENT_TRANSITIONS: Record<PaymentState, readonly PaymentState[]> = {
  created: ['requires_action', 'processing', 'failed', 'cancelled', 'expired'],
  requires_action: ['processing', 'succeeded', 'failed', 'cancelled', 'expired'],
  processing: ['succeeded', 'failed', 'cancelled', 'expired'],
  succeeded: ['partially_refunded', 'refunded'],
  partially_refunded: ['partially_refunded', 'refunded'],
  refunded: [],
  failed: [],
  cancelled: [],
  expired: [],
};

const REFUND_TRANSITIONS: Record<RefundState, readonly RefundState[]> = {
  created: ['submitted', 'processing', 'succeeded', 'failed', 'cancelled'],
  submitted: ['processing', 'succeeded', 'failed'],
  processing: ['succeeded', 'failed'],
  succeeded: [],
  failed: [],
  cancelled: [],
};

export const paymentTransitionAllowed = (from: PaymentState, to: PaymentState): boolean =>
  from === to || PAYMENT_TRANSITIONS[from].includes(to);

export const refundTransitionAllowed = (from: RefundState, to: RefundState): boolean =>
  from === to || REFUND_TRANSITIONS[from].includes(to);

export const assertPaymentTransition = (from: PaymentState, to: PaymentState): void => {
  if (!paymentTransitionAllowed(from, to)) {
    throw new Error(`Payment transition ${from} -> ${to} is not allowed`);
  }
};

export const assertRefundTransition = (from: RefundState, to: RefundState): void => {
  if (!refundTransitionAllowed(from, to)) {
    throw new Error(`Refund transition ${from} -> ${to} is not allowed`);
  }
};
