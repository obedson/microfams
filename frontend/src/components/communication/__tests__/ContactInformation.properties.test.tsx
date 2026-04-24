import React from 'react';
import { render, screen } from '@testing-library/react';
import '@testing-library/jest-dom';
import ContactInformation from '../ContactInformation';

describe('ContactInformation Properties Tests - Task 7.2', () => {
  const mockFarmerInfo = {
    name: 'John Farmer',
    email: 'john.farmer@example.com',
    phone: '123-456-7890',
    role: 'farmer' as const
  };

  const mockOwnerInfo = {
    name: 'Jane Owner',
    email: 'jane.owner@example.com',
    phone: '098-765-4321',
    role: 'owner' as const
  };

  /**
   * Property 48: Phone Contact Display
   * For any booking where contact information is available, phone contact links should be displayed for direct calling.
   * Validates: Requirements 8.4
   */
  test('Property 48: Contact information is displayed correctly for confirmed bookings', () => {
    // Test farmer viewing owner contact info
    const { rerender } = render(
      <ContactInformation
        farmerInfo={mockFarmerInfo}
        ownerInfo={mockOwnerInfo}
        bookingStatus="confirmed"
        currentUserRole="farmer"
      />
    );

    // Property: Property owner contact is shown to farmer
    expect(screen.getByText('Property Owner Contact')).toBeInTheDocument();
    expect(screen.getByText('Jane Owner')).toBeInTheDocument();
    expect(screen.getByText('jane.owner@example.com')).toBeInTheDocument();
    expect(screen.getByText('098-765-4321')).toBeInTheDocument();

    // Property: Email and phone links are clickable
    expect(screen.getByRole('link', { name: 'jane.owner@example.com' })).toHaveAttribute('href', 'mailto:jane.owner@example.com');
    expect(screen.getByRole('link', { name: '098-765-4321' })).toHaveAttribute('href', 'tel:098-765-4321');

    // Test owner viewing farmer contact info
    rerender(
      <ContactInformation
        farmerInfo={mockFarmerInfo}
        ownerInfo={mockOwnerInfo}
        bookingStatus="confirmed"
        currentUserRole="owner"
      />
    );

    // Property: Farmer contact is shown to owner
    expect(screen.getByText('Farmer Contact')).toBeInTheDocument();
    expect(screen.getByText('John Farmer')).toBeInTheDocument();
    expect(screen.getByText('john.farmer@example.com')).toBeInTheDocument();
    expect(screen.getByText('123-456-7890')).toBeInTheDocument();
  });

  /**
   * Additional Property: Contact Information Visibility Rules
   * For any booking status, contact information should only be shown for confirmed and pending bookings.
   */
  test('Property: Contact information visibility follows booking status rules', () => {
    // Test confirmed booking - should show contact info
    const { rerender } = render(
      <ContactInformation
        farmerInfo={mockFarmerInfo}
        ownerInfo={mockOwnerInfo}
        bookingStatus="confirmed"
        currentUserRole="farmer"
      />
    );

    expect(screen.getByText('Property Owner Contact')).toBeInTheDocument();

    // Test pending booking - should show contact info
    rerender(
      <ContactInformation
        farmerInfo={mockFarmerInfo}
        ownerInfo={mockOwnerInfo}
        bookingStatus="pending"
        currentUserRole="farmer"
      />
    );

    expect(screen.getByText('Property Owner Contact')).toBeInTheDocument();

    // Test pending_payment booking - should NOT show contact info
    rerender(
      <ContactInformation
        farmerInfo={mockFarmerInfo}
        ownerInfo={mockOwnerInfo}
        bookingStatus="pending_payment"
        currentUserRole="farmer"
      />
    );

    expect(screen.queryByText('Property Owner Contact')).not.toBeInTheDocument();

    // Test completed booking - should NOT show contact info
    rerender(
      <ContactInformation
        farmerInfo={mockFarmerInfo}
        ownerInfo={mockOwnerInfo}
        bookingStatus="completed"
        currentUserRole="farmer"
      />
    );

    expect(screen.queryByText('Property Owner Contact')).not.toBeInTheDocument();

    // Test cancelled booking - should NOT show contact info
    rerender(
      <ContactInformation
        farmerInfo={mockFarmerInfo}
        ownerInfo={mockOwnerInfo}
        bookingStatus="cancelled"
        currentUserRole="farmer"
      />
    );

    expect(screen.queryByText('Property Owner Contact')).not.toBeInTheDocument();
  });

  /**
   * Additional Property: Partial Contact Information Handling
   * For any contact with missing information, only available information should be displayed.
   */
  test('Property: Partial contact information is handled correctly', () => {
    const partialOwnerInfo = {
      name: 'Jane Owner',
      email: 'jane.owner@example.com',
      // No phone number
      role: 'owner' as const
    };

    render(
      <ContactInformation
        farmerInfo={mockFarmerInfo}
        ownerInfo={partialOwnerInfo}
        bookingStatus="confirmed"
        currentUserRole="farmer"
      />
    );

    // Property: Name and email are shown
    expect(screen.getByText('Jane Owner')).toBeInTheDocument();
    expect(screen.getByText('jane.owner@example.com')).toBeInTheDocument();

    // Property: Phone section is not shown when phone is missing
    expect(screen.queryByText('Phone:')).not.toBeInTheDocument();
  });

  /**
   * Additional Property: Empty Contact Information
   * For any contact with no email or phone, only the name should be displayed.
   */
  test('Property: Contact with only name is handled correctly', () => {
    const nameOnlyOwnerInfo = {
      name: 'Jane Owner',
      // No email or phone
      role: 'owner' as const
    };

    render(
      <ContactInformation
        farmerInfo={mockFarmerInfo}
        ownerInfo={nameOnlyOwnerInfo}
        bookingStatus="confirmed"
        currentUserRole="farmer"
      />
    );

    // Property: Name is shown
    expect(screen.getByText('Jane Owner')).toBeInTheDocument();

    // Property: Email and phone sections are not shown
    expect(screen.queryByText('Email:')).not.toBeInTheDocument();
    expect(screen.queryByText('Phone:')).not.toBeInTheDocument();
  });
});
