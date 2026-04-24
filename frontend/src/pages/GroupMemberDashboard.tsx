import React from 'react';
import { useParams, Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { groupAdminApi } from '../services/groupAdminAPI';
import { Users, DollarSign, Calendar, Info, ArrowLeft, CheckCircle, Clock } from 'lucide-react';

export default function GroupMemberDashboard() {
  const { id: groupId } = useParams<{ id: string }>();

  const { data: dashboard, isLoading } = useQuery({
    queryKey: ['group-member-dashboard', groupId],
    queryFn: () => groupAdminApi.getMemberDashboard(groupId!).then((res: any) => res.data)
  });

  if (isLoading) return <div className="p-8 text-center">Loading your dashboard...</div>;

  const { group, membership, members } = dashboard;

  return (
    <div className="max-w-5xl mx-auto px-4 py-8">
      <div className="flex items-center gap-4 mb-8">
        <Link to={`/groups/${groupId}`} className="p-2 hover:bg-gray-100 rounded-full transition-colors">
          <ArrowLeft size={24} />
        </Link>
        <div>
          <h1 className="text-3xl font-bold text-gray-900">{group.name}</h1>
          <p className="text-gray-500">Member Portal</p>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
        {/* Main Content */}
        <div className="md:col-span-2 space-y-8">
          <div className="bg-white p-8 rounded-3xl shadow-sm border border-gray-100">
            <h2 className="text-xl font-bold text-gray-900 mb-6 flex items-center gap-2">
              <Info size={20} className="text-primary-600" /> Group Information
            </h2>
            <div className="space-y-4">
              <p className="text-gray-600 leading-relaxed">{group.description}</p>
              <div className="grid grid-cols-2 gap-6 pt-4">
                <div className="p-4 bg-gray-50 rounded-2xl border border-gray-100">
                  <p className="text-xs text-gray-400 uppercase font-bold mb-1">Category</p>
                  <p className="font-bold text-gray-900 capitalize">{group.category}</p>
                </div>
                <div className="p-4 bg-gray-50 rounded-2xl border border-gray-100">
                  <p className="text-xs text-gray-400 uppercase font-bold mb-1">Created</p>
                  <p className="font-bold text-gray-900">{new Date(group.created_at).toLocaleDateString()}</p>
                </div>
              </div>
            </div>
          </div>

          <div className="bg-white rounded-3xl shadow-sm border border-gray-100 overflow-hidden">
            <div className="px-8 py-6 border-b border-gray-100 flex justify-between items-center bg-gray-50/50">
              <h2 className="font-bold text-gray-900 flex items-center gap-2">
                <Users size={20} className="text-gray-400" /> Community Members
              </h2>
              <span className="px-3 py-1 bg-white border border-gray-200 rounded-full text-xs font-bold text-gray-600">{members.length} Total</span>
            </div>
            <div className="p-8">
              <div className="flex flex-wrap gap-2">
                {members.map((name: string, i: number) => (
                  <span key={i} className="px-4 py-2 bg-gray-50 text-gray-700 rounded-xl text-sm font-medium border border-gray-100">
                    {name}
                  </span>
                ))}
              </div>
            </div>
          </div>
        </div>

        {/* Sidebar: Personal Status */}
        <div className="space-y-8">
          <div className="bg-primary-600 text-white p-8 rounded-3xl shadow-xl shadow-primary-100">
            <h3 className="font-bold text-primary-100 mb-6 flex items-center gap-2">
              <CheckCircle size={20} /> Membership Status
            </h3>
            <div className="space-y-6">
              <div>
                <p className="text-xs text-primary-200 uppercase font-bold mb-1">Your Role</p>
                <p className="text-2xl font-bold capitalize">{membership.role}</p>
              </div>
              <div>
                <p className="text-xs text-primary-200 uppercase font-bold mb-1">Total Contributed</p>
                <p className="text-2xl font-bold">₦{membership.total_contributed?.toLocaleString() || '0'}</p>
              </div>
              <div className="pt-4">
                <span className="px-3 py-1 bg-white/20 rounded-full text-xs font-bold uppercase tracking-wider">
                  {membership.status}
                </span>
              </div>
            </div>
          </div>

          <div className="bg-white p-8 rounded-3xl shadow-sm border border-gray-100">
            <h3 className="font-bold text-gray-900 mb-6 flex items-center gap-2">
              <Clock size={20} className="text-orange-500" /> Current Cycle
            </h3>
            <div className="space-y-4">
              <div className="flex justify-between items-center p-4 bg-orange-50 rounded-2xl border border-orange-100">
                <p className="text-sm font-medium text-orange-800">Payment Status</p>
                <span className="px-2 py-1 bg-white text-orange-600 rounded-lg text-xs font-bold uppercase">Pending</span>
              </div>
              <p className="text-xs text-gray-400 text-center italic">Next contribution deadline will be announced soon.</p>
            </div>
          </div>

          <div className="bg-gray-900 text-white p-8 rounded-3xl">
            <div className="flex items-center gap-3 mb-2">
              <DollarSign size={20} className="text-primary-400" />
              <p className="text-xs text-gray-400 uppercase font-bold">Group Fund Balance</p>
            </div>
            <p className="text-3xl font-bold text-white">₦{group.group_fund_balance.toLocaleString()}</p>
            <p className="text-[10px] text-gray-500 mt-2">Shared liquidity available for community investments.</p>
          </div>
        </div>
      </div>
    </div>
  );
}
