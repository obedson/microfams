import { PayoutState } from './payoutTypes.js';

const transitions: Readonly<Record<PayoutState, readonly PayoutState[]>> = {
  created: ['reserved', 'cancelled'],
  reserved: ['submitted', 'processing', 'failed', 'cancelled'],
  submitted: ['processing', 'succeeded', 'failed'],
  processing: ['succeeded', 'failed'],
  succeeded: ['reversed'],
  failed: [],
  reversed: [],
  cancelled: [],
};

export const canTransitionPayout = (from: PayoutState, to: PayoutState): boolean =>
  transitions[from].includes(to);

export const assertPayoutTransition = (from: PayoutState, to: PayoutState): void => {
  if (!canTransitionPayout(from, to)) {
    throw new Error(`Payout transition ${from} -> ${to} is not allowed`);
  }
};
