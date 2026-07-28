import React from 'react';

interface Props {
  startDate: string;
  paymentStatus: string;
  now?: Date;
}

const CancellationPolicyNotice: React.FC<Props> = ({ startDate, paymentStatus, now = new Date() }) => {
  if (paymentStatus !== 'paid') {
    return <p role="note" className="mb-4 text-sm text-gray-600">No refund is required for an unpaid booking.</p>;
  }
  const startsAfterToday = new Date(`${startDate}T00:00:00`) > now;
  return (
    <p role="note" className="mb-4 text-sm text-gray-600">
      {startsAfterToday
        ? 'The remaining paid amount will be submitted for refund after cancellation.'
        : 'The booking will be cancelled now; any refund requires an independent review.'}
    </p>
  );
};

export default CancellationPolicyNotice;
