import React, { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { apiClient } from '../api/client';
import { useAuthStore } from '../store/authStore';
import { ShieldCheck, UserPlus, CreditCard, CheckCircle2, XCircle, ArrowRight, Info } from 'lucide-react';

export default function CreateGroup() {
  const navigate = useNavigate();
  const { user } = useAuthStore();
  const [showPayment, setShowPayment] = useState(false);
  const [formData, setFormData] = useState({
    name: '',
    description: '',
    category: '',
    state_id: '',
    lga_id: '',
    entry_fee: 1000,
    payment_reference: ''
  });

  const { data: eligibility, isLoading: checkingEligibility } = useQuery({
    queryKey: ['can-create-group'],
    queryFn: () => apiClient.get('/groups/can-create').then(r => r.data)
  });

  const { data: states } = useQuery({
    queryKey: ['states'],
    queryFn: () => apiClient.get('/locations/states').then(r => r.data)
  });

  const { data: lgas } = useQuery({
    queryKey: ['lgas', formData.state_id],
    queryFn: () => apiClient.get(`/locations/lgas/${formData.state_id}`).then(r => r.data),
    enabled: !!formData.state_id
  });

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!showPayment) {
      setShowPayment(true);
      return;
    }
    
    if (!formData.payment_reference) {
      alert('Please complete payment first');
      return;
    }

    try {
      await apiClient.post('/groups', formData);
      alert('Group created successfully! You are now a member.');
      navigate('/groups');
    } catch (error: any) {
      alert(error.response?.data?.error || 'Failed to create group');
    }
  };

  if (checkingEligibility) {
    return <div className="text-center py-12">Checking eligibility...</div>;
  }

  if (!eligibility?.canCreate) {
    const { conditions } = eligibility || {};
    
    return (
      <div className="max-w-2xl mx-auto px-4 py-12">
        <div className="bg-white rounded-3xl shadow-xl border border-gray-100 overflow-hidden">
          <div className="bg-yellow-500 px-8 py-6 text-white">
            <h2 className="text-2xl font-bold flex items-center gap-2">
              <Info /> Requirements Not Met
            </h2>
            <p className="text-yellow-50 opacity-90 text-sm mt-1">Complete the steps below to unlock group creation.</p>
          </div>
          
          <div className="p-8 space-y-6">
            <div className="space-y-4">
              <div className={`flex items-center justify-between p-4 rounded-2xl border ${conditions?.nin_verified ? 'bg-green-50 border-green-100' : 'bg-gray-50 border-gray-100'}`}>
                <div className="flex items-center gap-4">
                  {conditions?.nin_verified ? <CheckCircle2 className="text-green-500" /> : <XCircle className="text-gray-300" />}
                  <div>
                    <p className="font-bold text-gray-900">Identity Verification</p>
                    <p className="text-xs text-gray-500">NIN must be verified for compliance.</p>
                  </div>
                </div>
                {!conditions?.nin_verified && (
                  <Link to="/verify-nin" className="text-primary-600 font-bold text-sm flex items-center gap-1 hover:underline">
                    Verify <ArrowRight size={14} />
                  </Link>
                )}
              </div>

              <div className={`flex items-center justify-between p-4 rounded-2xl border ${conditions?.is_platform_subscriber ? 'bg-green-50 border-green-100' : 'bg-gray-50 border-gray-100'}`}>
                <div className="flex items-center gap-4">
                  {conditions?.is_platform_subscriber ? <CheckCircle2 className="text-green-500" /> : <XCircle className="text-gray-300" />}
                  <div>
                    <p className="font-bold text-gray-900">Premium Membership</p>
                    <p className="text-xs text-gray-500">Active subscription required.</p>
                  </div>
                </div>
                {!conditions?.is_platform_subscriber && (
                  <Link to="/become-a-member" className="text-primary-600 font-bold text-sm flex items-center gap-1 hover:underline">
                    Subscribe <ArrowRight size={14} />
                  </Link>
                )}
              </div>

              <div className={`flex items-center justify-between p-4 rounded-2xl border ${conditions?.paid_invitees >= 2 ? 'bg-green-50 border-green-100' : 'bg-gray-50 border-gray-100'}`}>
                <div className="flex items-center gap-4">
                  {conditions?.paid_invitees >= 2 ? <CheckCircle2 className="text-green-500" /> : <XCircle className="text-gray-300" />}
                  <div>
                    <p className="font-bold text-gray-900">Community Referrals</p>
                    <p className="text-xs text-gray-500">Need 2 paid referrals ({conditions?.paid_invitees || 0}/2)</p>
                  </div>
                </div>
                {conditions?.paid_invitees < 2 && (
                  <Link to="/referrals" className="text-primary-600 font-bold text-sm flex items-center gap-1 hover:underline">
                    Invite <ArrowRight size={14} />
                  </Link>
                )}
              </div>
            </div>

            <div className="bg-gray-900 rounded-2xl p-6 text-white">
              <p className="text-xs text-gray-400 uppercase font-bold mb-2 tracking-widest">Your Referral Code</p>
              <div className="flex items-center justify-between">
                <span className="text-2xl font-mono font-bold tracking-wider">{user?.referral_code || 'N/A'}</span>
                <button 
                  onClick={() => {
                    navigator.clipboard.writeText(user?.referral_code || '');
                    alert('Copied!');
                  }}
                  className="px-4 py-2 bg-white/10 hover:bg-white/20 rounded-lg text-xs font-bold transition-colors"
                >
                  COPY
                </button>
              </div>
            </div>

            <button
              onClick={() => navigate('/groups')}
              className="w-full py-4 text-gray-500 font-bold hover:text-gray-900 transition-colors"
            >
              Back to Groups
            </button>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-2xl mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-8">Create New Group</h1>

      {!showPayment ? (
        <form onSubmit={handleSubmit} className="bg-white rounded-lg shadow p-6 space-y-6">
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Group Name *
          </label>
          <input
            type="text"
            required
            value={formData.name}
            onChange={(e) => setFormData({ ...formData, name: e.target.value })}
            className="w-full border border-gray-300 px-4 py-2 rounded-lg focus:ring-2 focus:ring-green-500"
            placeholder="e.g., Lagos Poultry Farmers Association"
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Description *
          </label>
          <textarea
            required
            rows={4}
            value={formData.description}
            onChange={(e) => setFormData({ ...formData, description: e.target.value })}
            className="w-full border border-gray-300 px-4 py-2 rounded-lg focus:ring-2 focus:ring-green-500"
            placeholder="Describe your group's purpose and activities..."
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Category *
          </label>
          <select
            required
            value={formData.category}
            onChange={(e) => setFormData({ ...formData, category: e.target.value })}
            className="w-full border border-gray-300 px-4 py-2 rounded-lg focus:ring-2 focus:ring-green-500"
          >
            <option value="">Select category</option>
            <option value="poultry">Poultry</option>
            <option value="cattle">Cattle</option>
            <option value="fishery">Fishery</option>
            <option value="goat">Goat</option>
            <option value="pig">Pig</option>
            <option value="general">General Farming</option>
            <option value="other">Other</option>
          </select>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            State *
          </label>
          <select
            required
            value={formData.state_id}
            onChange={(e) => setFormData({ ...formData, state_id: e.target.value, lga_id: '' })}
            className="w-full border border-gray-300 px-4 py-2 rounded-lg focus:ring-2 focus:ring-green-500"
          >
            <option value="">Select state</option>
            {states?.map((state: any) => (
              <option key={state.id} value={state.id}>
                {state.name}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            LGA *
          </label>
          <select
            required
            value={formData.lga_id}
            onChange={(e) => setFormData({ ...formData, lga_id: e.target.value })}
            disabled={!formData.state_id}
            className="w-full border border-gray-300 px-4 py-2 rounded-lg focus:ring-2 focus:ring-green-500 disabled:bg-gray-100"
          >
            <option value="">Select LGA</option>
            {lgas?.map((lga: any) => (
              <option key={lga.id} value={lga.id}>
                {lga.name}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Entry Fee (₦) *
          </label>
          <input
            type="number"
            required
            min="500"
            max="10000"
            step="100"
            value={formData.entry_fee}
            onChange={(e) => setFormData({ ...formData, entry_fee: Number(e.target.value) })}
            className="w-full border border-gray-300 px-4 py-2 rounded-lg focus:ring-2 focus:ring-green-500"
            placeholder="1000"
          />
          <p className="text-xs text-gray-500 mt-1">
            Set between ₦500 - ₦10,000. Recommended: ₦1,000
          </p>
        </div>

        <div className="flex gap-4">
          <button
            type="submit"
            className="flex-1 bg-green-600 text-white py-2 px-4 rounded-lg hover:bg-green-700"
          >
            Proceed to Payment
          </button>
          <button
            type="button"
            onClick={() => navigate('/groups')}
            className="flex-1 bg-gray-200 text-gray-700 py-2 px-4 rounded-lg hover:bg-gray-300"
          >
            Cancel
          </button>
        </div>
      </form>
      ) : (
        <div className="bg-white rounded-lg shadow p-6">
          <h2 className="text-xl font-bold mb-4">Payment Required</h2>
          <div className="bg-blue-50 border border-blue-200 rounded-lg p-4 mb-6">
            <p className="text-sm text-blue-800 mb-2">
              To create this group, you need to pay the entry fee of <strong>₦{formData.entry_fee.toLocaleString()}</strong>
            </p>
            <p className="text-xs text-blue-600">
              This payment makes you the first member of your group.
            </p>
          </div>

          <div className="mb-6">
            <label className="block text-sm font-medium text-gray-700 mb-2">
              Payment Reference *
            </label>
            <input
              type="text"
              required
              value={formData.payment_reference}
              onChange={(e) => setFormData({ ...formData, payment_reference: e.target.value })}
              className="w-full border border-gray-300 px-4 py-2 rounded-lg focus:ring-2 focus:ring-green-500"
              placeholder="Enter payment reference from Paystack"
            />
            <p className="text-xs text-gray-500 mt-1">
              Complete payment via Paystack and enter the reference here
            </p>
          </div>

          <div className="flex gap-4">
            <button
              onClick={handleSubmit}
              disabled={!formData.payment_reference}
              className="flex-1 bg-green-600 text-white py-2 px-4 rounded-lg hover:bg-green-700 disabled:bg-gray-400"
            >
              Create Group
            </button>
            <button
              onClick={() => setShowPayment(false)}
              className="flex-1 bg-gray-200 text-gray-700 py-2 px-4 rounded-lg hover:bg-gray-300"
            >
              Back
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
