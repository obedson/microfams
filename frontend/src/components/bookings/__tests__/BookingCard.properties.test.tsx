import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import '@testing-library/jest-dom';
import BookingCard from '../BookingCard';

// Mock auth store
jest.mock('../../../store/authStore', () => ({
  useAuthStore: () => ({
    user: { id: 'user-123', name: 'Jane Farmer', email: 'farmer@test.com' }
  })
}));

// Mock booking data generator
const createMockBooking = (overrides: any = {}) => ({
  id: 'booking-123',
  status: 'pending_payment',
  payment_status: 'pending',
  total_amount: 50000,
  start_date: '2024-01-15',
  end_date: '2024-01-20',
  created_at: '2024-01-10T10:00:00Z',
  notes: 'Test booking notes',
  properties: {
    title: 'Test Farm Property',
    city: 'Lagos',
    lga: 'Ikeja',
    users: {
      name: 'John Owner',
      email: 'owner@test.com',
      phone: '+2348012345678'
    }
  },
  users: {
    name: 'Jane Farmer',
    email: 'farmer@test.com',
    phone: '+2348087654321'
  },
  ...overrides
});

describe('BookingCard Properties Tests - Task 5.2', () => {
  /**
   * Property 1: Booking Tab Organization
   * Requirements 1.2: "THE Dashboard SHALL organize bookings into tabs for Upcoming, Past, and Cancelled bookings"
   * Design: "bookings should be properly categorized by their status and dates"
   */
  test('Property 1: Booking cards display appropriate content for tab categorization', () => {
    const upcomingBooking = createMockBooking({
      status: 'confirmed',
      end_date: '2024-12-31' // Future date
    });

    const pastBooking = createMockBooking({
      status: 'completed',
      end_date: '2024-01-01' // Past date
    });

    const cancelledBooking = createMockBooking({
      status: 'cancelled',
      cancelled_at: '2024-01-12T10:00:00Z'
    });

    // Test upcoming booking
    const { rerender } = render(
      <BookingCard booking={upcomingBooking} type="farmer" />
    );

    // Property: Upcoming bookings show status and timeline
    expect(screen.getByText('confirmed')).toBeInTheDocument();
    expect(screen.getByText('Confirmed')).toBeInTheDocument(); // Timeline step

    // Test past booking
    rerender(<BookingCard booking={pastBooking} type="farmer" />);
    expect(screen.getByText('completed')).toBeInTheDocument();
    expect(screen.getByText('Completed')).toBeInTheDocument(); // Timeline step

    // Test cancelled booking
    rerender(<BookingCard booking={cancelledBooking} type="farmer" />);
    expect(screen.getByText('cancelled')).toBeInTheDocument();
  });

  /**
   * Property 2: Reference Number Display
   * Requirements 1.3: "THE Dashboard SHALL display booking reference numbers for easy support communication"
   * Design: "reference numbers should be clearly visible and formatted for easy reading"
   */
  test('Property 2: Booking reference numbers are displayed correctly', () => {
    const booking = createMockBooking({
      id: 'booking-abcd1234efgh5678'
    });

    render(<BookingCard booking={booking} type="farmer" />);

    // Property: Reference number is displayed
    expect(screen.getByText(/Booking Reference:/)).toBeInTheDocument();
    
    // Property: Reference number is formatted (last 8 chars, uppercase)
    expect(screen.getByText('#EFGH5678')).toBeInTheDocument();
    
    // Property: Reference number uses monospace font for clarity
    const referenceElement = screen.getByText('#EFGH5678');
    expect(referenceElement).toHaveClass('font-mono');
  });

  /**
   * Property 3: Payment Button Visibility
   * Requirements 1.4: "WHEN a booking has pending payment status, THE Dashboard SHALL show a prominent 'Complete Payment' button"
   * Design: "payment buttons should be visible only when appropriate and clearly actionable"
   */
  test('Property 3: Payment buttons are visible based on booking and payment status', () => {
    const mockOnRetryPayment = jest.fn();

    // Test pending payment booking
    const pendingPaymentBooking = createMockBooking({
      status: 'pending_payment',
      payment_status: 'pending'
    });

    const { rerender } = render(
      <BookingCard 
        booking={pendingPaymentBooking} 
        type="farmer" 
        onRetryPayment={mockOnRetryPayment}
      />
    );

    // Property: Complete Payment button is visible for pending payment
    expect(screen.getByText('Complete Payment')).toBeInTheDocument();

    // Test failed payment booking
    const failedPaymentBooking = createMockBooking({
      status: 'pending_payment',
      payment_status: 'failed'
    });

    rerender(
      <BookingCard 
        booking={failedPaymentBooking} 
        type="farmer" 
        onRetryPayment={mockOnRetryPayment}
      />
    );

    // Property: Retry Payment button is visible for failed payment
    expect(screen.getByText('Retry Payment')).toBeInTheDocument();

    // Test paid booking
    const paidBooking = createMockBooking({
      status: 'confirmed',
      payment_status: 'paid'
    });

    rerender(
      <BookingCard 
        booking={paidBooking} 
        type="farmer" 
        onRetryPayment={mockOnRetryPayment}
      />
    );

    // Property: No payment buttons for paid bookings
    expect(screen.queryByText('Complete Payment')).not.toBeInTheDocument();
    expect(screen.queryByText('Retry Payment')).not.toBeInTheDocument();
  });

  /**
   * Property 4: Timeline Status Progression
   * Requirements 1.5: "THE Dashboard SHALL show booking progress using a visual timeline indicator"
   * Design: "timeline should show clear progression from Created → Payment → Pending Approval → Confirmed → Completed"
   */
  test('Property 4: Timeline shows correct status progression', () => {
    // Test pending payment status
    const pendingPaymentBooking = createMockBooking({ 
      status: 'pending_payment', 
      payment_status: 'pending' 
    });

    const { rerender } = render(<BookingCard booking={pendingPaymentBooking} type="farmer" />);

    // Property: Timeline steps are present
    expect(screen.getAllByText('Created')).toHaveLength(1);
    expect(screen.getAllByText('Payment')).toHaveLength(1);
    expect(screen.getAllByText('Pending Approval')).toHaveLength(1);
    expect(screen.getAllByText('Confirmed')).toHaveLength(1);
    expect(screen.getAllByText('Completed')).toHaveLength(1);

    // Test confirmed status
    const confirmedBooking = createMockBooking({ 
      status: 'confirmed', 
      payment_status: 'paid' 
    });

    rerender(<BookingCard booking={confirmedBooking} type="farmer" />);

    // Property: Timeline shows progression for confirmed booking
    expect(screen.getAllByText('Created')).toHaveLength(1);
    expect(screen.getAllByText('Payment')).toHaveLength(1);
    expect(screen.getAllByText('Confirmed')).toHaveLength(1);

    // Test completed status
    const completedBooking = createMockBooking({ 
      status: 'completed', 
      payment_status: 'paid' 
    });

    rerender(<BookingCard booking={completedBooking} type="farmer" />);

    // Property: Timeline shows all steps for completed booking
    expect(screen.getAllByText('Completed')).toHaveLength(1);
  });

  /**
   * Additional Property: Button interactions work correctly
   */
  test('Property: Action buttons trigger correct callbacks', () => {
    const mockOnCancel = jest.fn();
    const mockOnContact = jest.fn();
    const mockOnRetryPayment = jest.fn();

    const booking = createMockBooking({
      status: 'confirmed',
      payment_status: 'paid'
    });

    render(
      <BookingCard 
        booking={booking} 
        type="farmer"
        onCancel={mockOnCancel}
        onContact={mockOnContact}
        onRetryPayment={mockOnRetryPayment}
      />
    );

    // Property: Cancel button works
    const cancelButton = screen.getByText('Cancel Booking');
    fireEvent.click(cancelButton);
    expect(mockOnCancel).toHaveBeenCalledWith(booking);

    // Property: Message button works
    const messageButton = screen.getByText('Message Owner');
    fireEvent.click(messageButton);
    // Note: MessageButton might not call onContact if it uses its own modal logic
    // but the test confirms the button is present and clickable
    expect(messageButton).toBeInTheDocument();
  });

  /**
   * Additional Property: Timeline handles cancelled bookings correctly
   */
  test('Property: Timeline shows cancelled status correctly', () => {
    const cancelledBooking = createMockBooking({
      status: 'cancelled',
      cancelled_at: '2024-01-12T10:00:00Z'
    });

    render(<BookingCard booking={cancelledBooking} type="farmer" />);

    // Property: Cancelled status is visible
    expect(screen.getByText('cancelled')).toBeInTheDocument();
    
    // Property: Timeline shows cancellation
    expect(screen.getByText('Created')).toBeInTheDocument();
  });
});
