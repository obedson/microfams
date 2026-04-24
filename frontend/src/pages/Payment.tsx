import React, { useEffect, useState } from 'react';
import { useSearchParams, useNavigate, useParams, Link } from 'react-router-dom';
import { apiClient } from '../api/client';
import { useAuthStore } from '../store/authStore';
import GroupFundPayment from '../components/bookings/GroupFundPayment';
import { CreditCard, ArrowLeft, ShieldCheck, Zap } from 'lucide-react';

declare global {
  interface Window {
    PaystackPop: any;
  }
}

export default function Payment() {
  const [searchParams] = useSearchParams();
  const { bookingId } = useParams();
  const navigate = useNavigate();
  const { user } = useAuthStore();
  const [loading, setLoading] = useState(true);
  const [booking, setBooking] = useState<any>(null);
  const [paymentMethod, setPaymentMethod] = useState<'paystack' | 'group' | null>(null);

  const type = searchParams.get('type');
  const id = searchParams.get('id');
  const amount = searchParams.get('amount');

  useEffect(() => {
    if (!user) {
      navigate('/login');
      return;
    }

    if (bookingId) {
      fetchBookingDetails();
    } else {
      setLoading(false);
    }
  }, [bookingId]);

  const fetchBookingDetails = async () => {
    try {
      const { data } = await apiClient.get(`/bookings/${bookingId}`);
      setBooking(data.data || data);
      setLoading(false);
    } catch (error) {
      console.error('Error fetching booking:', error);
      setLoading(false);
    }
  };

  const handlePaystackPayment = async () => {
    try {
      setLoading(true);
      
      if (!window.PaystackPop) {
        const script = document.createElement('script');
        script.src = 'https://js.paystack.co/v1/inline.js';
        script.async = true;
        document.body.appendChild(script);
        await new Promise((resolve) => { script.onload = resolve; });
      }

      const { data } = await apiClient.post('/payments/initialize', {
        booking_id: bookingId
      });

      const paymentInfo = data.data || data;

      const handler = window.PaystackPop.setup({
        key: process.env.REACT_APP_PAYSTACK_PUBLIC_KEY!,
        email: user?.email,
        amount: booking.total_amount * 100,
        ref: paymentInfo.reference,
        callback: (response: any) => {
          verifyBookingPayment(response.reference);
        },
        onClose: () => {
          setLoading(false);
        }
      });

      handler.openIframe();
    } catch (error: any) {
      console.error('Booking payment init error:', error);
      alert(error.response?.data?.error || 'Failed to initialize payment');
      setLoading(false);
    }
  };

  const verifyBookingPayment = async (reference: string) => {
    try {
      const { data } = await apiClient.get(`/payments/verify/${reference}`);
      if (!data.success) {
        alert('Payment could not be verified. Please contact support.');
      }
      navigate('/my-bookings');
    } catch (error) {
      console.error('Payment verification error:', error);
      alert('Payment verification failed. Please contact support.');
      navigate('/my-bookings');
    }
  };

  const initializeGroupPayment = async () => {
    try {
      setLoading(true);
      
      if (!window.PaystackPop) {
        const script = document.createElement('script');
        script.src = 'https://js.paystack.co/v1/inline.js';
        script.async = true;
        document.body.appendChild(script);
        await new Promise((resolve) => { script.onload = resolve; });
      }

      const { data } = await apiClient.post('/payments/initialize-group', {
        member_id: id,
        amount: Number(amount)
      });

      const handler = window.PaystackPop.setup({
        key: process.env.REACT_APP_PAYSTACK_PUBLIC_KEY!,
        email: user?.email,
        amount: Number(amount) * 100,
        ref: data.reference,
        callback: (response: any) => {
          verifyGroupJoinPayment(response.reference);
        },
        onClose: () => {
          setLoading(false);
        }
      });

      handler.openIframe();
    } catch (error: any) {
      console.error('Payment init error:', error);
      alert(error.response?.data?.error || 'Failed to initialize payment');
      setLoading(false);
    }
  };

  const verifyGroupJoinPayment = async (reference: string) => {
    try {
      await apiClient.post(`/groups/confirm-payment/${id}`);
      navigate('/groups');
    } catch (error) {
      console.error('Payment verification error:', error);
      alert('Payment verification failed. Please contact support.');
      navigate('/groups');
    }
  };

  if (loading) {
    return (
      <div className="max-w-md mx-auto px-4 py-20 text-center">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-primary-600 mx-auto"></div>
        <p className="mt-4 text-gray-600 font-medium">Preparing secure checkout...</p>
      </div>
    );
  }

  // Auto-redirect for group join payments (legacy behavior)
  if (!bookingId && type === 'contribution') {
    return (
      <div className="max-w-md mx-auto px-4 py-20 text-center">
        <h2 className="text-xl font-bold text-gray-900 mb-4">Complete Contribution</h2>
        <button 
          onClick={initializeGroupPayment}
          className="bg-primary-600 text-white px-8 py-3 rounded-lg font-bold hover:bg-primary-700 transition-colors"
        >
          Pay ₦{Number(amount).toLocaleString()} Now
        </button>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50 py-12 px-4">
      <div className="max-w-xl mx-auto">
        <button 
          onClick={() => navigate(-1)}
          className="flex items-center gap-2 text-gray-500 hover:text-gray-900 mb-8 font-medium transition-colors"
        >
          <ArrowLeft size={20} /> Back
        </button>

        <div className="bg-white rounded-2xl shadow-xl border border-gray-100 overflow-hidden">
          <div className="bg-primary-600 px-8 py-10 text-white">
            <h1 className="text-2xl font-black uppercase tracking-tight">Secure Payment</h1>
            <p className="text-primary-100 mt-2 font-medium opacity-90">
              Complete your booking for <span className="text-white font-bold">{booking?.properties?.title || 'Farm Property'}</span>
            </p>
            <div className="mt-6 flex items-baseline gap-1">
              <span className="text-primary-200 text-lg font-bold">₦</span>
              <span className="text-4xl font-black">{booking?.total_amount?.toLocaleString()}</span>
            </div>
          </div>

          <div className="p-8">
            <h3 className="text-sm font-bold text-gray-400 uppercase tracking-widest mb-6">Choose Payment Method</h3>
            
            <div className="space-y-4">
              <button
                onClick={() => setPaymentMethod('paystack')}
                className={`w-full flex items-center justify-between p-5 rounded-xl border-2 transition-all ${
                  paymentMethod === 'paystack' 
                    ? 'border-primary-600 bg-primary-50/30' 
                    : 'border-gray-100 hover:border-gray-200 bg-white'
                }`}
              >
                <div className="flex items-center gap-4">
                  <div className={`w-12 h-12 rounded-full flex items-center justify-center ${
                    paymentMethod === 'paystack' ? 'bg-primary-600 text-white' : 'bg-gray-100 text-gray-400'
                  }`}>
                    <CreditCard size={24} />
                  </div>
                  <div className="text-left">
                    <p className="font-bold text-gray-900">Card / Bank Transfer</p>
                    <p className="text-xs text-gray-500 font-medium mt-0.5">Secure payment via Paystack</p>
                  </div>
                </div>
                <div className={`w-6 h-6 rounded-full border-2 flex items-center justify-center ${
                  paymentMethod === 'paystack' ? 'border-primary-600' : 'border-gray-200'
                }`}>
                  {paymentMethod === 'paystack' && <div className="w-3 h-3 bg-primary-600 rounded-full" />}
                </div>
              </button>

              <button
                onClick={() => setPaymentMethod('group')}
                className={`w-full flex items-center justify-between p-5 rounded-xl border-2 transition-all ${
                  paymentMethod === 'group' 
                    ? 'border-primary-600 bg-primary-50/30' 
                    : 'border-gray-100 hover:border-gray-200 bg-white'
                }`}
              >
                <div className="flex items-center gap-4">
                  <div className={`w-12 h-12 rounded-full flex items-center justify-center ${
                    paymentMethod === 'group' ? 'bg-primary-600 text-white' : 'bg-gray-100 text-gray-400'
                  }`}>
                    <Zap size={24} />
                  </div>
                  <div className="text-left">
                    <div className="flex items-center gap-2">
                      <p className="font-bold text-gray-900">Group Funds</p>
                      <span className="bg-green-100 text-green-700 text-[10px] font-black px-1.5 py-0.5 rounded">SAVE UP TO 10%</span>
                    </div>
                    <p className="text-xs text-gray-500 font-medium mt-0.5">Pay using your contribution groups</p>
                  </div>
                </div>
                <div className={`w-6 h-6 rounded-full border-2 flex items-center justify-center ${
                  paymentMethod === 'group' ? 'border-primary-600' : 'border-gray-200'
                }`}>
                  {paymentMethod === 'group' && <div className="w-3 h-3 bg-primary-600 rounded-full" />}
                </div>
              </button>
            </div>

            {paymentMethod === 'paystack' && (
              <div className="mt-8 animate-in fade-in slide-in-from-top-4 duration-300">
                <button
                  onClick={handlePaystackPayment}
                  className="w-full bg-primary-600 text-white py-4 rounded-xl font-bold text-lg hover:bg-primary-700 shadow-lg shadow-primary-200 active:scale-[0.98] transition-all"
                >
                  Proceed to Pay ₦{booking?.total_amount?.toLocaleString()}
                </button>
                <div className="flex items-center justify-center gap-2 mt-6 text-gray-400">
                  <ShieldCheck size={16} />
                  <span className="text-xs font-bold uppercase tracking-wider">Secured by industry-standard encryption</span>
                </div>
              </div>
            )}

            {paymentMethod === 'group' && (
              <div className="animate-in fade-in slide-in-from-top-4 duration-300">
                <GroupFundPayment 
                  bookingId={bookingId!} 
                  bookingAmount={booking?.total_amount || 0} 
                  onSuccess={() => navigate('/my-bookings')} 
                />
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
