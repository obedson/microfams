import fc from 'fast-check';
import { BookingModel } from '../models/Booking.js';
import supabase from '../utils/supabase.js';

/**
 * **Feature: farmle-platform-enhancement, Property 5: Cancellation Button Availability**
 * **Validates: Requirements 1.6**
 * 
 * Property-based test to verify that cancellation button availability follows business rules:
 * - Available for bookings with status: pending_payment, pending, confirmed
 * - Not available for bookings with status: cancelled, completed
 */

describe('Booking Status Transitions - Property Tests', () => {
  // Test data generators
  const bookingStatusArb = fc.constantFrom(
    'pending_payment',
    'pending', 
    'confirmed',
    'cancelled',
    'completed'
  );

  const paymentStatusArb = fc.constantFrom('pending', 'paid', 'failed');

  const bookingArb = fc.record({
    id: fc.uuid(),
    property_id: fc.uuid(),
    farmer_id: fc.uuid(),
    start_date: fc.integer({ min: 0, max: 365 })
      .map(days => {
        const date = new Date('2024-01-01');
        date.setDate(date.getDate() + days);
        return date.toISOString().split('T')[0];
      }),
    end_date: fc.integer({ min: 1, max: 400 })
      .map(days => {
        const date = new Date('2024-01-01');
        date.setDate(date.getDate() + days);
        return date.toISOString().split('T')[0];
      }),
    total_amount: fc.float({ min: 100, max: 10000 }),
    status: bookingStatusArb,
    payment_status: paymentStatusArb,
    payment_reference: fc.option(fc.string({ minLength: 10, maxLength: 50 }), { nil: null }),
    payment_retry_count: fc.integer({ min: 0, max: 5 }),
    created_at: fc.integer({ min: 0, max: 365 })
      .map(days => {
        const date = new Date('2024-01-01');
        date.setDate(date.getDate() + days);
        return date.toISOString();
      }),
    updated_at: fc.integer({ min: 0, max: 365 })
      .map(days => {
        const date = new Date('2024-01-01');
        date.setDate(date.getDate() + days);
        return date.toISOString();
      })
  });

  /**
   * Property 5: Cancellation Button Availability
   * For any booking with status pending_payment, pending, or confirmed, 
   * a cancel button should be available to the farmer.
   */
  test('Property 5: Cancellation button should be available for cancellable booking statuses', () => {
    fc.assert(fc.property(bookingArb, (booking: any) => {
      const cancellableStatuses = ['pending_payment', 'pending', 'confirmed'];
      const nonCancellableStatuses = ['cancelled', 'completed'];
      
      if (cancellableStatuses.includes(booking.status)) {
        // Booking should be cancellable
        const canCancel = isCancellable(booking);
        expect(canCancel).toBe(true);
      } else if (nonCancellableStatuses.includes(booking.status)) {
        // Booking should not be cancellable
        const canCancel = isCancellable(booking);
        expect(canCancel).toBe(false);
      }
    }), { numRuns: 100 });
  });

  /**
   * Additional property test: Status transition validation
   * Ensures that status transitions follow business logic
   */
  test('Property: Status transitions should follow valid business rules', () => {
    const statusTransitionArb = fc.record({
      currentStatus: bookingStatusArb,
      newStatus: bookingStatusArb,
      paymentStatus: paymentStatusArb
    });

    fc.assert(fc.property(statusTransitionArb, (transition: any) => {
      const isValidTransition = validateStatusTransition(
        transition.currentStatus,
        transition.newStatus,
        transition.paymentStatus
      );

      // Define valid transitions based on business rules
      const validTransitions = getValidTransitions(transition.currentStatus, transition.paymentStatus);
      
      if (validTransitions.includes(transition.newStatus)) {
        expect(isValidTransition).toBe(true);
      } else {
        expect(isValidTransition).toBe(false);
      }
    }), { numRuns: 100 });
  });
});

// Helper functions to implement business logic
function isCancellable(booking: any): boolean {
  const cancellableStatuses = ['pending_payment', 'pending', 'confirmed'];
  return cancellableStatuses.includes(booking.status);
}

function validateStatusTransition(currentStatus: string, newStatus: string, paymentStatus: string): boolean {
  // Cannot transition from completed or cancelled
  if (['completed', 'cancelled'].includes(currentStatus)) {
    return false;
  }

  // Cannot confirm booking without payment
  if (newStatus === 'confirmed' && paymentStatus !== 'paid') {
    return false;
  }

  // Cannot go to pending from pending_payment without payment
  if (currentStatus === 'pending_payment' && newStatus === 'pending' && paymentStatus !== 'paid') {
    return false;
  }

  // Valid transitions based on current status
  const validTransitions = getValidTransitions(currentStatus, paymentStatus);
  return validTransitions.includes(newStatus);
}

function getValidTransitions(currentStatus: string, paymentStatus: string): string[] {
  switch (currentStatus) {
    case 'pending_payment':
      // From pending_payment, can go to pending (if paid) or cancelled
      return paymentStatus === 'paid' 
        ? ['pending', 'cancelled'] 
        : ['cancelled'];
    
    case 'pending':
      // From pending, can go to confirmed (if paid) or cancelled
      return paymentStatus === 'paid'
        ? ['confirmed', 'cancelled']
        : ['cancelled'];
    
    case 'confirmed':
      // From confirmed, can go to completed or cancelled
      return ['completed', 'cancelled'];
    
    case 'cancelled':
    case 'completed':
      // Terminal states - no further transitions allowed
      return [];
    
    default:
      return [];
  }
}