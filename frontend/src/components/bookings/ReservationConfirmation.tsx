import React from 'react';
import { CheckCircle2, CreditCard } from 'lucide-react';
import Button from '../ui/Button';
import Card from '../ui/Card';

interface ReservationConfirmationProps {
  reservation: {
    booking: { id: string };
    price_snapshot: { currency: string; total_minor: number; pricing_version: string };
    hold: { held_until: string };
  };
  propertyTitle: string;
  onPay: () => void;
  isPaying: boolean;
}

export const ReservationConfirmation: React.FC<ReservationConfirmationProps> = ({
  reservation,
  propertyTitle,
  onPay,
  isPaying,
}) => {
  const amount = new Intl.NumberFormat('en-NG', {
    style: 'currency',
    currency: reservation.price_snapshot.currency,
  }).format(reservation.price_snapshot.total_minor / 100);
  const expiresAt = new Date(reservation.hold.held_until).toLocaleString();

  return (
    <Card className="p-6 border-2 border-green-500 shadow-xl shadow-green-50">
      <div className="text-center mb-6">
        <CheckCircle2 aria-hidden="true" size={32} className="text-green-600 mx-auto mb-4" />
        <h3 className="text-xl font-bold text-gray-900 mb-2">Reservation held</h3>
        <p className="text-gray-600 text-sm">Complete payment before {expiresAt} to keep these dates.</p>
      </div>
      <dl className="bg-gray-50 rounded-xl p-5 mb-6 border border-gray-100">
        <div className="flex justify-between items-center mb-2">
          <dt className="text-gray-500 text-xs font-bold uppercase tracking-wider">Property</dt>
          <dd className="text-gray-900 font-semibold text-sm">{propertyTitle}</dd>
        </div>
        <div className="flex justify-between items-center pt-3 border-t border-gray-200">
          <dt className="text-gray-500 text-xs font-bold uppercase tracking-wider">Locked price</dt>
          <dd className="text-2xl font-black text-primary-600">{amount}</dd>
        </div>
      </dl>
      <Button onClick={onPay} loading={isPaying} className="w-full py-4 text-lg font-bold" size="lg">
        <CreditCard aria-hidden="true" size={20} />
        {isPaying ? 'Redirecting...' : 'Complete payment'}
      </Button>
    </Card>
  );
};
