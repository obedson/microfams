import React, { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import axios from 'axios';
import BookingList from '../components/bookings/BookingList';
import BookingFilters from '../components/bookings/BookingFilters';
import toast from 'react-hot-toast';

const API_URL = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

const OwnerBookings: React.FC = () => {
  const [statusFilter, setStatusFilter] = useState<string>('all');
  const [propertyFilter, setPropertyFilter] = useState<string>('all');
  const [selectedBooking, setSelectedBooking] = useState<any>(null);
  const [showModal, setShowModal] = useState(false);
  const [rejectionReason, setRejectionReason] = useState('');
  const queryClient = useQueryClient();

  const { data: bookingsData, isLoading } = useQuery({
    queryKey: ['owner-bookings', statusFilter, propertyFilter],
    queryFn: async () => {
      const token = localStorage.getItem('token');
      const params: any = {};
      if (statusFilter !== 'all') params.status = statusFilter;
      if (propertyFilter !== 'all') params.property_id = propertyFilter;
      
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

  const { data: propertiesData } = useQuery({
    queryKey: ['my-properties'],
    queryFn: async () => {
      const token = localStorage.getItem('token');
      const response = await axios.get(`${API_URL}/properties`, {
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
      toast.success('Booking status updated');
    },
    onError: () => {
      toast.error('Failed to update booking status');
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
    if (selectedBooking && rejectionReason.trim()) {
      updateStatusMutation.mutate({
        id: selectedBooking.id,
        status: 'cancelled',
        rejection_reason: rejectionReason
      });
    }
  };

  const handleContact = (booking: any) => {
    const farmerEmail = booking.users?.email;
    const farmerPhone = booking.users?.phone;
    
    if (farmerEmail) {
      window.location.href = `mailto:${farmerEmail}?subject=Booking Inquiry - ${booking.properties?.title}`;
    } else if (farmerPhone) {
      window.location.href = `tel:${farmerPhone}`;
    }
  };

  const bookings = bookingsData?.data || [];
  const stats = statsData?.data || {};
  const properties = propertiesData?.data || [];

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      <div className="mb-8">
        <h1 className="text-3xl font-bold text-gray-900 mb-2">Booking Management</h1>
        <p className="text-gray-600">Manage bookings on your properties</p>
      </div>

      {/* Statistics Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
        <div className="bg-white p-6 rounded-lg shadow">
          <p className="text-gray-600 text-sm mb-1">Total Bookings</p>
          <p className="text-3xl font-bold text-gray-900">{stats.total || 0}</p>
        </div>
        <div className="bg-yellow-50 p-6 rounded-lg shadow border border-yellow-200">
          <p className="text-gray-600 text-sm mb-1">Pending Approval</p>
          <p className="text-3xl font-bold text-yellow-600">{stats.pending || 0}</p>
        </div>
        <div className="bg-green-50 p-6 rounded-lg shadow border border-green-200">
          <p className="text-gray-600 text-sm mb-1">Confirmed</p>
          <p className="text-3xl font-bold text-green-600">{stats.confirmed || 0}</p>
        </div>
        <div className="bg-blue-50 p-6 rounded-lg shadow border border-blue-200">
          <p className="text-gray-600 text-sm mb-1">Total Revenue</p>
          <p className="text-2xl font-bold text-blue-600">
            ₦{(stats.totalRevenue || 0).toLocaleString()}
          </p>
        </div>
      </div>

      <BookingFilters
        statusFilter={statusFilter}
        onStatusChange={setStatusFilter}
        propertyFilter={propertyFilter}
        onPropertyChange={setPropertyFilter}
        properties={properties}
        type="owner"
      />

      <BookingList
        bookings={bookings}
        type="owner"
        isLoading={isLoading}
        onApprove={handleApprove}
        onReject={handleReject}
        onContact={handleContact}
      />

      {/* Rejection Modal */}
      {showModal && (
        <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
          <div className="bg-white rounded-lg max-w-md w-full p-6">
            <h3 className="text-xl font-bold text-gray-900 mb-4">Reject Booking</h3>
            <p className="text-gray-600 mb-4">
              Please provide a reason for rejecting this booking:
            </p>
            <textarea
              value={rejectionReason}
              onChange={(e) => setRejectionReason(e.target.value)}
              className="w-full border border-gray-300 rounded-lg p-3 mb-4 h-32 focus:ring-2 focus:ring-green-500 focus:border-transparent"
              placeholder="Enter rejection reason..."
            />
            <div className="flex gap-2 justify-end">
              <button
                onClick={() => {
                  setShowModal(false);
                  setRejectionReason('');
                  setSelectedBooking(null);
                }}
                className="px-4 py-2 border border-gray-300 rounded-lg hover:bg-gray-50"
              >
                Cancel
              </button>
              <button
                onClick={submitRejection}
                disabled={!rejectionReason.trim() || updateStatusMutation.isPending}
                className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {updateStatusMutation.isPending ? 'Rejecting...' : 'Confirm Rejection'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default OwnerBookings;
