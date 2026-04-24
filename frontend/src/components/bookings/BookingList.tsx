import React from 'react';
import BookingCard from './BookingCard';

interface BookingListProps {
  bookings: any[];
  type: 'farmer' | 'owner';
  isLoading?: boolean;
  onCancel?: (booking: any) => void;
  onApprove?: (booking: any) => void;
  onReject?: (booking: any) => void;
  onContact?: (booking: any) => void;
  onRetryPayment?: (booking: any) => void;
}

const BookingList: React.FC<BookingListProps> = ({
  bookings,
  type,
  isLoading,
  onCancel,
  onApprove,
  onReject,
  onContact,
  onRetryPayment
}) => {
  if (isLoading) {
    return (
      <div className="flex justify-center items-center py-12">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-green-600"></div>
      </div>
    );
  }

  if (bookings.length === 0) {
    return (
      <div className="bg-white rounded-lg shadow p-12 text-center">
        <div className="text-gray-400 mb-4">
          <svg
            className="mx-auto h-16 w-16"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"
            />
          </svg>
        </div>
        <h3 className="text-lg font-medium text-gray-900 mb-2">No bookings found</h3>
        <p className="text-gray-500">
          {type === 'farmer' 
            ? 'You haven\'t made any bookings yet. Browse properties to get started!'
            : 'No bookings have been made on your properties yet.'}
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {bookings.map((booking) => (
        <BookingCard
          key={booking.id}
          booking={booking}
          type={type}
          onCancel={onCancel}
          onApprove={onApprove}
          onReject={onReject}
          onContact={onContact}
          onRetryPayment={onRetryPayment}
        />
      ))}
    </div>
  );
};

export default BookingList;
