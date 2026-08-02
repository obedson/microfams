import React, { useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { CreateGroupDisciplineCaseInput, groupAdminApi } from '../services/groupAdminAPI';
import GroupDisciplineCaseForm from '../components/groups/GroupDisciplineCaseForm';
import { Users, DollarSign, Settings, ShieldAlert, BarChart3, Clock, ArrowLeft, Edit3, CheckCircle, XCircle } from 'lucide-react';
import toast from 'react-hot-toast';

export default function GroupAdminDashboard() {
  const { id: groupId } = useParams<{ id: string }>();
  const queryClient = useQueryClient();
  const [disciplineMember, setDisciplineMember] = useState<any | null>(null);

  const { data: dashboard, isLoading } = useQuery({
    queryKey: ['group-admin-dashboard', groupId],
    queryFn: () => groupAdminApi.getAdminDashboard(groupId!).then((res: any) => res.data)
  });

  const disciplineMutation = useMutation({
    mutationFn: (value: CreateGroupDisciplineCaseInput) =>
      groupAdminApi.createDisciplineCase(groupId!, disciplineMember.id, value),
    onSuccess: () => {
      toast.success('Notice issued and a proposal draft created.');
      setDisciplineMember(null);
      queryClient.invalidateQueries({ queryKey: ['group-admin-dashboard', groupId] });
    },
    onError: (err: any) => toast.error(err.response?.data?.error || 'Failed to create discipline review')
  });

  if (isLoading) return <div className="p-8 text-center">Loading Dashboard...</div>;

  const { group, stats, wallet, members, disciplineCases = [] } = dashboard;

  return (
    <div className="max-w-7xl mx-auto px-4 py-8">
      <div className="flex items-center gap-4 mb-8">
        <Link to={`/groups/${groupId}`} className="p-2 hover:bg-gray-100 rounded-full transition-colors">
          <ArrowLeft size={24} />
        </Link>
        <div>
          <h1 className="text-3xl font-bold text-gray-900">{group.name}</h1>
          <p className="text-gray-500">Group Management Console</p>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-4 gap-8">
        {/* Stats Grid */}
        <div className="lg:col-span-3 space-y-8">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
            <div className="bg-white p-6 rounded-2xl shadow-sm border border-gray-100">
              <div className="flex items-center gap-4">
                <div className="p-3 bg-blue-50 text-blue-600 rounded-xl"><Users size={24} /></div>
                <div>
                  <p className="text-sm text-gray-500 font-medium">Paid Members</p>
                  <p className="text-2xl font-bold text-gray-900">{stats.memberCount} / {group.max_members}</p>
                </div>
              </div>
            </div>
            <div className="bg-white p-6 rounded-2xl shadow-sm border border-gray-100">
              <div className="flex items-center gap-4">
                <div className="p-3 bg-green-50 text-green-600 rounded-xl"><DollarSign size={24} /></div>
                <div>
                  <p className="text-sm text-gray-500 font-medium">Fund Balance</p>
                  <p className="text-2xl font-bold text-gray-900">₦{group.group_fund_balance.toLocaleString()}</p>
                </div>
              </div>
            </div>
            <div className="bg-white p-6 rounded-2xl shadow-sm border border-gray-100">
              <div className="flex items-center gap-4">
                <div className="p-3 bg-purple-50 text-purple-600 rounded-xl"><BarChart3 size={24} /></div>
                <div>
                  <p className="text-sm text-gray-500 font-medium">Cycle Status</p>
                  <p className="text-2xl font-bold text-gray-900 capitalize">{group.status || 'Active'}</p>
                </div>
              </div>
            </div>
          </div>

          {/* Member Management */}
          <div className="bg-white rounded-2xl shadow-sm border border-gray-100 overflow-hidden">
            <div className="px-6 py-4 border-b border-gray-100 flex justify-between items-center">
              <h2 className="font-bold text-gray-900 text-lg">Member Management</h2>
              <span className="text-xs bg-gray-100 text-gray-600 px-2 py-1 rounded-full uppercase font-bold">{members.length} Total</span>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full">
                <thead className="bg-gray-50">
                  <tr>
                    <th className="px-6 py-3 text-left text-xs font-bold text-gray-500 uppercase">User</th>
                    <th className="px-6 py-3 text-left text-xs font-bold text-gray-500 uppercase">Status</th>
                    <th className="px-6 py-3 text-left text-xs font-bold text-gray-500 uppercase">Verification</th>
                    <th className="px-6 py-3 text-right text-xs font-bold text-gray-500 uppercase">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  {members.map((member: any) => (
                    <tr key={member.id} className="hover:bg-gray-50 transition-colors">
                      <td className="px-6 py-4">
                        <div className="flex items-center gap-3">
                          <div className="w-8 h-8 rounded-full bg-gray-200 overflow-hidden">
                            {member.user?.profile_picture_url ? (
                              <img src={member.user.profile_picture_url} className="w-full h-full object-cover" />
                            ) : (
                              <div className="w-full h-full flex items-center justify-center text-xs font-bold text-gray-500 uppercase">
                                {member.user?.name?.charAt(0)}
                              </div>
                            )}
                          </div>
                          <div>
                            <p className="text-sm font-bold text-gray-900">{member.user?.name}</p>
                            <p className="text-xs text-gray-500">{member.user?.email}</p>
                          </div>
                        </div>
                      </td>
                      <td className="px-6 py-4">
                        <span className={`px-2 py-1 rounded-full text-[10px] font-bold uppercase tracking-wider ${
                          member.status === 'active' ? 'bg-green-100 text-green-700' : 
                          member.status === 'suspended' ? 'bg-yellow-100 text-yellow-700' : 'bg-red-100 text-red-700'
                        }`}>
                          {member.status}
                        </span>
                      </td>
                      <td className="px-6 py-4">
                        {member.user?.nin_verified ? (
                          <div className="flex items-center gap-1 text-green-600 text-xs font-medium">
                            <CheckCircle size={14} /> Verified
                          </div>
                        ) : (
                          <div className="flex items-center gap-1 text-gray-400 text-xs font-medium">
                            <XCircle size={14} /> Unverified
                          </div>
                        )}
                      </td>
                      <td className="px-6 py-4 text-right">
                        <div className="flex justify-end gap-2">
                          {['active', 'suspended'].includes(member.status) && (
                            <button
                              onClick={() => setDisciplineMember(member)}
                              className="inline-flex items-center gap-2 px-3 py-2 text-amber-700 hover:bg-amber-50 rounded-lg transition-colors text-xs font-semibold"
                              title="Start a noticed, proposal-backed discipline review"
                            >
                              <ShieldAlert size={16} /> Start review
                            </button>
                          )}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>

        {/* Sidebar: Details & Settings */}
        <div className="space-y-8">
          <div className="bg-white p-6 rounded-2xl shadow-sm border border-gray-100">
            <h3 className="font-bold text-gray-900 mb-4 flex items-center gap-2">
              <Settings size={18} className="text-gray-400" /> Group Settings
            </h3>
            <div className="space-y-4">
              <button className="w-full flex items-center justify-between p-3 rounded-xl hover:bg-gray-50 border border-transparent hover:border-gray-100 transition-all text-sm font-medium">
                <span>Edit Profile</span>
                <Edit3 size={16} className="text-gray-400" />
              </button>
              <button className="w-full flex items-center justify-between p-3 rounded-xl hover:bg-gray-50 border border-transparent hover:border-gray-100 transition-all text-sm font-medium">
                <span>Update Contribution</span>
                <Clock size={16} className="text-gray-400" />
              </button>
            </div>
          </div>

          <div className="bg-gray-900 text-white p-6 rounded-2xl shadow-lg">
            <h3 className="font-bold text-primary-400 mb-2 flex items-center gap-2">
              <DollarSign size={18} /> Banking Details
            </h3>
            {wallet.nuban ? (
              <div className="space-y-4">
                <div>
                  <p className="text-[10px] uppercase font-bold text-gray-400">Virtual NUBAN</p>
                  <p className="text-xl font-mono tracking-wider">{wallet.nuban.nuban}</p>
                </div>
                <div>
                  <p className="text-[10px] uppercase font-bold text-gray-400">Bank Name</p>
                  <p className="text-sm font-medium">{wallet.nuban.bank_name}</p>
                </div>
                <div className="pt-2">
                  <span className="px-2 py-0.5 bg-green-500/20 text-green-400 text-[10px] font-bold rounded uppercase">Active</span>
                </div>
              </div>
            ) : (
              <p className="text-sm text-gray-400">Account provisioning in progress...</p>
            )}
          </div>

          {disciplineCases.length > 0 && (
            <div className="bg-red-50 p-6 rounded-2xl border border-red-100">
              <h3 className="font-bold text-red-900 mb-4 flex items-center gap-2">
                <ShieldAlert size={18} /> Discipline reviews
              </h3>
              <div className="space-y-3">
                {disciplineCases.map((disciplineCase: any) => (
                  <div key={disciplineCase.id} className="bg-white p-3 rounded-xl shadow-sm border border-red-50">
                    <p className="text-xs font-bold text-gray-900 capitalize">{disciplineCase.proposed_action} · {disciplineCase.state.replaceAll('_', ' ')}</p>
                    <p className="text-xs text-gray-600 mt-1">{disciplineCase.public_notice}</p>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>
      {disciplineMember && (
        <div role="dialog" aria-modal="true" className="fixed inset-0 z-50 bg-black/50 p-4 flex items-center justify-center">
          <div className="bg-white rounded-2xl shadow-xl max-w-2xl w-full max-h-[90vh] overflow-y-auto p-6">
            <GroupDisciplineCaseForm
              memberName={disciplineMember.user?.name || 'Member'}
              submitting={disciplineMutation.isLoading}
              onCancel={() => setDisciplineMember(null)}
              onSubmit={(value) => disciplineMutation.mutate(value)}
            />
          </div>
        </div>
      )}
    </div>
  );
}
