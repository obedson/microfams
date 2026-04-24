import React from 'react';

interface PendingPaymentBooking {
  id: string;
  reference_number: string;
  farmer_name: string;
  property_name: string;
  amount: number;
  created_at: Date;
  payment_timeout_at: Date;
  status: 'pending_payment';
}

interface PendingPaymentsProps {
  bookings: PendingPaymentBooking[];
  onBulkAction: (bookingIds: string[], action: string) => void;
  onSendReminder: (bookingId: string) => void;
}

const PendingPayments: React.FC<PendingPaymentsProps> = ({
  bookings,
  onBulkAction,
  onSendReminder
}) => {
  const [selectedBookings, setSelectedBookings] = React.useState<string[]>([]);

  const calculateDaysElapsed = (createdAt: Date): number => {
    const now = new Date();
    const diffTime = Math.abs(now.getTime() - createdAt.getTime());
    return Math.ceil(diffTime / (1000 * 60 * 60 * 24));
  };

  const isApproachingTimeout = (paymentTimeoutAt: Date): boolean => {
    const now = new Date();
    const hoursUntilTimeout = (paymentTimeoutAt.getTime() - now.getTime()) / (1000 * 60 * 60);
    return hoursUntilTimeout <= 48 && hoursUntilTimeout > 0;
  };

  const formatCurrency = (amount: number) => {
    return new Intl.NumberFormat('en-NG', {
      style: 'currency',
      currency: 'NGN'
    }).format(amount);
  };

  const handleSelectAll = (checked: boolean) => {
    if (checked) {
      setSelectedBookings(bookings.map(b => b.id));
    } else {
      setSelectedBookings([]);
    }
  };

  const handleSelectBooking = (bookingId: string, checked: boolean) => {
    if (checked) {
      setSelectedBookings(prev => [...prev, bookingId]);
    } else {
      setSelectedBookings(prev => prev.filter(id => id !== bookingId));
    }
  };

  const handleBulkAction = (action: string) => {
    if (selectedBookings.length > 0) {
      onBulkAction(selectedBookings, action);
      setSelectedBookings([]);
    }
  };

  const totalPendingRevenue = bookings.reduce((sum, booking) => sum + booking.amount, 0);

  return (
    <div className="pending-payments-section">
      <div className="section-header">
        <h3>Pending Payment Bookings</h3>
        <div className="pending-revenue">
          Potential Revenue: {formatCurrency(totalPendingRevenue)}
        </div>
      </div>

      {bookings.length === 0 ? (
        <div className="no-pending-payments">
          No pending payment bookings
        </div>
      ) : (
        <>
          {/* Bulk Actions */}
          <div className="bulk-actions">
            <label className="select-all">
              <input
                type="checkbox"
                checked={selectedBookings.length === bookings.length}
                onChange={(e) => handleSelectAll(e.target.checked)}
              />
              Select All ({bookings.length})
            </label>
            
            {selectedBookings.length > 0 && (
              <div className="action-buttons">
                <button 
                  onClick={() => handleBulkAction('send_reminders')}
                  className="bulk-action-btn reminder"
                >
                  Send Reminders ({selectedBookings.length})
                </button>
                <button 
                  onClick={() => handleBulkAction('cancel_bookings')}
                  className="bulk-action-btn cancel"
                >
                  Cancel Selected ({selectedBookings.length})
                </button>
              </div>
            )}
          </div>

          {/* Pending Bookings List */}
          <div className="pending-bookings-list">
            {bookings.map((booking) => {
              const daysElapsed = calculateDaysElapsed(booking.created_at);
              const isTimeout = isApproachingTimeout(booking.payment_timeout_at);
              
              return (
                <div 
                  key={booking.id} 
                  className={`pending-booking-item ${isTimeout ? 'timeout-warning' : ''}`}
                >
                  <div className="booking-select">
                    <input
                      type="checkbox"
                      checked={selectedBookings.includes(booking.id)}
                      onChange={(e) => handleSelectBooking(booking.id, e.target.checked)}
                    />
                  </div>

                  <div className="booking-info">
                    <div className="booking-header">
                      <span className="reference">{booking.reference_number}</span>
                      {isTimeout && (
                        <span className="timeout-badge">Payment Timeout Soon</span>
                      )}
                    </div>
                    
                    <div className="booking-details">
                      <div className="farmer">Farmer: {booking.farmer_name}</div>
                      <div className="property">Property: {booking.property_name}</div>
                      <div className="amount">Amount: {formatCurrency(booking.amount)}</div>
                    </div>

                    <div className="booking-timing">
                      <span className="days-elapsed">
                        {daysElapsed} day{daysElapsed !== 1 ? 's' : ''} elapsed
                      </span>
                    </div>
                  </div>

                  <div className="booking-actions">
                    <button 
                      onClick={() => onSendReminder(booking.id)}
                      className="action-btn reminder"
                    >
                      Send Reminder
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
};

export default PendingPayments;
