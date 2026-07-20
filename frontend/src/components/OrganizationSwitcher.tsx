import React, { useEffect } from 'react';
import { Building2 } from 'lucide-react';
import { useOrganizationStore } from '../store/organizationStore';

const OrganizationSwitcher: React.FC = () => {
  const { memberships, activeOrganizationId, loading, error, loadOrganizations, selectOrganization } = useOrganizationStore();

  useEffect(() => {
    void loadOrganizations();
  }, [loadOrganizations]);

  if (loading && memberships.length === 0) {
    return <span className="text-sm text-gray-500">Loading organization...</span>;
  }
  if (error) return <span className="text-sm text-red-600" title={error}>Organization unavailable</span>;
  if (memberships.length === 0) return null;

  return (
    <label className="flex items-center gap-2 text-sm text-gray-700" aria-label="Active organization">
      <Building2 size={16} aria-hidden="true" />
      <select
        className="max-w-52 rounded-md border-gray-300 py-1.5 text-sm focus:border-primary-500 focus:ring-primary-500"
        value={activeOrganizationId || ''}
        onChange={(event) => {
          selectOrganization(event.target.value);
          if (process.env.NODE_ENV !== 'test') {
            window.location.reload();
          }
        }}
      >
        {memberships.length > 1 && <option value="" disabled>Select organization</option>}
        {memberships.map((membership) => (
          <option key={membership.organizationId} value={membership.organizationId}>
            {membership.organization.name} - {membership.role}
          </option>
        ))}
      </select>
    </label>
  );
};

export default OrganizationSwitcher;
