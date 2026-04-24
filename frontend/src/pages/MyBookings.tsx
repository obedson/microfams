import React, { useState, useEffect } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { bookingAPI } from '../api/client';
import BookingList from '../components/bookings/BookingList';
import BookingFilters from '../components/bookings/BookingFilters';
import BookingCalendar from '../components/bookings/BookingCalendar';
import { X, RefreshCcw } from 'lucide-react';
import axios from 'axios';
import toast from 'react-hot-toast';
import { supabase, isConfigured } from '../api/supabase';

const API_URL = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

const MyBookings: React.FC = () => {
  // Property 1: Booking Tab Organization + Calendar View
  const [activeView, setActiveView] = useState<'list' | 'calendar'>('list');
  const [activeTab, setActiveTab] = useState<'upcoming' | 'past' | 'cancelled'>('upcoming');
  
  // Task 5.3: Advanced filtering state
  const [statusFilter, setStatusFilter] = useState('all');
  const [paymentStatusFilter, setPaymentStatusFilter] = useState('all');
  const [dateRangeFilter, setDateRangeFilter] = useState<{ start: string; end: string }>({ start: '', end: '' });
  const [searchQuery, setSearchQuery] = useState('');
  
  // Calendar state
  const [selectedDate, setSelectedDate] = useState<Date | null>(null);
  const [selectedDateBookings, setSelectedDateBookings] = useState<any[]>([]);
  const [showDateModal, setShowDateModal] = useState(false);
  
  const [selectedBooking, setSelectedBooking] = useState<any>(null);
  const [showCancelModal, setShowCancelModal] = useState(false);
  const [cancelReason, setCancelReason] = useState('');
  const queryClient = useQueryClient();

  // Real-time subscription
  useEffect(() => {
    if (!isConfigured) return;

    const channel = supabase
      .channel('booking-status-changes')
      .on(
        'postgres_changes',
        {
          event: 'UPDATE',
          schema: 'public',
          table: 'bookings'
        },
        (payload: { new: any; old: any }) => {
          console.log('Real-time booking update:', payload);
          queryClient.invalidateQueries({ queryKey: ['my-bookings'] });
          
          // Show toast if status changed to confirmed
          if (payload.new.status === 'confirmed' && payload.old.status !== 'confirmed') {
            toast.success('Your booking was just confirmed!', {
              icon: '🎉',
              duration: 5000
            });
          }
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [queryClient]);

  const { data, isLoading, isFetching } = useQuery({
    queryKey: ['my-bookings'],
    queryFn: bookingAPI.getMyBookings,
    staleTime: 30000 // Consider data fresh for 30 seconds
  });

  const cancelMutation = useMutation({
    mutationFn: async ({ id, reason }: { id: string; reason: string }) => {
      const token = localStorage.getItem('token');
      await axios.put(
        `${API_URL}/bookings/${id}/cancel`,
        { reason },
        { headers: { Authorization: `Bearer ${token}` } }
      );
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['my-bookings'] });
      setShowCancelModal(false);
      setSelectedBooking(null);
      setCancelReason('');
      toast.success('Booking cancelled successfully');
    },
    onError: () => {
      toast.error('Failed to cancel booking');
    }
  });

  const retryPaymentMutation = useMutation({
    mutationFn: async (bookingId: string) => {
      const token = localStorage.getItem('token');
      const response = await axios.post(
        `${API_URL}/bookings/${bookingId}/retry-payment`,
        {},
        { headers: { Authorization: `Bearer ${token}` } }
      );
      return response.data;
    },
    onSuccess: (data) => {
      if (data.payment_url) {
        window.location.href = data.payment_url;
      }
    },
    onError: () => {
      toast.error('Failed to retry payment');
    }
  });

  const bookings = data?.data?.data || [];
  
  // Property 1: Booking Tab Organization - categorize bookings
  const categorizeBookings = (bookings: any[]) => {
    const now = new Date();
    
    return {
      upcoming: bookings.filter(b => {
        const endDate = new Date(b.end_date);
        return ['pending_payment', 'pending', 'confirmed'].includes(b.status) && endDate >= now;
      }),
      past: bookings.filter(b => {
        const endDate = new Date(b.end_date);
        return b.status === 'completed' || (endDate < now && b.status !== 'cancelled');
      }),
      cancelled: bookings.filter(b => b.status === 'cancelled')
    };
  };

  const categorizedBookings = categorizeBookings(bookings);
  const currentBookings = categorizedBookings[activeTab];
  
  // Task 5.3: Advanced filtering logic
  const applyFilters = (bookings: any[]) => {
    let filtered = bookings;

    // Status filter
    if (statusFilter !== 'all') {
      filtered = filtered.filter(b => b.status === statusFilter);
    }

    // Payment status filter
    if (paymentStatusFilter !== 'all') {
      filtered = filtered.filter(b => b.payment_status === paymentStatusFilter);
    }

    // Date range filter
    if (dateRangeFilter.start) {
      filtered = filtered.filter(b => new Date(b.start_date) >= new Date(dateRangeFilter.start));
    }
    if (dateRangeFilter.end) {
      filtered = filtered.filter(b => new Date(b.end_date) <= new Date(dateRangeFilter.end));
    }

    // Search filter
    if (searchQuery.trim()) {
      const query = searchQuery.toLowerCase();
      filtered = filtered.filter(b => 
        b.users?.name?.toLowerCase().includes(query) ||
        b.properties?.users?.name?.toLowerCase().includes(query) ||
        b.id?.toLowerCase().includes(query) ||
        b.properties?.title?.toLowerCase().includes(query)
      );
    }

    return filtered;
  };

  const filteredBookings = applyFilters(currentBookings);

  const handleCancel = (booking: any) => {
    setSelectedBooking(booking);
    setShowCancelModal(true);
  };

  const handleContact = (booking: any) => {
    const ownerEmail = booking.properties?.users?.email;
    const ownerPhone = booking.properties?.users?.phone;
    
    if (ownerEmail) {
      window.location.href = `mailto:${ownerEmail}?subject=Booking Inquiry - ${booking.properties?.title}`;
    } else if (ownerPhone) {
      window.location.href = `tel:${ownerPhone}`;
    }
  };

  const handleRetryPayment = (booking: any) => {
    retryPaymentMutation.mutate(booking.id);
  };

  // Task 5.3: Filter management
  const handleClearFilters = () => {
    setStatusFilter('all');
    setPaymentStatusFilter('all');
    setDateRangeFilter({ start: '', end: '' });
    setSearchQuery('');
  };

  // Task 5.5: Calendar date click handler
  const handleDateClick = (date: Date, dayBookings: any[]) => {
    setSelectedDate(date);
    setSelectedDateBookings(dayBookings);
    setShowDateModal(true);
  };

  const submitCancel = () => {
    if (selectedBooking && cancelReason.trim()) {
      cancelMutation.mutate({
        id: selectedBooking.id,
        reason: cancelReason
      });
    }
  };

  // Tab configuration
  const tabs = [
    { key: 'upcoming' as const, label: 'Upcoming', count: categorizedBookings.upcoming.length },
    { key: 'past' as const, label: 'Past', count: categorizedBookings.past.length },
    { key: 'cancelled' as const, label: 'Cancelled', count: categorizedBookings.cancelled.length }
  ];

  // View configuration
  const views = [
    { key: 'list' as const, label: 'List View' },
    { key: 'calendar' as const, label: 'Calendar View' }
  ];

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      <div className="mb-8 flex justify-between items-end">
        <div>
          <h1 className="text-3xl font-bold text-gray-900 mb-2">My Bookings</h1>
          <p className="text-gray-600">View and manage your property bookings</p>
        </div>
        {isFetching && !isLoading && (
          <div className="flex items-center gap-2 text-primary-600 text-sm font-bold bg-primary-50 px-3 py-1 rounded-full animate-pulse">
            <RefreshCcw size={14} className="animate-spin" />
            Live Syncing...
          </div>
        )}
      </div>

      {/* Property 1: Booking Tab Organization + View Toggle */}
      <div className="bg-white rounded-lg shadow mb-6">
        <div className="border-b border-gray-200">
          <div className="flex justify-between items-center px-6">
            <nav className="-mb-px flex space-x-8">
              {tabs.map((tab) => (
                <button
                  key={tab.key}
                  onClick={() => setActiveTab(tab.key)}
                  className={`py-4 px-1 border-b-2 font-medium text-sm whitespace-nowrap ${
                    activeTab === tab.key
                      ? 'border-green-500 text-green-600'
                      : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'
                  }`}
                >
                  {tab.label}
                  <span className={`ml-2 py-0.5 px-2 rounded-full text-xs ${
                    activeTab === tab.key
                      ? 'bg-green-100 text-green-600'
                      : 'bg-gray-100 text-gray-600'
                  }`}>
                    {tab.count}
                  </span>
                </button>
              ))}
            </nav>
            
            {/* View Toggle */}
            <div className="flex bg-gray-100 rounded-lg p-1">
              {views.map((view) => (
                <button
                  key={view.key}
                  onClick={() => setActiveView(view.key)}
                  className={`px-3 py-1 rounded text-sm font-medium ${
                    activeView === view.key
                      ? 'bg-white text-gray-900 shadow-sm'
                      : 'text-gray-600 hover:text-gray-900'
                  }`}
                >
                  {view.label}
                </button>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Conditional rendering based on view */}
      {activeView === 'list' ? (
        <>
          <BookingFilters
            statusFilter={statusFilter}
            onStatusChange={setStatusFilter}
            type="farmer"
            paymentStatusFilter={paymentStatusFilter}
            onPaymentStatusChange={setPaymentStatusFilter}
            dateRangeFilter={dateRangeFilter}
            onDateRangeChange={setDateRangeFilter}
            searchQuery={searchQuery}
            onSearchChange={setSearchQuery}
            onClearFilters={handleClearFilters}
          />

          <BookingList
            bookings={filteredBookings}
            type="farmer"
            isLoading={isLoading}
            onCancel={handleCancel}
            onContact={handleContact}
            onRetryPayment={handleRetryPayment}
          />
        </>
      ) : (
        <BookingCalendar
          bookings={bookings}
          onDateClick={handleDateClick}
        />
      )}

      {/* Date Details Modal */}
      {showDateModal && selectedDate && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
          <div className="bg-white rounded-lg max-w-2xl w-full max-h-[80vh] overflow-y-auto">
            <div className="p-6">
              <div className="flex justify-between items-center mb-4">
                <h3 className="text-xl font-bold text-gray-900">
                  Bookings for {selectedDate.toLocaleDateString()}
                </h3>
                <button
                  onClick={() => setShowDateModal(false)}
                  className="text-gray-400 hover:text-gray-600"
                >
                  <X size={24} />
                </button>
              </div>
              
              {selectedDateBookings.length > 0 ? (
                <div className="space-y-4">
                  {selectedDateBookings.map((booking) => (
                    <div key={booking.id} className="border border-gray-200 rounded-lg p-4">
                      <div className="flex justify-between items-start">
                        <div>
                          <h4 className="font-semibold text-gray-900">
                            {booking.properties?.title || 'Property'}
                          </h4>
                          <p className="text-sm text-gray-600">
                            {new Date(booking.start_date).toLocaleDateString()} - {new Date(booking.end_date).toLocaleDateString()}
                          </p>
                          <div className="flex gap-2 mt-2">
                            <span className={`px-2 py-1 rounded-full text-xs font-medium ${
                              booking.status === 'confirmed' ? 'bg-green-100 text-green-800' :
                              booking.status === 'pending' ? 'bg-yellow-100 text-yellow-800' :
                              booking.status === 'pending_payment' ? 'bg-orange-100 text-orange-800' :
                              booking.status === 'cancelled' ? 'bg-red-100 text-red-800' :
                              'bg-blue-100 text-blue-800'
                            }`}>
                              {booking.status?.replace('_', ' ')}
                            </span>
                          </div>
                        </div>
                        <div className="text-right">
                          <p className="font-bold text-green-600">
                            ₦{booking.total_amount?.toLocaleString()}
                          </p>
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              ) : (
                <p className="text-gray-500 text-center py-8">
                  No bookings for this date
                </p>
              )}
            </div>
          </div>
        </div>
      )}

      {/* Cancel Modal */}
      {showCancelModal && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
          <div className="bg-white rounded-lg max-w-md w-full p-6">
            <h3 className="text-xl font-bold text-gray-900 mb-4">Cancel Booking</h3>
            <p className="text-gray-600 mb-4">
              Please provide a reason for cancelling this booking:
            </p>
            <textarea
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
              className="w-full border border-gray-300 rounded-lg p-3 mb-4 h-32 focus:ring-2 focus:ring-green-500 focus:border-transparent"
              placeholder="Enter cancellation reason..."
            />
            <div className="flex gap-2 justify-end">
              <button
                onClick={() => {
                  setShowCancelModal(false);
                  setCancelReason('');
                  setSelectedBooking(null);
                }}
                className="px-4 py-2 border border-gray-300 rounded-lg hover:bg-gray-50"
              >
                Close
              </button>
              <button
                onClick={submitCancel}
                disabled={!cancelReason.trim() || cancelMutation.isPending}
                className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {cancelMutation.isPending ? 'Cancelling...' : 'Confirm Cancel'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default MyBookings;
