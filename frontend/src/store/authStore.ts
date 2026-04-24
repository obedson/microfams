import { create } from 'zustand';
import { persist } from 'zustand/middleware';

interface User {
  id: string;
  email: string;
  name: string;
  role: 'farmer' | 'owner' | 'admin';
  referral_code?: string;
  paid_referrals_count?: number;
  profile_picture_url?: string | null;
  nin_verified?: boolean;
  is_platform_subscriber?: boolean;
}

interface AuthState {
  user: User | null;
  token: string | null;
  refreshToken: string | null;
  isAuthenticated: boolean;
  login: (user: User, token: string, refreshToken: string) => void;
  logout: () => void;
  updateUser: (data: Partial<User>) => void;
}

export const useAuthStore = create<AuthState>()(
  persist(
    (set) => ({
      user: null,
      token: null,
      refreshToken: null,
      isAuthenticated: false,
      login: (user, token, refreshToken) => {
        localStorage.setItem('token', token);
        localStorage.setItem('refreshToken', refreshToken);
        localStorage.setItem('user', JSON.stringify(user));
        set({ user, token, refreshToken, isAuthenticated: true });
      },
      logout: () => {
        localStorage.removeItem('token');
        localStorage.removeItem('refreshToken');
        localStorage.removeItem('user');
        set({ user: null, token: null, refreshToken: null, isAuthenticated: false });
      },
      updateUser: (data) => {
        set((state) => {
          if (!state.user) return state;
          const updatedUser = { ...state.user, ...data };
          localStorage.setItem('user', JSON.stringify(updatedUser));
          return { user: updatedUser };
        });
      },
    }),
    {
      name: 'auth-storage',
    }
  )
);
