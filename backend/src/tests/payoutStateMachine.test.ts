import { assertPayoutTransition, canTransitionPayout } from '../domains/financial/payoutStateMachine.js';

describe('payout state machine', () => {
  it('allows the approved monotonic and reversal transitions', () => {
    expect(canTransitionPayout('created', 'reserved')).toBe(true);
    expect(canTransitionPayout('reserved', 'submitted')).toBe(true);
    expect(canTransitionPayout('reserved', 'processing')).toBe(true);
    expect(canTransitionPayout('submitted', 'succeeded')).toBe(true);
    expect(canTransitionPayout('processing', 'failed')).toBe(true);
    expect(canTransitionPayout('succeeded', 'reversed')).toBe(true);
  });

  it('rejects terminal reactivation and backwards transitions', () => {
    expect(canTransitionPayout('failed', 'submitted')).toBe(false);
    expect(canTransitionPayout('succeeded', 'processing')).toBe(false);
    expect(() => assertPayoutTransition('cancelled', 'reserved')).toThrow('not allowed');
  });
});
