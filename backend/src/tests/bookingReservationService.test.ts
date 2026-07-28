import fc from 'fast-check';
import { bookingReservationHttpError, calculateMonthlyBookingPrice } from '../services/bookingReservationService.js';

describe('BookingReservationService domain rules', () => {
  it('calculates monthly pricing in integer minor units', () => {
    expect(calculateMonthlyBookingPrice('2026-08-01', '2026-08-31', 125_050)).toEqual({
      durationDays: 30,
      billedMonths: 1,
      totalMinor: 125_050,
    });
    expect(calculateMonthlyBookingPrice('2026-08-01', '2026-09-01', 125_050)).toEqual({
      durationDays: 31,
      billedMonths: 2,
      totalMinor: 250_100,
    });
  });

  it('preserves the integer-minor-unit invariant across valid durations and rates', () => {
    fc.assert(fc.property(
      fc.integer({ min: 1, max: 720 }),
      fc.integer({ min: 0, max: 100_000_000 }),
      (durationDays, monthlyRateMinor) => {
        const start = new Date('2030-01-01T00:00:00Z');
        const end = new Date(start.getTime() + durationDays * 86_400_000);
        const result = calculateMonthlyBookingPrice(
          start.toISOString().slice(0, 10),
          end.toISOString().slice(0, 10),
          monthlyRateMinor,
        );
        expect(result.durationDays).toBe(durationDays);
        expect(result.billedMonths).toBe(Math.ceil(durationDays / 30));
        expect(result.totalMinor).toBe(monthlyRateMinor * Math.ceil(durationDays / 30));
        expect(Number.isInteger(result.totalMinor)).toBe(true);
      },
    ), { numRuns: 200 });
  });

  it('rejects invalid pricing inputs', () => {
    expect(() => calculateMonthlyBookingPrice('2026-08-10', '2026-08-10', 100)).toThrow('BOOKING_PRICE_INPUT_INVALID');
    expect(() => calculateMonthlyBookingPrice('invalid', '2026-08-10', 100)).toThrow('BOOKING_PRICE_INPUT_INVALID');
    expect(() => calculateMonthlyBookingPrice('2026-08-01', '2026-08-10', 10.5)).toThrow('BOOKING_PRICE_INPUT_INVALID');
  });

  it.each([
    ['BOOKING_DATES_UNAVAILABLE', 409, 'BOOKING_DATES_UNAVAILABLE'],
    ['IDEMPOTENCY_REPLAY_CONFLICT', 409, 'IDEMPOTENCY_REPLAY_CONFLICT'],
    ['PROPERTY_NOT_FOUND', 404, 'PROPERTY_NOT_FOUND'],
    ['BOOKING_NOT_AUTHORIZED', 403, 'BOOKING_NOT_AUTHORIZED'],
    ['BOOKING_DATES_INVALID', 400, 'BOOKING_DATES_INVALID'],
  ])('maps database error %s to a stable API contract', (message, status, code) => {
    expect(bookingReservationHttpError(message)).toEqual({ status, code });
  });
});
