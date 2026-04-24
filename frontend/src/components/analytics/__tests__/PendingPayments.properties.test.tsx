import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import '@testing-library/jest-dom';
import PendingPayments from '../PendingPayments';

const mockPendingBookings = [
  {
    id: 'booking-1',
    reference_number: '#ABCD1234',
    farmer_name: 'John Farmer',
    property_name: 'Green Valley Farm',
    amount: 50000,
    created_at: new Date(Date.now() - 2 * 24 * 60 * 60 * 1000), // 2 days ago
    payment_timeout_at: new Date(Date.now() + 22 * 60 * 60 * 1000), // 22 hours from now (within 24-48 hour window)
    status: 'pending_payment' as const
  },
  {
    id: 'booking-2',
    reference_number: '#EFGH5678',
    farmer_name: 'Jane Farmer',
    property_name: 'Sunset Ranch',
    amount: 75000,
    created_at: new Date(Date.now() - 1 * 24 * 60 * 60 * 1000), // 1 day ago
    payment_timeout_at: new Date(Date.now() + 50 * 60 * 60 * 1000), // 50 hours from now (outside 24-48 hour window)
    status: 'pending_payment' as const
  }
];

describe('PendingPayments Properties Tests - Task 6.4', () => {
  const mockOnBulkAction = jest.fn();
  const mockOnSendReminder = jest.fn();

  beforeEach(() => {
    jest.clearAllMocks();
  });

  /**
   * Property 59: Pending Payment Section Display
   * For any dashboard view, pending payment bookings should be displayed in a separate, clearly identified section.
   * Validates: Requirements 10.1
   */
  test('Property 59: Pending payment bookings are displayed in separate section', () => {
    render(
      <PendingPayments
        bookings={mockPendingBookings}
        onBulkAction={mockOnBulkAction}
        onSendReminder={mockOnSendReminder}
      />
    );

    // Property: Section is clearly identified
    expect(screen.getByText('Pending Payment Bookings')).toBeInTheDocument();
    
    // Property: Section contains pending payment bookings
    expect(screen.getByText('#ABCD1234')).toBeInTheDocument();
    expect(screen.getByText('#EFGH5678')).toBeInTheDocument();
    
    // Property: Section shows potential revenue
    expect(screen.getByText(/Potential Revenue:/)).toBeInTheDocument();
    
    // Property: Section is separate from other content
    const section = screen.getByText('Pending Payment Bookings').closest('.pending-payments-section');
    expect(section).toBeInTheDocument();
  });

  /**
   * Property 61: Days Elapsed Calculation
   * For any pending payment booking, the days elapsed since booking creation should be correctly calculated and displayed.
   * Validates: Requirements 10.3
   */
  test('Property 61: Days elapsed since booking creation is correctly calculated', () => {
    render(
      <PendingPayments
        bookings={mockPendingBookings}
        onBulkAction={mockOnBulkAction}
        onSendReminder={mockOnSendReminder}
      />
    );

    // Property: Days elapsed is calculated correctly for 2-day-old booking
    expect(screen.getByText(/3.*days.*elapsed/)).toBeInTheDocument();
    
    // Property: Days elapsed is calculated correctly for 1-day-old booking
    expect(screen.getByText(/2.*days.*elapsed/)).toBeInTheDocument();
    
    // Property: Plural form is used for multiple days
    const multipleDaysText = screen.getByText(/3.*days.*elapsed/);
    expect(multipleDaysText).toBeInTheDocument();
  });

  /**
   * Property 62: Payment Timeout Highlighting
   * For any booking approaching payment timeout (24-48 hours), it should be highlighted or marked appropriately.
   * Validates: Requirements 10.4
   */
  test('Property 62: Bookings approaching payment timeout are highlighted', () => {
    render(
      <PendingPayments
        bookings={mockPendingBookings}
        onBulkAction={mockOnBulkAction}
        onSendReminder={mockOnSendReminder}
      />
    );

    // Property: Booking with 22 hours until timeout is highlighted
    const timeoutBooking = screen.getByText('#ABCD1234').closest('.pending-booking-item');
    expect(timeoutBooking).toHaveClass('timeout-warning');
    
    // Property: Timeout warning badge is displayed (only for booking within 24-48 hour window)
    expect(screen.getByText('Payment Timeout Soon')).toBeInTheDocument();
    
    // Property: Booking with 50 hours until timeout is not highlighted (outside 24-48 hour window)
    const normalBooking = screen.getByText('#EFGH5678').closest('.pending-booking-item');
    expect(normalBooking).not.toHaveClass('timeout-warning');
  });

  /**
   * Additional Property: Bulk Actions Functionality
   * For any selection of pending payment bookings, bulk actions should be available and executable.
   * Validates: Requirements 10.5
   */
  test('Property 63: Bulk actions are available for selected bookings', () => {
    render(
      <PendingPayments
        bookings={mockPendingBookings}
        onBulkAction={mockOnBulkAction}
        onSendReminder={mockOnSendReminder}
      />
    );

    // Property: Select all checkbox is available
    const selectAllCheckbox = screen.getByLabelText(/Select All/);
    expect(selectAllCheckbox).toBeInTheDocument();
    
    // Property: Individual booking checkboxes are available
    const checkboxes = screen.getAllByRole('checkbox');
    expect(checkboxes).toHaveLength(3); // 1 select all + 2 individual bookings
    
    // Property: Bulk actions appear when bookings are selected
    fireEvent.click(selectAllCheckbox);
    
    expect(screen.getByText('Send Reminders (2)')).toBeInTheDocument();
    expect(screen.getByText('Cancel Selected (2)')).toBeInTheDocument();
    
    // Property: Bulk actions execute correctly
    fireEvent.click(screen.getByText('Send Reminders (2)'));
    expect(mockOnBulkAction).toHaveBeenCalledWith(['booking-1', 'booking-2'], 'send_reminders');
  });

  /**
   * Additional Property: Individual Reminder Actions
   * For any pending payment booking, individual reminder actions should be available.
   */
  test('Property: Individual reminder actions work correctly', () => {
    render(
      <PendingPayments
        bookings={mockPendingBookings}
        onBulkAction={mockOnBulkAction}
        onSendReminder={mockOnSendReminder}
      />
    );

    // Property: Individual reminder buttons are available
    const reminderButtons = screen.getAllByText('Send Reminder');
    expect(reminderButtons).toHaveLength(2);
    
    // Property: Individual reminder action executes correctly
    fireEvent.click(reminderButtons[0]);
    expect(mockOnSendReminder).toHaveBeenCalledWith('booking-1');
  });

  /**
   * Additional Property: Empty State Handling
   * For any dashboard with no pending payments, appropriate empty state should be displayed.
   */
  test('Property: Empty state is displayed when no pending bookings exist', () => {
    render(
      <PendingPayments
        bookings={[]}
        onBulkAction={mockOnBulkAction}
        onSendReminder={mockOnSendReminder}
      />
    );

    // Property: Empty state message is displayed
    expect(screen.getByText('No pending payment bookings')).toBeInTheDocument();
    
    // Property: Bulk actions are not shown for empty state
    expect(screen.queryByText('Select All')).not.toBeInTheDocument();
  });

  /**
   * Additional Property: Revenue Calculation
   * For any analytics calculation, pending revenue should be correctly calculated from all unpaid bookings.
   * Validates: Requirements 10.2
   */
  test('Property 60: Pending revenue is correctly calculated from unpaid bookings', () => {
    render(
      <PendingPayments
        bookings={mockPendingBookings}
        onBulkAction={mockOnBulkAction}
        onSendReminder={mockOnSendReminder}
      />
    );

    // Property: Total pending revenue is calculated correctly (50000 + 75000 = 125000)
    expect(screen.getByText(/Potential Revenue:/)).toBeInTheDocument();
    
    // Property: Revenue is formatted as Nigerian Naira
    expect(screen.getByText(/₦125,000\.00/)).toBeInTheDocument();
  });
});
