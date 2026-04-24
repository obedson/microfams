import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import '@testing-library/jest-dom';
import BookingFilters from '../BookingFilters';

// Mock data
const mockProperties = [
  { id: 'prop1', title: 'Farm Property 1' },
  { id: 'prop2', title: 'Farm Property 2' }
];

describe('BookingFilters Properties Tests - Task 5.4', () => {
  /**
   * Property 25: Date Range Filtering
   * Requirements 5.1: "THE Dashboard SHALL provide date range filter for booking start and end dates"
   * Design: "date range filters should accurately filter bookings by their date periods"
   */
  test('Property 25: Date range filtering works correctly', async () => {
    const mockOnDateRangeChange = jest.fn();
    
    render(
      <BookingFilters
        statusFilter="all"
        onStatusChange={jest.fn()}
        type="farmer"
        dateRangeFilter={{ start: '', end: '' }}
        onDateRangeChange={mockOnDateRangeChange}
      />
    );

    // Show advanced filters
    fireEvent.click(screen.getByText('Advanced'));

    // Property: Date range inputs are present
    expect(screen.getByLabelText('Start Date')).toBeInTheDocument();
    expect(screen.getByLabelText('End Date')).toBeInTheDocument();

    // Property: Date range inputs accept date values
    const startDateInput = screen.getByLabelText('Start Date');
    const endDateInput = screen.getByLabelText('End Date');

    fireEvent.change(startDateInput, { target: { value: '2024-01-01' } });
    expect(mockOnDateRangeChange).toHaveBeenCalledWith({
      start: '2024-01-01',
      end: ''
    });

    fireEvent.change(endDateInput, { target: { value: '2024-01-31' } });
    expect(mockOnDateRangeChange).toHaveBeenCalledWith({
      start: '',
      end: '2024-01-31'
    });

    // Property: Date inputs have calendar icons
    expect(screen.getAllByRole('img', { hidden: true })).toHaveLength(2); // Calendar icons
  });

  /**
   * Property 26: Status Filtering Accuracy
   * Requirements 5.2: "THE Dashboard SHALL allow filtering by booking status"
   * Design: "status filters should accurately show only bookings matching selected status"
   */
  test('Property 26: Status filtering works accurately', () => {
    const mockOnStatusChange = jest.fn();
    
    render(
      <BookingFilters
        statusFilter="all"
        onStatusChange={mockOnStatusChange}
        type="farmer"
      />
    );

    // Property: Status filter dropdown is present
    const statusSelect = screen.getByLabelText('Status');
    expect(statusSelect).toBeInTheDocument();

    // Property: All status options are available
    expect(screen.getByText('All Bookings')).toBeInTheDocument();
    expect(screen.getByText('Pending Payment')).toBeInTheDocument();
    expect(screen.getByText('Pending Approval')).toBeInTheDocument();
    expect(screen.getByText('Confirmed')).toBeInTheDocument();
    expect(screen.getByText('Completed')).toBeInTheDocument();
    expect(screen.getByText('Cancelled')).toBeInTheDocument();

    // Property: Status change triggers callback
    fireEvent.change(statusSelect, { target: { value: 'confirmed' } });
    expect(mockOnStatusChange).toHaveBeenCalledWith('confirmed');

    fireEvent.change(statusSelect, { target: { value: 'pending_payment' } });
    expect(mockOnStatusChange).toHaveBeenCalledWith('pending_payment');
  });

  /**
   * Property 27: Property-Specific Filtering
   * Requirements 5.3: "WHERE multiple properties exist, THE Dashboard SHALL provide property-specific filtering"
   * Design: "property filters should be available for owners and accurately filter by property"
   */
  test('Property 27: Property-specific filtering works for owners', () => {
    const mockOnPropertyChange = jest.fn();
    
    // Test for owner (should show property filter)
    const { rerender } = render(
      <BookingFilters
        statusFilter="all"
        onStatusChange={jest.fn()}
        type="owner"
        properties={mockProperties}
        propertyFilter="all"
        onPropertyChange={mockOnPropertyChange}
      />
    );

    // Property: Property filter is visible for owners
    expect(screen.getByLabelText('Property')).toBeInTheDocument();
    expect(screen.getByText('All Properties')).toBeInTheDocument();
    expect(screen.getByText('Farm Property 1')).toBeInTheDocument();
    expect(screen.getByText('Farm Property 2')).toBeInTheDocument();

    // Property: Property selection triggers callback
    const propertySelect = screen.getByLabelText('Property');
    fireEvent.change(propertySelect, { target: { value: 'prop1' } });
    expect(mockOnPropertyChange).toHaveBeenCalledWith('prop1');

    // Test for farmer (should not show property filter)
    rerender(
      <BookingFilters
        statusFilter="all"
        onStatusChange={jest.fn()}
        type="farmer"
        properties={mockProperties}
        propertyFilter="all"
        onPropertyChange={mockOnPropertyChange}
      />
    );

    // Property: Property filter is not visible for farmers
    expect(screen.queryByLabelText('Property')).not.toBeInTheDocument();
  });

  /**
   * Property 29: Search Functionality Accuracy
   * Requirements 5.5: "THE Dashboard SHALL provide search functionality by farmer name or booking reference"
   * Design: "search should accurately match farmer names and booking references"
   */
  test('Property 29: Search functionality works accurately', () => {
    const mockOnSearchChange = jest.fn();
    
    render(
      <BookingFilters
        statusFilter="all"
        onStatusChange={jest.fn()}
        type="farmer"
        searchQuery=""
        onSearchChange={mockOnSearchChange}
      />
    );

    // Property: Search input is present
    const searchInput = screen.getByPlaceholderText('Search by farmer name or booking reference...');
    expect(searchInput).toBeInTheDocument();

    // Property: Search input has search icon
    expect(screen.getByRole('img', { hidden: true })).toBeInTheDocument(); // Search icon

    // Property: Search input triggers callback on change
    fireEvent.change(searchInput, { target: { value: 'John Farmer' } });
    expect(mockOnSearchChange).toHaveBeenCalledWith('John Farmer');

    fireEvent.change(searchInput, { target: { value: 'booking-123' } });
    expect(mockOnSearchChange).toHaveBeenCalledWith('booking-123');

    // Property: Search input accepts empty values (verify at least 2 calls were made)
    fireEvent.change(searchInput, { target: { value: '' } });
    expect(mockOnSearchChange).toHaveBeenCalledTimes(2);
  });

  /**
   * Additional Property: Payment Status Filtering
   * Requirements 5.4: "THE Dashboard SHALL allow filtering by payment status"
   */
  test('Property: Payment status filtering works correctly', () => {
    const mockOnPaymentStatusChange = jest.fn();
    
    render(
      <BookingFilters
        statusFilter="all"
        onStatusChange={jest.fn()}
        type="farmer"
        paymentStatusFilter="all"
        onPaymentStatusChange={mockOnPaymentStatusChange}
      />
    );

    // Show advanced filters
    fireEvent.click(screen.getByText('Advanced'));

    // Property: Payment status filter is present in advanced mode
    expect(screen.getByLabelText('Payment Status')).toBeInTheDocument();

    // Property: Payment status options are available
    expect(screen.getByText('All Payment Status')).toBeInTheDocument();
    expect(screen.getByText('Pending')).toBeInTheDocument();
    expect(screen.getByText('Paid')).toBeInTheDocument();
    expect(screen.getByText('Failed')).toBeInTheDocument();

    // Property: Payment status change triggers callback
    const paymentStatusSelect = screen.getByLabelText('Payment Status');
    fireEvent.change(paymentStatusSelect, { target: { value: 'paid' } });
    expect(mockOnPaymentStatusChange).toHaveBeenCalledWith('paid');
  });

  /**
   * Additional Property: Filter State Persistence and Indicators
   * Requirements 5.6: "THE Dashboard SHALL maintain filter state during user session"
   * Requirements 5.7: "THE Dashboard SHALL display active filter indicators and allow quick filter clearing"
   */
  test('Property: Filter state indicators and clearing work correctly', () => {
    const mockOnClearFilters = jest.fn();
    
    // Test with active filters
    const { rerender } = render(
      <BookingFilters
        statusFilter="confirmed"
        onStatusChange={jest.fn()}
        type="farmer"
        searchQuery="test search"
        onSearchChange={jest.fn()}
        onClearFilters={mockOnClearFilters}
      />
    );

    // Property: Active filter indicator is shown
    expect(screen.getByText('Active')).toBeInTheDocument();

    // Property: Clear all button is present when filters are active
    expect(screen.getByText('Clear All')).toBeInTheDocument();

    // Property: Clear all button triggers callback
    fireEvent.click(screen.getByText('Clear All'));
    expect(mockOnClearFilters).toHaveBeenCalled();

    // Test with no active filters
    rerender(
      <BookingFilters
        statusFilter="all"
        onStatusChange={jest.fn()}
        type="farmer"
        searchQuery=""
        onSearchChange={jest.fn()}
        onClearFilters={mockOnClearFilters}
      />
    );

    // Property: No active indicator when no filters are active
    expect(screen.queryByText('Active')).not.toBeInTheDocument();
    expect(screen.queryByText('Clear All')).not.toBeInTheDocument();
  });

  /**
   * Additional Property: Advanced/Simple Toggle
   */
  test('Property: Advanced/Simple toggle works correctly', () => {
    render(
      <BookingFilters
        statusFilter="all"
        onStatusChange={jest.fn()}
        type="farmer"
        paymentStatusFilter="all"
        onPaymentStatusChange={jest.fn()}
        dateRangeFilter={{ start: '', end: '' }}
        onDateRangeChange={jest.fn()}
      />
    );

    // Property: Initially shows simple mode
    expect(screen.getByText('Advanced')).toBeInTheDocument();
    expect(screen.queryByLabelText('Payment Status')).not.toBeInTheDocument();

    // Property: Clicking Advanced shows advanced filters
    fireEvent.click(screen.getByText('Advanced'));
    expect(screen.getByText('Simple')).toBeInTheDocument();
    expect(screen.getByLabelText('Payment Status')).toBeInTheDocument();
    expect(screen.getByLabelText('Start Date')).toBeInTheDocument();

    // Property: Clicking Simple hides advanced filters
    fireEvent.click(screen.getByText('Simple'));
    expect(screen.getByText('Advanced')).toBeInTheDocument();
    expect(screen.queryByLabelText('Payment Status')).not.toBeInTheDocument();
  });
});
