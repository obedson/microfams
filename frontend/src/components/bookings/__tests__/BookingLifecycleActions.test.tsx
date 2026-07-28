import React from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import BookingCard from '../BookingCard';

const booking = {
  id: '00000000-0000-4000-8000-000000000001',
  status: 'pending',
  payment_status: 'paid',
  total_amount: 1000,
  start_date: '2020-01-01',
  end_date: '2020-01-31',
  created_at: '2020-01-01T00:00:00Z',
  properties: { title: 'Lifecycle Farm', city: 'Abuja', lga: 'AMAC' },
  users: { name: 'Test Farmer' },
};

describe('BookingCard owner lifecycle actions', () => {
  it('offers approval only for a paid pending booking', () => {
    const onApprove = jest.fn();
    render(<BookingCard booking={booking} type="owner" onApprove={onApprove} />);
    fireEvent.click(screen.getByRole('button', { name: 'Approve' }));
    expect(onApprove).toHaveBeenCalledWith(booking);
    expect(screen.queryByRole('button', { name: 'Mark Completed' })).toBeNull();
  });

  it('offers completion only for a paid confirmed booking whose end date passed', () => {
    const onComplete = jest.fn();
    const completedCandidate = { ...booking, status: 'confirmed' };
    render(<BookingCard booking={completedCandidate} type="owner" onComplete={onComplete} />);
    fireEvent.click(screen.getByRole('button', { name: 'Mark Completed' }));
    expect(onComplete).toHaveBeenCalledWith(completedCandidate);
    expect(screen.queryByRole('button', { name: 'Approve' })).toBeNull();
  });
});
