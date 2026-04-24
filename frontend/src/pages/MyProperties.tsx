import React from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import axios from 'axios';
import toast from 'react-hot-toast';
import { useAuthStore } from '../store/authStore';
import { LoadingSpinner } from '../components/Loading';

const API_URL = process.env.REACT_APP_API_URL || 'http://localhost:3001/api';

export default function MyProperties() {
  const navigate = useNavigate();
  const { user, token } = useAuthStore();
  const queryClient = useQueryClient();

  const { data, isLoading } = useQuery({
    queryKey: ['my-properties'],
    queryFn: async () => {
      const response = await axios.get(`${API_URL}/properties`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      const allProperties = response.data.data || [];
      return allProperties.filter((p: any) => p.owner_id === user?.id);
    }
  });

  const deleteMutation = useMutation({
    mutationFn: async (propertyId: string) => {
      await axios.delete(`${API_URL}/properties/${propertyId}`, {
        headers: { Authorization: `Bearer ${token}` }
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['my-properties'] });
      toast.success('Property deleted successfully');
    },
    onError: (error: any) => {
      toast.error(error.response?.data?.error || 'Failed to delete property');
    }
  });

  const handleDelete = async (propertyId: string, hasBookings: boolean) => {
    if (hasBookings) {
      toast.error('Cannot delete property with active bookings');
      return;
    }
    if (window.confirm('Are you sure you want to delete this property?')) {
      deleteMutation.mutate(propertyId);
    }
  };

  if (isLoading) {
    return (
      <div className="flex justify-center items-center min-h-screen">
        <LoadingSpinner size="lg" />
      </div>
    );
  }

  const properties = data || [];

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      <div className="flex justify-between items-center mb-8">
        <h1 className="text-3xl font-bold">My Properties</h1>
        <button
          onClick={() => navigate('/create-property')}
          className="bg-green-600 text-white px-6 py-2 rounded-lg hover:bg-green-700"
        >
          Add Property
        </button>
      </div>

      {properties.length === 0 ? (
        <div className="text-center py-12">
          <p className="text-gray-600 mb-4">You haven't listed any properties yet.</p>
          <button
            onClick={() => navigate('/create-property')}
            className="bg-green-600 text-white px-6 py-2 rounded-lg hover:bg-green-700"
          >
            List Your First Property
          </button>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {properties.map((property: any) => (
            <div key={property.id} className="bg-white rounded-lg shadow overflow-hidden">
              {property.images?.[0] && (
                <img
                  src={property.images[0]}
                  alt={property.title}
                  className="w-full h-48 object-cover"
                />
              )}
              <div className="p-4">
                <h3 className="text-xl font-semibold mb-2">{property.title}</h3>
                <p className="text-gray-600 mb-2">{property.city}, {property.lga}</p>
                <p className="text-green-600 font-bold mb-4">₦{property.price_per_month.toLocaleString()}/month</p>
                
                <div className="flex gap-2">
                  <button
                    onClick={() => navigate(`/properties/${property.id}/edit`)}
                    className="flex-1 bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                  >
                    Edit
                  </button>
                  <button
                    onClick={() => handleDelete(property.id, property.has_bookings)}
                    disabled={property.has_bookings}
                    className={`flex-1 px-4 py-2 rounded ${
                      property.has_bookings
                        ? 'bg-gray-300 text-gray-500 cursor-not-allowed'
                        : 'bg-red-600 text-white hover:bg-red-700'
                    }`}
                    title={property.has_bookings ? 'Cannot delete property with bookings' : 'Delete property'}
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
