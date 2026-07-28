import { fireEvent, render, screen } from '@testing-library/react';
import { ReservationConfirmation } from '../ReservationConfirmation';

describe('ReservationConfirmation', () => {
  const reservation = {
    booking: { id: 'booking-1' },
    price_snapshot: {
      currency: 'NGN',
      total_minor: 123456,
      pricing_version: 'BOOKING-MONTHLY-2026-07-28',
    },
    hold: { held_until: '2030-01-02T12:00:00.000Z' },
  };

  it('shows the authoritative locked price and hold deadline', () => {
    render(
      <ReservationConfirmation
        reservation={reservation}
        propertyTitle="Poultry House A"
        onPay={jest.fn()}
        isPaying={false}
      />,
    );
    expect(screen.getByRole('heading', { name: /reservation held/i })).toBeTruthy();
    expect(screen.getByText('Poultry House A')).toBeTruthy();
    expect(screen.getByText(/1,234\.56/)).toBeTruthy();
    expect(screen.getByText(/complete payment before/i)).toBeTruthy();
  });

  it('starts payment for the reserved booking', () => {
    const onPay = jest.fn();
    render(
      <ReservationConfirmation
        reservation={reservation}
        propertyTitle="Poultry House A"
        onPay={onPay}
        isPaying={false}
      />,
    );
    fireEvent.click(screen.getByRole('button', { name: /complete payment/i }));
    expect(onPay).toHaveBeenCalledTimes(1);
  });
});
