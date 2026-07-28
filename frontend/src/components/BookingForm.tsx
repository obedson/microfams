import React, { useState, useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Calendar, AlertCircle, CheckCircle2, ArrowRight } from 'lucide-react';
import { bookingAPI, paymentAPI } from '../api/client';
import { useAuthStore } from '../store/authStore';
import Button from './ui/Button';
import Card from './ui/Card';
import { ReservationConfirmation } from './bookings/ReservationConfirmation';

interface BookingFormProps {
  property: any;
  onSuccess: () => void;
}

interface BookingForm {
  start_date: string;
  end_date: string;
}

const BookingForm: React.FC<BookingFormProps> = ({ property }) => {
  const { register, handleSubmit, watch, setValue, formState: { errors } } = useForm<BookingForm>();
  const { isAuthenticated } = useAuthStore();
  const queryClient = useQueryClient();
  const [reservation, setReservation] = useState<any | null>(null);
  const [disabledDates, setDisabledDates] = useState<string[]>([]);
  const [conflictInfo, setConflictInfo] = useState<{ dates: string[], suggestion: any } | null>(null);

  const { data: bookedDatesData } = useQuery(
    ['bookedDates', property.id],
    () => bookingAPI.getBookedDates(property.id),
    { enabled: !!property.id }
  );

  const nextAvailable = bookedDatesData?.data?.suggestion;

  useEffect(() => {
    if (bookedDatesData?.data?.data) {
      const dates: string[] = [];
      bookedDatesData.data.data.forEach((booking: any) => {
        const start = new Date(booking.start_date);
        const end = new Date(booking.end_date);
        // Include both start and end in disabled dates
        for (let d = new Date(start); d <= end; d.setDate(d.getDate() + 1)) {
          dates.push(d.toISOString().split('T')[0]);
        }
      });
      setDisabledDates(dates);
    }
  }, [bookedDatesData]);

  const startDate = watch('start_date');
  const endDate = watch('end_date');

  // Clear conflict when dates change
  useEffect(() => {
    if (conflictInfo) setConflictInfo(null);
  }, [startDate, endDate]);

  const calculateTotal = () => {
    if (!startDate || !endDate) return 0;
    const start = new Date(startDate);
    const end = new Date(endDate);
    const days = Math.ceil((end.getTime() - start.getTime()) / (1000 * 60 * 60 * 24));
    const months = Math.ceil(days / 30);
    return months * property.price_per_month;
  };

  const bookingMutation = useMutation(
    (request: { data: any; idempotencyKey: string }) => bookingAPI.create(request.data, request.idempotencyKey),
    {
      onSuccess: (response) => {
        setReservation(response.data.data);
        queryClient.invalidateQueries(['bookedDates', property.id]);
      },
      onError: (err: any) => {
        if (err.response?.status === 409 && err.response?.data?.error === 'BOOKING_DATES_UNAVAILABLE') {
          setConflictInfo({ dates: ['The selected dates are no longer available.'], suggestion: err.response.data.suggestion });
        }
      }
    }
  );

  const handleApplySuggestion = () => {
    if (conflictInfo?.suggestion) {
      setValue('start_date', conflictInfo.suggestion.start_date);
      setValue('end_date', conflictInfo.suggestion.end_date);
      setConflictInfo(null);
    } else if (nextAvailable) {
      setValue('start_date', nextAvailable.start_date);
      setValue('end_date', nextAvailable.end_date);
    }
  };

  const paymentMutation = useMutation(
    (bookingId: string) => paymentAPI.initialize(bookingId),
    {
      onSuccess: (response) => {
        const { authorization_url } = response.data.data;
        window.location.href = authorization_url;
      },
    }
  );

  const onSubmit = (data: BookingForm) => {
    const bookingData = {
      property_id: property.id,
      start_date: data.start_date,
      end_date: data.end_date,
    };
    bookingMutation.mutate({ data: bookingData, idempotencyKey: window.crypto.randomUUID() });
  };

  const handlePayment = () => {
    if (reservation?.booking?.id) {
      paymentMutation.mutate(reservation.booking.id);
    }
  };

  if (!isAuthenticated) {
    return (
      <Card className="p-6 text-center border-2 border-primary-100">
        <div className="w-16 h-16 bg-primary-50 rounded-full flex items-center justify-center mx-auto mb-4">
          <CheckCircle2 size={32} className="text-primary-600" />
        </div>
        <h3 className="text-lg font-bold text-gray-900 mb-2">
          Start Your Journey
        </h3>
        <p className="text-gray-600 text-sm mb-6">
          Log in to secure your dates and coordinate with the farm owner.
        </p>
        <Button className="w-full" onClick={() => window.location.href = '/login'}>Sign In to Book</Button>
      </Card>
    );
  }

  if (reservation) {
    return (
      <ReservationConfirmation
        reservation={reservation}
        propertyTitle={property.title}
        onPay={handlePayment}
        isPaying={paymentMutation.isLoading}
      />
    );
  }

  const total = calculateTotal();

  return (
    <Card className="p-6 border border-gray-100 shadow-sm overflow-hidden relative">
      <div className="mb-6">
        <h3 className="text-xl font-black text-gray-900 mb-1 uppercase tracking-tight">Book Now</h3>
        <div className="flex items-center text-primary-600">
          <span className="text-2xl font-black">₦{property.price_per_month?.toLocaleString()}</span>
          <span className="text-gray-500 text-sm font-bold ml-1">/ Month</span>
        </div>
      </div>

      <form onSubmit={handleSubmit(onSubmit)} className="space-y-5">
        {/* Availability Alerts */}
        {conflictInfo ? (
          <div className="bg-red-50 border border-red-100 rounded-xl p-4 space-y-3">
            <div className="flex items-start gap-2">
              <AlertCircle className="text-red-600 flex-shrink-0 mt-0.5" size={18} />
              <div>
                <p className="text-red-900 text-sm font-bold">Booking Conflict</p>
                <p className="text-red-700 text-xs mt-1 leading-relaxed">
                  This property is already reserved during:
                  <ul className="list-disc ml-4 mt-1 font-semibold">
                    {conflictInfo.dates.map((d, i) => <li key={i}>{d}</li>)}
                  </ul>
                </p>
              </div>
            </div>
            {conflictInfo.suggestion && (
              <button
                type="button"
                onClick={handleApplySuggestion}
                className="w-full bg-white border border-red-200 text-red-700 py-2 rounded-lg text-xs font-bold flex items-center justify-center gap-2 hover:bg-red-50 transition-colors"
              >
                Switch to Next Available: {new Date(conflictInfo.suggestion.start_date).toLocaleDateString()} <ArrowRight size={14} />
              </button>
            )}
          </div>
        ) : disabledDates.length > 0 ? (
          <div className="bg-amber-50 border border-amber-100 rounded-xl p-4">
            <div className="flex items-start gap-2">
              <Calendar className="text-amber-600 flex-shrink-0 mt-0.5" size={18} />
              <div>
                <p className="text-amber-900 text-sm font-bold">Partial Availability</p>
                <p className="text-amber-700 text-xs mt-1 leading-relaxed">
                  Some days are booked. Check the highlighted dates below before selecting.
                </p>
              </div>
            </div>
          </div>
        ) : nextAvailable && (
          <div className="bg-green-50 border border-green-100 rounded-xl p-4 flex items-center justify-between">
            <div className="flex items-center gap-2 text-green-800">
              <CheckCircle2 size={18} />
              <span className="text-xs font-bold uppercase tracking-tight">Available Now</span>
            </div>
            <button 
              type="button"
              onClick={handleApplySuggestion}
              className="text-[10px] font-black text-green-700 bg-white px-2 py-1 rounded border border-green-200 hover:bg-green-50"
            >
              FAST BOOK NEXT SLOT
            </button>
          </div>
        )}

        <div>
          <label className="block text-xs font-bold text-gray-500 uppercase mb-2 tracking-widest">
            Pick Start Date
          </label>
          <div className="relative">
            <Calendar size={18} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" />
            <input
              {...register('start_date', { required: 'Start date is required' })}
              type="date"
              min={new Date().toISOString().split('T')[0]}
              className={`w-full pl-10 pr-4 py-3 bg-gray-50 border-2 rounded-xl focus:ring-0 focus:border-primary-500 outline-none transition-all font-semibold ${
                errors.start_date ? 'border-red-200' : 'border-gray-50'
              }`}
            />
          </div>
          {errors.start_date && (
            <p className="mt-1 text-[10px] font-bold text-red-600 uppercase">{errors.start_date.message}</p>
          )}
        </div>

        <div>
          <label className="block text-xs font-bold text-gray-500 uppercase mb-2 tracking-widest">
            Pick End Date
          </label>
          <div className="relative">
            <Calendar size={18} className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400" />
            <input
              {...register('end_date', { required: 'End date is required' })}
              type="date"
              min={startDate || new Date().toISOString().split('T')[0]}
              className={`w-full pl-10 pr-4 py-3 bg-gray-50 border-2 rounded-xl focus:ring-0 focus:border-primary-500 outline-none transition-all font-semibold ${
                errors.end_date ? 'border-red-200' : 'border-gray-50'
              }`}
            />
          </div>
          {errors.end_date && (
            <p className="mt-1 text-[10px] font-bold text-red-600 uppercase">{errors.end_date.message}</p>
          )}
        </div>

        {total > 0 && (
          <div className="bg-primary-600 rounded-xl p-4 text-white shadow-lg shadow-primary-100 flex justify-between items-center animate-in zoom-in-95">
            <div>
              <p className="text-[10px] font-bold opacity-80 uppercase tracking-widest">Total Estimate</p>
              <p className="text-2xl font-black">₦{total.toLocaleString()}</p>
            </div>
            <ArrowRight size={24} className="opacity-50" />
          </div>
        )}

        {bookingMutation.isError && !conflictInfo && (
          <div className="bg-red-50 border border-red-100 rounded-xl p-3 flex gap-2">
            <AlertCircle className="text-red-600 flex-shrink-0" size={18} />
            <p className="text-red-800 text-[11px] font-bold leading-tight">
              {(bookingMutation.error as any)?.response?.data?.message || 'The system encountered an error. Please refresh and try again.'}
            </p>
          </div>
        )}

        <Button
          type="submit"
          loading={bookingMutation.isLoading}
          className="w-full py-4 rounded-xl shadow-md active:scale-[0.98] transition-all font-black text-lg"
          size="lg"
        >
          {bookingMutation.isLoading ? 'Processing...' : 'Reserve Property'}
        </Button>
      </form>

      <p className="mt-4 text-[10px] font-bold text-gray-400 text-center uppercase tracking-widest">
        Secure checkout powered by Paystack
      </p>
    </Card>
  );
};

export default BookingForm;

