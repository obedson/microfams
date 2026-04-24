import React from 'react';
import { useParams, Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { Calendar, DollarSign, Users, Settings, CheckCircle, XCircle, AlertCircle } from 'lucide-react';
import { apiClient } from '../api/client';
import { useAuthStore } from '../store/authStore';

export default function ContributionDashboard() {
  const { id } = useParams();
  const { user } = useAuthStore();

  const { data: group } = useQuery({
    queryKey: ['group', id],
    queryFn: () => apiClient.get(`/groups/${id}`).then(r => r.data)
  });

  const { data: cycle, isLoading } = useQuery({
    queryKey: ['current-cycle', id],
    queryFn: () => apiClient.get(`/groups/${id}/contributions/cycles/current`).then(r => r.data),
    retry: false
  });

  const { data: details } = useQuery({
    queryKey: ['cycle-details', cycle?.id],
    queryFn: () => apiClient.get(`/groups/${id}/contributions/cycles/${cycle.id}`).then(r => r.data),
    enabled: !!cycle?.id
  });

  const isOwner = group?.creator_id === user?.id;

  if (isLoading) return <div className="text-center py-12">Loading...</div>;

  if (!cycle) {
    return (
      <div className="max-w-4xl mx-auto px-4 py-8">
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-6 text-center">
          <AlertCircle size={48} className="mx-auto mb-4 text-yellow-600" />
          <h2 className="text-xl font-bold mb-2">No Active Contribution Cycle</h2>
          <p className="text-gray-600 mb-4">There is no active contribution cycle for this group.</p>
          {isOwner && (
            <Link
              to={`/groups/${id}/contributions/settings`}
              className="inline-flex items-center gap-2 bg-green-600 text-white px-6 py-2 rounded-lg hover:bg-green-700"
            >
              <Settings size={20} />
              Configure Contributions
            </Link>
          )}
        </div>
      </div>
    );
  }

  const progress = (cycle.collected_amount / cycle.expected_amount) * 100;
  const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  const getStatusIcon = (status: string) => {
    switch (status) {
      case 'paid': return <CheckCircle className="text-green-600" size={20} />;
      case 'late': return <AlertCircle className="text-yellow-600" size={20} />;
      default: return <XCircle className="text-red-600" size={20} />;
    }
  };

  const getStatusBadge = (status: string) => {
    const styles = {
      paid: 'bg-green-100 text-green-700',
      late: 'bg-yellow-100 text-yellow-700',
      pending: 'bg-gray-100 text-gray-700',
      overdue: 'bg-red-100 text-red-700'
    };
    return styles[status as keyof typeof styles] || styles.pending;
  };

  return (
    <div className="max-w-6xl mx-auto px-4 py-8">
      <div className="flex justify-between items-center mb-8">
        <h1 className="text-3xl font-bold">Contribution Dashboard</h1>
        {isOwner && (
          <Link
            to={`/groups/${id}/contributions/settings`}
            className="flex items-center gap-2 bg-gray-200 px-4 py-2 rounded-lg hover:bg-gray-300"
          >
            <Settings size={20} />
            Settings
          </Link>
        )}
      </div>

      {/* Cycle Overview */}
      <div className="bg-white rounded-lg shadow p-6 mb-8">
        <div className="flex items-center justify-between mb-4">
          <div className="flex items-center gap-3">
            <Calendar size={24} className="text-green-600" />
            <h2 className="text-xl font-bold">
              {monthNames[cycle.cycle_month - 1]} {cycle.cycle_year}
            </h2>
          </div>
          <div className="text-sm text-gray-600">
            Deadline: {new Date(cycle.deadline_date).toLocaleDateString()}
          </div>
        </div>

        <div className="mb-4">
          <div className="flex justify-between text-sm mb-2">
            <span>Progress</span>
            <span className="font-bold">{progress.toFixed(0)}%</span>
          </div>
          <div className="w-full bg-gray-200 rounded-full h-4">
            <div
              className="bg-green-600 h-4 rounded-full transition-all"
              style={{ width: `${Math.min(progress, 100)}%` }}
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-4">
          <div className="text-center p-4 bg-green-50 rounded-lg">
            <p className="text-sm text-gray-600">Collected</p>
            <p className="text-2xl font-bold text-green-600">₦{cycle.collected_amount?.toLocaleString()}</p>
          </div>
          <div className="text-center p-4 bg-blue-50 rounded-lg">
            <p className="text-sm text-gray-600">Expected</p>
            <p className="text-2xl font-bold text-blue-600">₦{cycle.expected_amount?.toLocaleString()}</p>
          </div>
          <div className="text-center p-4 bg-red-50 rounded-lg">
            <p className="text-sm text-gray-600">Outstanding</p>
            <p className="text-2xl font-bold text-red-600">₦{cycle.outstanding_amount?.toLocaleString()}</p>
          </div>
        </div>
      </div>

      {/* Member Payments */}
      <div className="bg-white rounded-lg shadow p-6">
        <h2 className="text-xl font-bold mb-4 flex items-center gap-2">
          <Users size={24} />
          Member Payments
        </h2>

        <div className="space-y-3">
          {details?.contributions?.map((contrib: any) => (
            <div key={contrib.id} className="flex items-center justify-between p-4 bg-gray-50 rounded-lg">
              <div className="flex items-center gap-3">
                {getStatusIcon(contrib.payment_status)}
                <div>
                  <p className="font-medium">{contrib.member.user.name}</p>
                  <p className="text-sm text-gray-500">{contrib.member.user.email}</p>
                </div>
              </div>
              <div className="text-right">
                <p className="font-bold">₦{contrib.paid_amount?.toLocaleString() || contrib.expected_amount?.toLocaleString()}</p>
                {contrib.penalty_amount > 0 && (
                  <p className="text-xs text-red-600">+₦{contrib.penalty_amount} penalty</p>
                )}
                <span className={`inline-block px-3 py-1 rounded-full text-xs mt-1 ${getStatusBadge(contrib.payment_status)}`}>
                  {contrib.payment_status}
                </span>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
