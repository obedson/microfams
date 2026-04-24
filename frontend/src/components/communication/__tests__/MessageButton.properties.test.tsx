import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import '@testing-library/jest-dom';
import MessageButton from '../MessageButton';

// Mock window.location.href
delete (window as any).location;
window.location = { href: '' } as any;

describe('Communication System Properties Tests - Task 7.2', () => {
  const mockOnMessageClick = jest.fn();

  beforeEach(() => {
    jest.clearAllMocks();
    window.location.href = '';
  });

  /**
   * Property 45: Message Button Availability for Farmers
   * For any farmer viewing confirmed or pending bookings, a "Message Owner" button should be available.
   * Validates: Requirements 8.1
   */
  test('Property 45: Message Owner button is available for farmers on confirmed and pending bookings', () => {
    // Test confirmed booking
    const { rerender } = render(
      <MessageButton
        userType="farmer"
        bookingStatus="confirmed"
        recipientName="John Owner"
        recipientEmail="owner@example.com"
        bookingReference="#ABCD1234"
        propertyName="Green Valley Farm"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Message Owner button is available for confirmed bookings
    expect(screen.getByText('Message Owner')).toBeInTheDocument();

    // Test pending booking
    rerender(
      <MessageButton
        userType="farmer"
        bookingStatus="pending"
        recipientName="John Owner"
        recipientEmail="owner@example.com"
        bookingReference="#ABCD1234"
        propertyName="Green Valley Farm"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Message Owner button is available for pending bookings
    expect(screen.getByText('Message Owner')).toBeInTheDocument();

    // Test that button is NOT available for other statuses
    rerender(
      <MessageButton
        userType="farmer"
        bookingStatus="pending_payment"
        recipientName="John Owner"
        recipientEmail="owner@example.com"
        bookingReference="#ABCD1234"
        propertyName="Green Valley Farm"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Message Owner button is NOT available for pending_payment bookings
    expect(screen.queryByText('Message Owner')).not.toBeInTheDocument();
  });

  /**
   * Property 46: Message Button Availability for Owners
   * For any property owner viewing active bookings, a "Message Farmer" button should be available.
   * Validates: Requirements 8.2
   */
  test('Property 46: Message Farmer button is available for owners on active bookings', () => {
    // Test pending_payment booking
    const { rerender } = render(
      <MessageButton
        userType="owner"
        bookingStatus="pending_payment"
        recipientName="Jane Farmer"
        recipientEmail="farmer@example.com"
        bookingReference="#EFGH5678"
        propertyName="Sunset Ranch"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Message Farmer button is available for pending_payment bookings
    expect(screen.getByText('Message Farmer')).toBeInTheDocument();

    // Test pending booking
    rerender(
      <MessageButton
        userType="owner"
        bookingStatus="pending"
        recipientName="Jane Farmer"
        recipientEmail="farmer@example.com"
        bookingReference="#EFGH5678"
        propertyName="Sunset Ranch"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Message Farmer button is available for pending bookings
    expect(screen.getByText('Message Farmer')).toBeInTheDocument();

    // Test confirmed booking
    rerender(
      <MessageButton
        userType="owner"
        bookingStatus="confirmed"
        recipientName="Jane Farmer"
        recipientEmail="farmer@example.com"
        bookingReference="#EFGH5678"
        propertyName="Sunset Ranch"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Message Farmer button is available for confirmed bookings
    expect(screen.getByText('Message Farmer')).toBeInTheDocument();

    // Test that button is NOT available for completed bookings
    rerender(
      <MessageButton
        userType="owner"
        bookingStatus="completed"
        recipientName="Jane Farmer"
        recipientEmail="farmer@example.com"
        bookingReference="#EFGH5678"
        propertyName="Sunset Ranch"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Message Farmer button is NOT available for completed bookings
    expect(screen.queryByText('Message Farmer')).not.toBeInTheDocument();
  });

  /**
   * Property 47: Email Client Integration
   * For any message button click, the system should generate a correct mailto link with pre-filled subject line.
   * Validates: Requirements 8.3
   */
  test('Property 47: Email client integration generates correct mailto links', () => {
    render(
      <MessageButton
        userType="farmer"
        bookingStatus="confirmed"
        recipientName="John Owner"
        recipientEmail="owner@example.com"
        recipientPhone="123-456-7890"
        bookingReference="#ABCD1234"
        propertyName="Green Valley Farm"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Email button is available when email is provided
    const emailButton = screen.getByText('📧 Email');
    expect(emailButton).toBeInTheDocument();

    // Property: Email button generates correct mailto link with pre-filled subject
    fireEvent.click(emailButton);
    
    const expectedSubject = 'Booking #ABCD1234 - Green Valley Farm';
    const expectedMailto = `mailto:owner@example.com?subject=${encodeURIComponent(expectedSubject)}`;
    expect(window.location.href).toBe(expectedMailto);
  });

  /**
   * Property 48: Phone Contact Display
   * For any booking where contact information is available, phone contact links should be displayed.
   * Validates: Requirements 8.4
   */
  test('Property 48: Phone contact links are displayed when available', () => {
    render(
      <MessageButton
        userType="farmer"
        bookingStatus="confirmed"
        recipientName="John Owner"
        recipientEmail="owner@example.com"
        recipientPhone="123-456-7890"
        bookingReference="#ABCD1234"
        propertyName="Green Valley Farm"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Phone button is available when phone is provided
    const phoneButton = screen.getByText('📞 Call');
    expect(phoneButton).toBeInTheDocument();

    // Property: Phone button generates correct tel link
    fireEvent.click(phoneButton);
    expect(window.location.href).toBe('tel:123-456-7890');
  });

  /**
   * Additional Property: Contact Options Visibility
   * For any message button, contact options should only be shown when contact information is available.
   */
  test('Property: Contact options are only shown when information is available', () => {
    // Test with no contact information
    const { rerender } = render(
      <MessageButton
        userType="farmer"
        bookingStatus="confirmed"
        recipientName="John Owner"
        bookingReference="#ABCD1234"
        propertyName="Green Valley Farm"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: No contact buttons when no contact info provided
    expect(screen.queryByText('📧 Email')).not.toBeInTheDocument();
    expect(screen.queryByText('📞 Call')).not.toBeInTheDocument();

    // Test with only email
    rerender(
      <MessageButton
        userType="farmer"
        bookingStatus="confirmed"
        recipientName="John Owner"
        recipientEmail="owner@example.com"
        bookingReference="#ABCD1234"
        propertyName="Green Valley Farm"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Only email button when only email provided
    expect(screen.getByText('📧 Email')).toBeInTheDocument();
    expect(screen.queryByText('📞 Call')).not.toBeInTheDocument();
  });

  /**
   * Additional Property: Message Button Click Handler
   * For any message button click, the onMessageClick handler should be called.
   */
  test('Property: Message button click handler is called correctly', () => {
    render(
      <MessageButton
        userType="farmer"
        bookingStatus="confirmed"
        recipientName="John Owner"
        recipientEmail="owner@example.com"
        bookingReference="#ABCD1234"
        propertyName="Green Valley Farm"
        onMessageClick={mockOnMessageClick}
      />
    );

    // Property: Message button click calls handler
    const messageButton = screen.getByText('Message Owner');
    fireEvent.click(messageButton);
    expect(mockOnMessageClick).toHaveBeenCalledTimes(1);
  });
});
