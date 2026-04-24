import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import axios from 'axios';

const API_URL = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

const OwnerBookings: React.FC = () => {
  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [selectedBooking, setSelectedBooking] = useState<any>(null);
  const [showModal, setShowModal] = useState(false);
  const [rejectionReason, setRejectionReason] = useState('');
  const queryClient = useQueryClient();

  const { data: bookingsData, isLoading } = useQuery({
    queryKey: ['owner-bookings', statusFilter],
    queryFn: async () => {
      const token = localStorage.getItem('token');
      const params = statusFilter !== 'all' ? { status: statusFilter } : {};
      const response = await axios.get(`${API_URL}/bookings/owner/bookings`, {
        headers: { Authorization: `Bearer ${token}` },
        params
      });
      return response.data;
    }
  });

  const { data: statsData } = useQuery({
    queryKey: ['booking-stats'],
    queryFn: async () => {
      const token = localStorage.getItem('token');
      const response = await axios.get(`${API_URL}/bookings/owner/stats`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      return response.data;
    }
  });

  const updateStatusMutation = useMutation({
    mutationFn: async ({ id, status, rejection_reason }: any) => {
      const token = localStorage.getItem('token');
      await axios.put(
        `${API_URL}/bookings/${id}/status`,
        { status, rejection_reason },
        { headers: { Authorization: `Bearer ${token}` } }
      );
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['owner-bookings'] });
      queryClient.invalidateQueries({ queryKey: ['booking-stats'] });
      setShowModal(false);
      setSelectedBooking(null);
      setRejectionReason('');
    }
  });

  const handleApprove = (booking: any) => {
    if (window.confirm('Approve this booking?')) {
      updateStatusMutation.mutate({ id: booking.id, status: 'confirmed' });
    }
  };

  const handleReject = (booking: any) => {
    setSelectedBooking(booking);
    setShowModal(true);
  };

  const submitRejection = () => {
    if (selectedBooking) {
      updateStatusMutation.mutate({
        id: selectedBooking.id,
        status: 'cancelled',
        rejection_reason: rejectionReason
      });
    }
  };

  const bookings = bookingsData?.data || [];
  const stats = statsData?.data || {};

  if (isLoading) return <div className="p-6">Loading bookings...</div>;

  return (
    <div className="max-w-7xl mx-auto p-6">
      <h1 className="text-3xl font-bold mb-6">Booking Management</h1>

      {/* Statistics Cards */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
        <div className="bg-white p-6 rounded-lg shadow">
          <p className="text-gray-600 text-sm">Total Bookings</p>
          <p className="text-3xl font-bold">{stats.total || 0}</p>
        </div>
        <div className="bg-yellow-50 p-6 rounded-lg shadow">
          <p className="text-gray-600 text-sm">Pending</p>
          <p className="text-3xl font-bold text-yellow-600">{stats.pending || 0}</p>
        </div>
        <div className="bg-green-50 p-6 rounded-lg shadow">
          <p className="text-gray-600 text-sm">Confirmed</p>
          <p className="text-3xl font-bold text-green-600">{stats.confirmed || 0}</p>
        </div>
        <div className="bg-blue-50 p-6 rounded-lg shadow">
          <p className="text-gray-600 text-sm">Total Revenue</p>
          <p className="text-2xl font-bold text-blue-600">
            ₦{(stats.totalRevenue || 0).toLocaleString()}
          </p>
        </div>
      </div>

      {/* Filter Tabs */}
      <div className="flex gap-2 mb-6 border-b">
        {['all', 'pending', 'confirmed', 'completed', 'cancelled'].map((status) => (
          <button
            key={status}
            onClick={() => setStatusFilter(status)}
            className={`px-4 py-2 font-medium capitalize ${
              statusFilter === status
                ? 'border-b-2 border-green-600 text-green-600'
                : 'text-gray-600 hover:text-gray-900'
            }`}
          >
            {status}
          </button>
        ))}
      </div>

      {/* Bookings List */}
      {bookings.length === 0 ? (
        <div className="bg-white p-8 rounded-lg shadow text-center text-gray-500">
          No bookings found
        </div>
      ) : (
        <div className="space-y-4">
          {bookings.map((booking: any) => (
            <div key={booking.id} className="bg-white p-6 rounded-lg shadow hover:shadow-lg transition">
              <div className="flex justify-between items-start">
                <div className="flex-1">
                  <div className="flex items-center gap-3 mb-2">
                    <h3 className="text-xl font-semibold">{booking.properties?.title}</h3>
                    <span
                      className={`px-3 py-1 rounded-full text-sm font-medium ${
                        booking.status === 'pending'
                          ? 'bg-yellow-100 text-yellow-800'
                          : booking.status === 'confirmed'
                          ? 'bg-green-100 text-green-800'
                          : booking.status === 'completed'
                          ? 'bg-blue-100 text-blue-800'
                          : 'bg-red-100 text-red-800'
                      }`}
                    >
                      {booking.status}
                    </span>
                    <span
                      className={`px-3 py-1 rounded-full text-sm font-medium ${
                        booking.payment_status === 'paid'
                          ? 'bg-green-100 text-green-800'
                          : 'bg-gray-100 text-gray-800'
                      }`}
                    >
                      {booking.payment_status}
                    </span>
                  </div>

                  <div className="grid grid-cols-2 md:grid-cols-4 gap-4 text-sm text-gray-600 mb-3">
                    <div>
                      <p className="font-medium text-gray-900">Farmer</p>
                      <p>{booking.users?.name}</p>
                      <p className="text-xs">{booking.users?.email}</p>
                    </div>
                    <div>
                      <p className="font-medium text-gray-900">Check-in</p>
                      <p>{new Date(booking.start_date).toLocaleDateString()}</p>
                    </div>
                    <div>
                      <p className="font-medium text-gray-900">Check-out</p>
                      <p>{new Date(booking.end_date).toLocaleDateString()}</p>
                    </div>
                    <div>
                      <p className="font-medium text-gray-900">Amount</p>
                      <p className="text-lg font-bold text-green-600">
                        ₦{booking.total_amount.toLocaleString()}
                      </p>
                    </div>
                  </div>

                  {booking.notes && (
                    <div className="bg-gray-50 p-3 rounded mb-3">
                      <p className="text-sm text-gray-600">
                        <strong>Notes:</strong> {booking.notes}
                      </p>
                    </div>
                  )}

                  {booking.rejection_reason && (
                    <div className="bg-red-50 p-3 rounded mb-3">
                      <p className="text-sm text-red-600">
                        <strong>Rejection Reason:</strong> {booking.rejection_reason}
                      </p>
                    </div>
                  )}
                </div>

                {/* Action Buttons */}
                {booking.status === 'pending' && (
                  <div className="flex gap-2 ml-4">
                    <button
                      onClick={() => handleApprove(booking)}
                      disabled={updateStatusMutation.isPending}
                      className="px-4 py-2 bg-green-600 text-white rounded hover:bg-green-700 disabled:opacity-50"
                    >
                      Approve
                    </button>
                    <button
                      onClick={() => handleReject(booking)}
                      disabled={updateStatusMutation.isPending}
                      className="px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700 disabled:opacity-50"
                    >
                      Reject
                    </button>
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Rejection Modal */}
      {showModal && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
          <div className="bg-white p-6 rounded-lg max-w-md w-full mx-4">
            <h3 className="text-xl font-bold mb-4">Reject Booking</h3>
            <p className="text-gray-600 mb-4">
              Please provide a reason for rejecting this booking:
            </p>
            <textarea
              value={rejectionReason}
              onChange={(e) => setRejectionReason(e.target.value)}
              className="w-full border rounded p-3 mb-4 h-32"
              placeholder="Enter rejection reason..."
            />
            <div className="flex gap-2 justify-end">
              <button
                onClick={() => {
                  setShowModal(false);
                  setRejectionReason('');
                  setSelectedBooking(null);
                }}
                className="px-4 py-2 border rounded hover:bg-gray-50"
              >
                Cancel
              </button>
              <button
                onClick={submitRejection}
                disabled={!rejectionReason.trim() || updateStatusMutation.isPending}
                className="px-4 py-2 bg-red-600 text-white rounded hover:bg-red-700 disabled:opacity-50"
              >
                Confirm Rejection
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default OwnerBookings;
