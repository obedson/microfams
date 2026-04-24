import React, { useState } from 'react';
import { Users, MapPin, Plus, Sparkles } from 'lucide-react';
import { Link, useNavigate } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { apiClient } from '../api/client';
import { useAuthStore } from '../store/authStore';

export default function Groups() {
  const { user } = useAuthStore();
  const navigate = useNavigate();
  const [selectedState, setSelectedState] = useState('');
  const [selectedLga, setSelectedLga] = useState('');

  const { data: states } = useQuery({
    queryKey: ['states'],
    queryFn: () => apiClient.get('/locations/states').then(r => r.data)
  });

  const { data: lgas } = useQuery({
    queryKey: ['lgas', selectedState],
    queryFn: () => apiClient.get(`/locations/lgas/${selectedState}`).then(r => r.data),
    enabled: !!selectedState
  });

  const { data: groups } = useQuery({
    queryKey: ['groups', selectedState, selectedLga],
    queryFn: () => apiClient.get('/groups/search', { 
      params: { state_id: selectedState, lga_id: selectedLga } 
    }).then(r => r.data),
    enabled: !!selectedState
  });

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      {(!user?.is_platform_subscriber || !user?.nin_verified) && (
        <div className="mb-8 bg-gradient-to-r from-primary-600 to-primary-800 rounded-2xl p-6 text-white shadow-lg flex items-center justify-between">
          <div className="flex items-center gap-4">
            <div className="p-3 bg-white/10 rounded-xl"><Sparkles /></div>
            <div>
              <p className="font-bold">Unlock Group Creation</p>
              <p className="text-primary-100 text-sm">Become a premium member to create and manage your own groups.</p>
            </div>
          </div>
          <button 
            onClick={() => navigate('/become-a-member')}
            className="px-6 py-2 bg-white text-primary-700 rounded-lg font-bold hover:bg-primary-50 transition-colors shadow-md"
          >
            Upgrade
          </button>
        </div>
      )}

      <div className="flex justify-between items-center mb-8">
        <h1 className="text-3xl font-bold text-gray-900">Find Groups Near You</h1>
        <Link
          to="/create-group"
          className="bg-green-600 text-white px-4 py-2 rounded-lg flex items-center gap-2 hover:bg-green-700"
        >
          <Plus size={20} />
          Create Group
        </Link>
      </div>

      <div className="bg-white rounded-lg shadow p-6 mb-8">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Select State
            </label>
            <select
              value={selectedState}
              onChange={(e) => {
                setSelectedState(e.target.value);
                setSelectedLga('');
              }}
              className="w-full border border-gray-300 px-4 py-2 rounded-lg focus:ring-2 focus:ring-green-500"
            >
              <option value="">Choose your state</option>
              {states?.map((state: any) => (
                <option key={state.id} value={state.id}>
                  {state.name}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Select LGA (Optional)
            </label>
            <select
              value={selectedLga}
              onChange={(e) => setSelectedLga(e.target.value)}
              disabled={!selectedState}
              className="w-full border border-gray-300 px-4 py-2 rounded-lg focus:ring-2 focus:ring-green-500 disabled:bg-gray-100"
            >
              <option value="">All LGAs</option>
              {lgas?.map((lga: any) => (
                <option key={lga.id} value={lga.id}>
                  {lga.name}
                </option>
              ))}
            </select>
          </div>
        </div>
      </div>

      <div className="text-center py-12 text-gray-500">
        <Users size={64} className="mx-auto mb-4 text-gray-300" />
        {!selectedState ? (
          <p className="text-lg">Select your state to find farming groups near you</p>
        ) : groups && groups.length === 0 ? (
          <p className="text-lg">No groups found in this location yet. Be the first to create one!</p>
        ) : null}
      </div>

      {groups && groups.length > 0 && (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {groups.map((group: any) => (
            <div key={group.id} className="bg-white rounded-lg shadow p-6">
              <h3 className="font-bold text-lg mb-2">{group.name}</h3>
              <p className="text-gray-600 text-sm mb-3">{group.description}</p>
              <div className="space-y-1 text-sm text-gray-500 mb-4">
                <p>Category: <span className="font-medium">{group.category}</span></p>
                <p>Members: <span className="font-medium">{group.member_count}</span></p>
                <p className="text-base">
                  Entry Fee: <span className="font-bold text-green-600">₦{group.entry_fee?.toLocaleString()}</span>
                </p>
              </div>
              <Link
                to={`/groups/${group.id}`}
                className="block w-full bg-green-600 text-white text-center px-4 py-2 rounded-lg hover:bg-green-700"
              >
                View Details
              </Link>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
