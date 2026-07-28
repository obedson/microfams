import fc from 'fast-check';
import {
  bookingTransitionHttpError,
  isLegalManagedBookingTransition,
} from '../services/bookingLifecycleService.js';

describe('booking lifecycle policy', () => {
  it('allows only paid pending approval and due confirmed completion', () => {
    expect(isLegalManagedBookingTransition('pending', 'confirmed', 'paid')).toBe(true);
    expect(isLegalManagedBookingTransition('pending', 'confirmed', 'pending')).toBe(false);
    expect(isLegalManagedBookingTransition('confirmed', 'completed', 'paid', '2026-07-27', '2026-07-28')).toBe(true);
    expect(isLegalManagedBookingTransition('confirmed', 'completed', 'paid', '2026-07-29', '2026-07-28')).toBe(false);
    expect(isLegalManagedBookingTransition('pending', 'cancelled', 'paid')).toBe(false);
  });

  it('rejects every managed transition from a terminal state', () => {
    fc.assert(fc.property(
      fc.constantFrom('cancelled', 'completed'),
      fc.constantFrom('confirmed', 'completed'),
      (current, target) => {
        expect(isLegalManagedBookingTransition(current, target, 'paid', '2020-01-01', '2026-07-28')).toBe(false);
      },
    ), { numRuns: 100 });
  });

  it('maps database policy failures to stable API errors', () => {
    expect(bookingTransitionHttpError('BOOKING_TRANSITION_NOT_AUTHORIZED')).toEqual({
      status: 403, code: 'BOOKING_TRANSITION_NOT_AUTHORIZED',
    });
    expect(bookingTransitionHttpError('BOOKING_COMPLETION_TOO_EARLY')).toEqual({
      status: 409, code: 'BOOKING_COMPLETION_TOO_EARLY',
    });
    expect(bookingTransitionHttpError('IDEMPOTENCY_REPLAY_CONFLICT')).toEqual({
      status: 409, code: 'IDEMPOTENCY_REPLAY_CONFLICT',
    });
  });
});
