import React from 'react';
import { Calendar, MapPin, User, DollarSign, Clock, CheckCircle, AlertCircle, XCircle } from 'lucide-react';
import { MessageButton } from '../communication';
import { useAuthStore } from '../../store/authStore';
import '../communication/Communication.css';

interface BookingCardProps {
  booking: any;
  type: 'farmer' | 'owner';
  onCancel?: (booking: any) => void;
  onApprove?: (booking: any) => void;
  onReject?: (booking: any) => void;
  onContact?: (booking: any) => void;
  onRetryPayment?: (booking: any) => void;
}

const BookingCard: React.FC<BookingCardProps> = ({
  booking,
  type,
  onCancel,
  onApprove,
  onReject,
  onContact,
  onRetryPayment
}) => {
  const { user: currentUser } = useAuthStore();
  const getStatusColor = (status: string) => {
    switch (status) {
      case 'confirmed': return 'bg-green-100 text-green-800';
      case 'pending': return 'bg-yellow-100 text-yellow-800';
      case 'pending_payment': return 'bg-orange-100 text-orange-800';
      case 'cancelled': return 'bg-red-100 text-red-800';
      case 'completed': return 'bg-blue-100 text-blue-800';
      default: return 'bg-gray-100 text-gray-800';
    }
  };

  const getPaymentColor = (payment_status: string) => {
    switch (payment_status) {
      case 'paid': return 'bg-green-100 text-green-800';
      case 'pending': return 'bg-yellow-100 text-yellow-800';
      case 'failed': return 'bg-red-100 text-red-800';
      default: return 'bg-gray-100 text-gray-800';
    }
  };

  const formatDate = (date: string) => {
    return new Date(date).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric'
    });
  };

  // Property 4: Timeline Status Progression
  const getTimelineSteps = () => {
    const steps = [
      { key: 'created', label: 'Created', icon: Clock },
      { key: 'payment', label: 'Payment', icon: DollarSign },
      { key: 'pending', label: 'Pending Approval', icon: AlertCircle },
      { key: 'confirmed', label: 'Confirmed', icon: CheckCircle },
      { key: 'completed', label: 'Completed', icon: CheckCircle }
    ];

    const currentStep = booking.status === 'pending_payment' ? 'payment' :
                       booking.status === 'pending' ? 'pending' :
                       booking.status === 'confirmed' ? 'confirmed' :
                       booking.status === 'completed' ? 'completed' :
                       booking.status === 'cancelled' ? 'cancelled' : 'created';

    return steps.map((step, index) => {
      let status = 'upcoming';
      if (booking.status === 'cancelled') {
        status = index === 0 ? 'completed' : 'cancelled';
      } else if (step.key === 'created') {
        status = 'completed';
      } else if (step.key === 'payment') {
        status = booking.payment_status === 'paid' ? 'completed' : 
                booking.payment_status === 'failed' ? 'failed' :
                booking.status === 'pending_payment' ? 'current' : 'upcoming';
      } else if (step.key === 'pending') {
        status = booking.status === 'pending' ? 'current' :
                ['confirmed', 'completed'].includes(booking.status) ? 'completed' : 'upcoming';
      } else if (step.key === 'confirmed') {
        status = booking.status === 'confirmed' ? 'current' :
                booking.status === 'completed' ? 'completed' : 'upcoming';
      } else if (step.key === 'completed') {
        status = booking.status === 'completed' ? 'completed' : 'upcoming';
      }

      return { ...step, status };
    });
  };

  const timelineSteps = getTimelineSteps();

  return (
    <div className="bg-white rounded-lg shadow-md hover:shadow-lg transition-shadow p-6">
      {/* Header */}
      <div className="flex justify-between items-start mb-4">
        <div className="flex-1">
          <h3 className="text-xl font-semibold text-gray-900 mb-2">
            {booking.properties?.title || 'Property'}
          </h3>
          {/* Property 2: Reference Number Display */}
          <div className="text-sm text-gray-500 mb-2">
            Booking Reference: <span className="font-mono font-medium text-gray-700">#{booking.id?.slice(-8)?.toUpperCase()}</span>
          </div>
          <div className="flex gap-2 flex-wrap">
            <span className={`px-3 py-1 rounded-full text-xs font-medium ${getStatusColor(booking.status)}`}>
              {booking.status?.replace('_', ' ')}
            </span>
            <span className={`px-3 py-1 rounded-full text-xs font-medium ${getPaymentColor(booking.payment_status)}`}>
              {booking.payment_status}
            </span>
          </div>
        </div>
        <div className="text-right">
          <p className="text-2xl font-bold text-green-600">
            ₦{booking.total_amount?.toLocaleString()}
          </p>
        </div>
      </div>

      {/* Property 4: Timeline Status Progression */}
      <div className="mb-6">
        <div className="flex items-center justify-between">
          {timelineSteps.map((step, index) => {
            const Icon = step.icon;
            const isLast = index === timelineSteps.length - 1;
            
            return (
              <div key={step.key} className="flex items-center flex-1">
                <div className="flex flex-col items-center">
                  <div className={`w-8 h-8 rounded-full flex items-center justify-center ${
                    step.status === 'completed' ? 'bg-green-500 text-white' :
                    step.status === 'current' ? 'bg-blue-500 text-white' :
                    step.status === 'failed' ? 'bg-red-500 text-white' :
                    step.status === 'cancelled' ? 'bg-gray-400 text-white' :
                    'bg-gray-200 text-gray-400'
                  }`}>
                    {step.status === 'cancelled' ? <XCircle size={16} /> : <Icon size={16} />}
                  </div>
                  <span className={`text-xs mt-1 text-center ${
                    step.status === 'completed' ? 'text-green-600 font-medium' :
                    step.status === 'current' ? 'text-blue-600 font-medium' :
                    step.status === 'failed' ? 'text-red-600 font-medium' :
                    'text-gray-400'
                  }`}>
                    {step.label}
                  </span>
                </div>
                {!isLast && (
                  <div className={`flex-1 h-0.5 mx-2 ${
                    step.status === 'completed' ? 'bg-green-500' :
                    step.status === 'failed' ? 'bg-red-500' :
                    'bg-gray-200'
                  }`} />
                )}
              </div>
            );
          })}
        </div>
      </div>

      {/* Details Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
        {/* Location */}
        <div className="flex items-start gap-2">
          <MapPin size={18} className="text-gray-400 mt-1" />
          <div>
            <p className="text-xs text-gray-500">Location</p>
            <p className="text-sm font-medium text-gray-900">
              {booking.properties?.city}, {booking.properties?.lga}
            </p>
          </div>
        </div>

        {/* Contact Person */}
        <div className="flex items-start gap-2">
          <User size={18} className="text-gray-400 mt-1" />
          <div>
            <p className="text-xs text-gray-500">
              {type === 'farmer' ? 'Property Owner' : 'Farmer'}
            </p>
            <p className="text-sm font-medium text-gray-900">
              {type === 'farmer' 
                ? booking.properties?.users?.name 
                : booking.users?.name}
            </p>
            {booking.status === 'confirmed' && (
              <p className="text-xs text-gray-600">
                {type === 'farmer'
                  ? booking.properties?.users?.phone
                  : booking.users?.phone}
              </p>
            )}
          </div>
        </div>

        {/* Check-in */}
        <div className="flex items-start gap-2">
          <Calendar size={18} className="text-gray-400 mt-1" />
          <div>
            <p className="text-xs text-gray-500">Check-in</p>
            <p className="text-sm font-medium text-gray-900">
              {formatDate(booking.start_date)}
            </p>
          </div>
        </div>

        {/* Check-out */}
        <div className="flex items-start gap-2">
          <Calendar size={18} className="text-gray-400 mt-1" />
          <div>
            <p className="text-xs text-gray-500">Check-out</p>
            <p className="text-sm font-medium text-gray-900">
              {formatDate(booking.end_date)}
            </p>
          </div>
        </div>
      </div>

      {/* Notes */}
      {booking.notes && (
        <div className="bg-blue-50 border border-blue-200 rounded-lg p-3 mb-4">
          <p className="text-xs text-blue-600 font-medium mb-1">Notes</p>
          <p className="text-sm text-blue-900">{booking.notes}</p>
        </div>
      )}

      {/* Rejection Reason */}
      {booking.rejection_reason && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-3 mb-4">
          <p className="text-xs text-red-600 font-medium mb-1">Rejection Reason</p>
          <p className="text-sm text-red-900">{booking.rejection_reason}</p>
        </div>
      )}

      {/* Actions */}
      <div className="flex gap-2 flex-wrap pt-4 border-t">
        {/* Farmer Actions */}
        {type === 'farmer' && (
          <>
            {/* Property 3: Payment Button Visibility */}
            {booking.status === 'pending_payment' && booking.payment_status !== 'paid' && (
              <button
                onClick={() => window.location.href = `/payment/${booking.id}`}
                className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 text-sm font-medium flex items-center gap-2"
              >
                <DollarSign size={16} />
                Complete Payment
              </button>
            )}
            {booking.payment_status === 'failed' && onRetryPayment && (
              <button
                onClick={() => onRetryPayment(booking)}
                className="px-4 py-2 bg-orange-600 text-white rounded-lg hover:bg-orange-700 text-sm font-medium flex items-center gap-2"
              >
                <AlertCircle size={16} />
                Retry Payment
              </button>
            )}
            {(booking.status === 'pending' || booking.status === 'confirmed') && onCancel && (
              <button
                onClick={() => onCancel(booking)}
                className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 text-sm font-medium"
              >
                Cancel Booking
              </button>
            )}
            {(booking.status === 'confirmed' || booking.status === 'pending') && currentUser && (
              <MessageButton
                userType="farmer"
                bookingStatus={booking.status}
                bookingId={booking.id}
                currentUserId={currentUser.id}
                currentUserName={currentUser.name}
                recipientId={booking.properties?.owner_id}
                recipientName={booking.properties?.users?.name || 'Property Owner'}
                recipientEmail={booking.properties?.users?.email}
                recipientPhone={booking.properties?.users?.phone}
                bookingReference={`#${booking.id?.slice(-8)?.toUpperCase()}`}
                propertyName={booking.properties?.title || 'Property'}
                onMessageClick={() => onContact?.(booking)}
              />
            )}
            {booking.payment_status === 'paid' && (
              <button
                onClick={async () => {
                  try {
                    const token = localStorage.getItem('token');
                    if (!token) {
                      alert('Please log in to download receipt');
                      return;
                    }

                    const apiUrl = process.env.REACT_APP_API_URL || 'http://localhost:3001/api';
                    
                    // Standard approach for authenticated file downloads:
                    // 1. Fetch the data
                    // 2. Handle potential redirect or blob
                    const response = await fetch(`${apiUrl}/receipts/${booking.id}/download`, {
                      headers: {
                        'Authorization': `Bearer ${token}`
                      },
                      redirect: 'follow' // Explicitly follow redirects
                    });

                    if (response.ok) {
                      const data = await response.json();
                      if (data.url) {
                        // Open S3 URL directly — no CORS issue
                        window.open(data.url, '_blank');
                      } else {
                        // Fallback: text receipt blob
                        const blob = await new Response(data).blob();
                        const url = window.URL.createObjectURL(blob);
                        const a = document.createElement('a');
                        a.href = url;
                        a.download = `receipt-${booking.id.slice(-8)}.txt`;
                        document.body.appendChild(a);
                        a.click();
                        window.URL.revokeObjectURL(url);
                        document.body.removeChild(a);
                      }
                    } else {
                      const error = await response.json();
                      alert(`Error: ${error.error || 'Failed to download receipt'}`);
                    }
                  } catch (error) {
                    console.error('Receipt download error:', error);
                    alert('Failed to download receipt. Please try again.');
                  }
                }}
                className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 text-sm font-medium flex items-center gap-2 transition-colors"
              >
                <DollarSign size={16} />
                Download Receipt
              </button>
            )}
          </>
        )}

        {/* Owner Actions */}
        {type === 'owner' && (
          <>
            {booking.status === 'pending' && booking.payment_status === 'paid' && (
              <>
                {onApprove && (
                  <button
                    onClick={() => onApprove(booking)}
                    className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 text-sm font-medium"
                  >
                    Approve
                  </button>
                )}
                {onReject && (
                  <button
                    onClick={() => onReject(booking)}
                    className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 text-sm font-medium"
                  >
                    Reject
                  </button>
                )}
              </>
            )}
            {onContact && currentUser && (
              <MessageButton
                userType="owner"
                bookingStatus={booking.status}
                bookingId={booking.id}
                currentUserId={currentUser.id}
                currentUserName={currentUser.name}
                recipientId={booking.farmer_id}
                recipientName={booking.users?.name || 'Farmer'}
                recipientEmail={booking.users?.email}
                recipientPhone={booking.users?.phone}
                bookingReference={`#${booking.id?.slice(-8)?.toUpperCase()}`}
                propertyName={booking.properties?.title || 'Property'}
                onMessageClick={() => onContact?.(booking)}
              />
            )}
          </>
        )}
      </div>

      {/* Timestamps */}
      <div className="flex items-center gap-4 mt-4 pt-4 border-t text-xs text-gray-500">
        <div className="flex items-center gap-1">
          <Clock size={14} />
          <span>Created: {formatDate(booking.created_at)}</span>
        </div>
        {booking.cancelled_at && (
          <div className="flex items-center gap-1">
            <Clock size={14} />
            <span>Cancelled: {formatDate(booking.cancelled_at)}</span>
          </div>
        )}
      </div>
    </div>
  );
};

export default BookingCard;
