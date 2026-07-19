import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import { useAuthStore } from './authStore';

export interface OrganizationMembership {
  id: string;
  userId: string;
  organizationId: string;
  role: string;
  permissions: string[];
  organization: {
    id: string;
    name: string;
    slug: string;
    type: string;
    jurisdiction: string;
    defaultCurrency: string;
    timezone: string;
    status: 'active' | 'suspended' | 'closed';
  };
}

interface OrganizationState {
  memberships: OrganizationMembership[];
  activeOrganizationId: string | null;
  loading: boolean;
  error: string | null;
  loadOrganizations: () => Promise<void>;
  selectOrganization: (organizationId: string) => void;
  clear: () => void;
}

const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

export const useOrganizationStore = create<OrganizationState>()(
  persist(
    (set, get) => ({
      memberships: [],
      activeOrganizationId: null,
      loading: false,
      error: null,
      loadOrganizations: async () => {
        const token = useAuthStore.getState().token || localStorage.getItem('token');
        if (!token) return;
        set({ loading: true, error: null });
        try {
          const response = await fetch(`${API_BASE}/organizations`, {
            headers: { Authorization: `Bearer ${token}` },
          });
          if (!response.ok) throw new Error('Unable to load organizations');
          const payload = await response.json();
          const memberships = (payload.data || []) as OrganizationMembership[];
          const current = get().activeOrganizationId;
          const activeOrganizationId = memberships.some((item) => item.organizationId === current)
            ? current
            : memberships.length === 1 ? memberships[0].organizationId : null;
          set({ memberships, activeOrganizationId, loading: false });
        } catch (error) {
          set({ loading: false, error: error instanceof Error ? error.message : 'Unable to load organizations' });
        }
      },
      selectOrganization: (organizationId) => {
        if (!get().memberships.some((item) => item.organizationId === organizationId)) return;
        set({ activeOrganizationId: organizationId });
      },
      clear: () => set({ memberships: [], activeOrganizationId: null, loading: false, error: null }),
    }),
    {
      name: 'organization-storage',
      partialize: (state) => ({ activeOrganizationId: state.activeOrganizationId }),
    },
  ),
);
