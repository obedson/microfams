import React, { useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useQuery, useMutation } from '@tanstack/react-query';
import { Users, MapPin, DollarSign, AlertCircle, Sparkles, ShieldAlert } from 'lucide-react';
import { apiClient } from '../api/client';
import { useAuthStore } from '../store/authStore';

export default function GroupDetail() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { user } = useAuthStore();
  const [isJoining, setIsJoining] = useState(false);

  const { data: group, isLoading, error } = useQuery({
    queryKey: ['group', id],
    queryFn: async () => {
      const response = await apiClient.get(`/groups/${id}`);
      return response.data;
    },
    retry: false
  });

  const { data: members, error: membersError } = useQuery({
    queryKey: ['group-members', id],
    queryFn: async () => {
      const response = await apiClient.get(`/groups/${id}/members`);
      return response.data;
    },
    enabled: !!group,
    retry: false
  });

  const { data: membershipStatus } = useQuery({
    queryKey: ['membership-status', id],
    queryFn: async () => {
      const response = await apiClient.get(`/groups/${id}/membership-status`);
      console.log('Membership status:', response.data);
      return response.data;
    },
    enabled: !!user && !!group,
    retry: false
  });

  const joinMutation = useMutation({
    mutationFn: async () => {
      const { data } = await apiClient.post(`/groups/${id}/join`, {
        payment_reference: `GRP-${Date.now()}`,
        amount: group.entry_fee
      });
      return data;
    },
    onSuccess: (membership) => {
      window.location.href = `/payment?type=group&id=${membership.id}&amount=${group.entry_fee}`;
    },
    onError: (error: any) => {
      console.error('Join error:', error);
      alert(error.response?.data?.error || 'Failed to join group');
    }
  });

  if (isLoading) {
    return (
      <div className="max-w-4xl mx-auto px-4 py-8">
        <div className="text-center py-12">
          <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-green-600 mx-auto"></div>
          <p className="mt-4 text-gray-600">Loading group details...</p>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="max-w-4xl mx-auto px-4 py-8">
        <div className="bg-red-50 border border-red-200 rounded-lg p-6">
          <div className="flex items-center gap-3 mb-4">
            <AlertCircle className="text-red-600" size={24} />
            <h2 className="text-xl font-bold text-red-800">Error Loading Group</h2>
          </div>
          <p className="text-red-700 mb-4">
            {(error as any)?.response?.data?.error || (error as any)?.message || 'Failed to load group'}
          </p>
          <button
            onClick={() => navigate('/groups')}
            className="bg-red-600 text-white px-4 py-2 rounded-lg hover:bg-red-700"
          >
            Back to Groups
          </button>
        </div>
      </div>
    );
  }

  if (!group) {
    return (
      <div className="max-w-4xl mx-auto px-4 py-8">
        <div className="text-center py-12">
          <h2 className="text-2xl font-bold text-gray-800 mb-4">Group Not Found</h2>
          <p className="text-gray-600 mb-6">The group you're looking for doesn't exist.</p>
          <button
            onClick={() => navigate('/groups')}
            className="bg-green-600 text-white px-6 py-3 rounded-lg hover:bg-green-700"
          >
            Browse Groups
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto px-4 py-8">
      {user && (!user.is_platform_subscriber || !user.nin_verified) && (
        <div className="mb-8 bg-white border border-primary-100 rounded-2xl p-6 shadow-sm flex items-center justify-between">
          <div className="flex items-center gap-4">
            <div className="p-3 bg-primary-50 text-primary-600 rounded-xl"><Sparkles size={24} /></div>
            <div>
              <p className="font-bold text-gray-900">Premium Membership Required</p>
              <p className="text-gray-500 text-sm">You must verify your identity and subscribe to join groups.</p>
            </div>
          </div>
          <Link to="/become-a-member" className="px-6 py-2 bg-primary-600 text-white rounded-lg font-bold hover:bg-primary-700 transition-colors">
            Get Access
          </Link>
        </div>
      )}

      <div className="bg-white rounded-lg shadow-lg p-8">
        <div className="flex justify-between items-start mb-4">
          <h1 className="text-3xl font-bold">{group.name}</h1>
          {user && (
            <Link
              to={`/groups/${id}/contributions`}
              className="bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700"
            >
              View Contributions
            </Link>
          )}
        </div>
        
        <div className="flex items-center gap-4 text-gray-600 mb-6">
          <div className="flex items-center gap-2">
            <MapPin size={20} />
            <span>{group.state?.name || 'N/A'}, {group.lga?.name || 'N/A'}</span>
          </div>
          <div className="flex items-center gap-2">
            <Users size={20} />
            <span>{group.member_count || 0} members</span>
          </div>
        </div>

        <p className="text-gray-700 mb-6">{group.description}</p>

        <div className="bg-green-50 border border-green-200 rounded-lg p-4 mb-6">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-gray-600">Entry Fee</p>
              <p className="text-2xl font-bold text-green-600">₦{group.entry_fee?.toLocaleString() || '0'}</p>
              <p className="text-xs text-gray-500 mt-1">One-time payment to join</p>
            </div>
            {!user ? (
              <button
                onClick={() => navigate('/login')}
                className="bg-gray-600 text-white px-6 py-3 rounded-lg hover:bg-gray-700"
              >
                Login to Join
              </button>
            ) : membershipStatus?.payment_status === 'paid' ? (
              <div className="text-center">
                <div className="bg-green-100 text-green-800 px-6 py-3 rounded-lg font-semibold mb-2">
                  ✓ Active Member
                </div>
                <Link
                  to={`/groups/${id}/contributions`}
                  className="text-blue-600 hover:underline text-sm"
                >
                  View Contributions →
                </Link>
              </div>
            ) : membershipStatus?.payment_status === 'pending' ? (
              <button
                onClick={() => window.location.href = `/payment?type=group&id=${membershipStatus.id}&amount=${group.entry_fee}&groupId=${id}`}
                className="bg-orange-600 text-white px-6 py-3 rounded-lg hover:bg-orange-700"
              >
                Complete Payment
              </button>
            ) : (
              <button
                onClick={() => joinMutation.mutate()}
                disabled={joinMutation.isPending}
                className="bg-green-600 text-white px-6 py-3 rounded-lg hover:bg-green-700 disabled:bg-gray-400"
              >
                {joinMutation.isPending ? 'Processing...' : 'Join Group'}
              </button>
            )}
          </div>
        </div>

        {membersError && (
          <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-6">
            <p className="text-yellow-800">Could not load members list</p>
          </div>
        )}

        {members && members.length > 0 && (
          <div>
            <h2 className="text-xl font-bold mb-4">Members ({members.length})</h2>
            <div className="space-y-2">
              {members.map((member: any) => (
                <div key={member.id} className="flex items-center gap-3 p-3 bg-gray-50 rounded">
                  <div className="w-10 h-10 bg-green-600 rounded-full flex items-center justify-center text-white font-bold">
                    {member.user?.name?.[0] || '?'}
                  </div>
                  <div>
                    <p className="font-medium">{member.user?.name || 'Unknown'}</p>
                    <p className="text-sm text-gray-500">{member.user?.role || 'Member'}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
