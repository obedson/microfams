import React from 'react';
import { useQuery } from '@tanstack/react-query';
import { bookingAPI } from '../api/client';

const MyBookings: React.FC = () => {
  const { data, isLoading } = useQuery({
    queryKey: ['my-bookings'],
    queryFn: bookingAPI.getMyBookings
  });

  if (isLoading) return <div>Loading bookings...</div>;

  const bookings = data?.data?.data || [];

  return (
    <div>
      <h2>My Bookings</h2>
      {bookings.length === 0 ? (
        <p>No bookings yet.</p>
      ) : (
        <div>
          {bookings.map((booking: any) => (
            <div key={booking.id} style={{ border: '1px solid #ccc', padding: '1rem', margin: '1rem 0' }}>
              <h3>{booking.properties?.title || 'Property'}</h3>
              <p><strong>Property Owner:</strong> {booking.properties?.users?.name || 'N/A'}</p>
              {booking.status === 'confirmed' && (
                <>
                  <p><strong>Owner Email:</strong> {booking.properties?.users?.email || 'N/A'}</p>
                  <p><strong>Owner Phone:</strong> {booking.properties?.users?.phone || 'N/A'}</p>
                </>
              )}
              <p><strong>Location:</strong> {booking.properties?.city}</p>
              <p><strong>Dates:</strong> {booking.start_date} to {booking.end_date}</p>
              <p><strong>Amount:</strong> ₦{booking.total_amount.toLocaleString()}</p>
              <p><strong>Status:</strong> 
                <span style={{ 
                  color: booking.status === 'confirmed' ? 'green' : 
                        booking.status === 'cancelled' ? 'red' : 'orange' 
                }}>
                  {booking.status}
                </span>
              </p>
              <p><strong>Payment:</strong> 
                <span style={{ 
                  color: booking.payment_status === 'paid' ? 'green' : 'orange' 
                }}>
                  {booking.payment_status}
                </span>
              </p>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default MyBookings;
