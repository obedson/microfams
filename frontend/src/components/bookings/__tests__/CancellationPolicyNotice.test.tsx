import '@testing-library/jest-dom';
import React from 'react';
import { render, screen } from '@testing-library/react';
import CancellationPolicyNotice from '../CancellationPolicyNotice';

describe('CancellationPolicyNotice', () => {
  const now = new Date('2026-07-28T12:00:00Z');

  it('explains that unpaid bookings require no refund', () => {
    render(<CancellationPolicyNotice startDate="2026-08-05" paymentStatus="pending" now={now} />);
    expect(screen.getByRole('note')).toHaveTextContent('No refund is required');
  });

  it('explains automatic pre-start refund servicing', () => {
    render(<CancellationPolicyNotice startDate="2026-08-05" paymentStatus="paid" now={now} />);
    expect(screen.getByRole('note')).toHaveTextContent('submitted for refund');
  });

  it('explains maker-checker review after service starts', () => {
    render(<CancellationPolicyNotice startDate="2026-07-27" paymentStatus="paid" now={now} />);
    expect(screen.getByRole('note')).toHaveTextContent('independent review');
  });
});
