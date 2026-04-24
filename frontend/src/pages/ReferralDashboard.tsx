import React from 'react';
import { useQuery } from '@tanstack/react-query';
import { Users, Copy, CheckCircle } from 'lucide-react';
import { apiClient } from '../api/client';
import { useAuthStore } from '../store/authStore';

export default function ReferralDashboard() {
  const { user } = useAuthStore();
  const [copied, setCopied] = React.useState(false);

  const { data: stats } = useQuery({
    queryKey: ['referral-stats'],
    queryFn: () => apiClient.get('/auth/referral-stats').then(r => r.data)
  });

  const copyReferralCode = () => {
    navigator.clipboard.writeText(user?.referral_code || '');
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="max-w-4xl mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-8">Referral Dashboard</h1>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
        <div className="bg-white rounded-lg shadow p-6">
          <p className="text-gray-600 text-sm mb-2">Total Referrals</p>
          <p className="text-3xl font-bold text-green-600">{stats?.total || 0}</p>
        </div>
        <div className="bg-white rounded-lg shadow p-6">
          <p className="text-gray-600 text-sm mb-2">Paid Referrals</p>
          <p className="text-3xl font-bold text-blue-600">{user?.paid_referrals_count || 0}</p>
        </div>
        <div className="bg-white rounded-lg shadow p-6">
          <p className="text-gray-600 text-sm mb-2">Can Create Group</p>
          <p className="text-3xl font-bold">
            {(user?.paid_referrals_count || 0) >= 2 ? (
              <CheckCircle className="text-green-600" size={32} />
            ) : (
              <span className="text-gray-400">{2 - (user?.paid_referrals_count || 0)} more</span>
            )}
          </p>
        </div>
      </div>

      <div className="bg-white rounded-lg shadow p-6 mb-8">
        <h2 className="text-xl font-bold mb-4">Your Referral Code</h2>
        <div className="flex items-center gap-4">
          <div className="flex-1 bg-gray-50 border border-gray-300 rounded-lg p-4">
            <p className="text-3xl font-bold text-green-600 text-center">
              {user?.referral_code || 'N/A'}
            </p>
          </div>
          <button
            onClick={copyReferralCode}
            className="bg-green-600 text-white px-6 py-3 rounded-lg hover:bg-green-700 flex items-center gap-2"
          >
            {copied ? <CheckCircle size={20} /> : <Copy size={20} />}
            {copied ? 'Copied!' : 'Copy'}
          </button>
        </div>
        <p className="text-sm text-gray-600 mt-4">
          Share this code with others during registration. When they join and pay for a group, you'll get credit!
        </p>
      </div>

      {stats?.referrals && stats.referrals.length > 0 && (
        <div className="bg-white rounded-lg shadow p-6">
          <h2 className="text-xl font-bold mb-4">Your Referrals</h2>
          <div className="space-y-3">
            {stats.referrals.map((ref: any) => (
              <div key={ref.id} className="flex items-center justify-between p-3 bg-gray-50 rounded">
                <div className="flex items-center gap-3">
                  <Users size={20} className="text-gray-400" />
                  <div>
                    <p className="font-medium">{ref.name}</p>
                    <p className="text-sm text-gray-500">{ref.email}</p>
                  </div>
                </div>
                <span className={`px-3 py-1 rounded-full text-sm ${
                  ref.has_paid ? 'bg-green-100 text-green-700' : 'bg-gray-100 text-gray-600'
                }`}>
                  {ref.has_paid ? 'Paid' : 'Pending'}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
