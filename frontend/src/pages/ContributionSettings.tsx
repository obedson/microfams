import React, { useState } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { useQuery, useMutation } from '@tanstack/react-query';
import { Settings, Save } from 'lucide-react';
import { apiClient } from '../api/client';
import { useAuthStore } from '../store/authStore';

export default function ContributionSettings() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { user } = useAuthStore();

  const { data: group, isLoading: groupLoading } = useQuery({
    queryKey: ['group', id],
    queryFn: () => apiClient.get(`/groups/${id}`).then(r => r.data)
  });

  const { data: settings, isLoading } = useQuery({
    queryKey: ['contribution-settings', id],
    queryFn: () => apiClient.get(`/groups/${id}/contributions/settings`).then(r => r.data),
    enabled: !!group && group.creator_id === user?.id
  });

  const [formData, setFormData] = useState({
    contribution_enabled: false,
    contribution_amount: 1000,
    payment_day: 5,
    grace_period_days: 3,
    late_penalty_amount: 500,
    late_penalty_type: 'fixed',
    auto_suspend_after: 2,
    auto_expel_after: 3
  });

  React.useEffect(() => {
    if (group && group.creator_id !== user?.id) {
      alert('Only the group owner can access settings');
      navigate(`/groups/${id}`);
    }
  }, [group, user, id, navigate]);

  React.useEffect(() => {
    if (settings) setFormData(settings);
  }, [settings]);

  const saveMutation = useMutation({
    mutationFn: () => apiClient.post(`/groups/${id}/contributions/settings`, formData),
    onSuccess: () => {
      alert('Settings saved successfully!');
      navigate(`/groups/${id}/contributions`);
    }
  });

  if (groupLoading || isLoading) return <div className="text-center py-12">Loading...</div>;
  if (!group || group.creator_id !== user?.id) return null;

  return (
    <div className="max-w-3xl mx-auto px-4 py-8">
      <div className="flex items-center gap-3 mb-8">
        <Settings size={32} className="text-green-600" />
        <h1 className="text-3xl font-bold">Contribution Settings</h1>
      </div>

      <div className="bg-white rounded-lg shadow p-6 space-y-6">
        <div className="flex items-center gap-3">
          <input
            type="checkbox"
            checked={formData.contribution_enabled}
            onChange={(e) => setFormData({ ...formData, contribution_enabled: e.target.checked })}
            className="w-5 h-5"
          />
          <label className="text-lg font-medium">Enable Monthly Contributions</label>
        </div>

        {formData.contribution_enabled && (
          <>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <label className="block text-sm font-medium mb-2">Monthly Amount (₦)</label>
                <input
                  type="number"
                  min="500"
                  max="50000"
                  value={formData.contribution_amount}
                  onChange={(e) => setFormData({ ...formData, contribution_amount: Number(e.target.value) })}
                  className="w-full border px-4 py-2 rounded-lg"
                />
              </div>

              <div>
                <label className="block text-sm font-medium mb-2">Payment Day (1-28)</label>
                <input
                  type="number"
                  min="1"
                  max="28"
                  value={formData.payment_day}
                  onChange={(e) => setFormData({ ...formData, payment_day: Number(e.target.value) })}
                  className="w-full border px-4 py-2 rounded-lg"
                />
              </div>

              <div>
                <label className="block text-sm font-medium mb-2">Grace Period (days)</label>
                <input
                  type="number"
                  min="0"
                  max="7"
                  value={formData.grace_period_days}
                  onChange={(e) => setFormData({ ...formData, grace_period_days: Number(e.target.value) })}
                  className="w-full border px-4 py-2 rounded-lg"
                />
              </div>

              <div>
                <label className="block text-sm font-medium mb-2">Penalty Type</label>
                <select
                  value={formData.late_penalty_type}
                  onChange={(e) => setFormData({ ...formData, late_penalty_type: e.target.value })}
                  className="w-full border px-4 py-2 rounded-lg"
                >
                  <option value="fixed">Fixed Amount</option>
                  <option value="percentage">Percentage</option>
                </select>
              </div>

              <div>
                <label className="block text-sm font-medium mb-2">
                  Penalty {formData.late_penalty_type === 'percentage' ? '(%)' : '(₦)'}
                </label>
                <input
                  type="number"
                  min="0"
                  value={formData.late_penalty_amount}
                  onChange={(e) => setFormData({ ...formData, late_penalty_amount: Number(e.target.value) })}
                  className="w-full border px-4 py-2 rounded-lg"
                />
              </div>

              <div>
                <label className="block text-sm font-medium mb-2">Auto-Suspend After (missed)</label>
                <input
                  type="number"
                  min="1"
                  value={formData.auto_suspend_after}
                  onChange={(e) => setFormData({ ...formData, auto_suspend_after: Number(e.target.value) })}
                  className="w-full border px-4 py-2 rounded-lg"
                />
              </div>

              <div>
                <label className="block text-sm font-medium mb-2">Auto-Expel After (missed)</label>
                <input
                  type="number"
                  min="1"
                  value={formData.auto_expel_after}
                  onChange={(e) => setFormData({ ...formData, auto_expel_after: Number(e.target.value) })}
                  className="w-full border px-4 py-2 rounded-lg"
                />
              </div>
            </div>
          </>
        )}

        <div className="flex gap-4 pt-4">
          <button
            onClick={() => saveMutation.mutate()}
            disabled={saveMutation.isPending}
            className="flex-1 bg-green-600 text-white py-3 rounded-lg hover:bg-green-700 flex items-center justify-center gap-2"
          >
            <Save size={20} />
            {saveMutation.isPending ? 'Saving...' : 'Save Settings'}
          </button>
          <button
            onClick={() => navigate(`/groups/${id}`)}
            className="flex-1 bg-gray-200 py-3 rounded-lg hover:bg-gray-300"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}
