import { create } from 'zustand';
import AsyncStorage from '@react-native-async-storage/async-storage';
import apiClient from '../api/client';

interface User {
  id: string;
  email: string;
  name: string;
  role: string;
}

interface AuthState {
  user: User | null;
  token: string | null;
  refreshToken: string | null;
  isAuthenticated: boolean;
  isLoading: boolean;
  login: (email: string, password: string) => Promise<void>;
  register: (name: string, email: string, password: string, role: string) => Promise<void>;
  logout: () => Promise<void>;
  loadUser: () => Promise<void>;
}

export const useAuthStore = create<AuthState>((set) => ({
  user: null,
  token: null,
  refreshToken: null,
  isAuthenticated: false,
  isLoading: true,

  login: async (email: string, password: string) => {
    try {
      console.log('Attempting login...', { email });
      const response = await apiClient.post('/auth/login', { email, password });
      console.log('Login response:', response.data);
      const { token, refreshToken, user } = response.data.data || response.data;
      await AsyncStorage.setItem('token', token);
      if (refreshToken) await AsyncStorage.setItem('refreshToken', refreshToken);
      set({ user, token, refreshToken, isAuthenticated: true });
    } catch (error: any) {
      console.error('Login error:', error.response?.data || error.message);
      throw error;
    }
  },

  register: async (name: string, email: string, password: string, role: string) => {
    try {
      console.log('Attempting registration...', { name, email, role });
      const response = await apiClient.post('/auth/register', { name, email, password, role });
      console.log('Register response:', response.data);
      const { token, refreshToken, user } = response.data.data || response.data;
      await AsyncStorage.setItem('token', token);
      if (refreshToken) await AsyncStorage.setItem('refreshToken', refreshToken);
      set({ user, token, refreshToken, isAuthenticated: true });
    } catch (error: any) {
      console.error('Register error:', error.response?.data || error.message);
      throw error;
    }
  },

  logout: async () => {
    await AsyncStorage.removeItem('token');
    await AsyncStorage.removeItem('refreshToken');
    set({ user: null, token: null, refreshToken: null, isAuthenticated: false });
  },

  loadUser: async () => {
    try {
      const token = await AsyncStorage.getItem('token');
      const refreshToken = await AsyncStorage.getItem('refreshToken');
      if (token) {
        const response = await apiClient.get('/auth/me');
        set({ user: response.data, token, refreshToken, isAuthenticated: true, isLoading: false });
      } else {
        set({ isLoading: false });
      }
    } catch (error) {
      await AsyncStorage.removeItem('token');
      await AsyncStorage.removeItem('refreshToken');
      set({ user: null, token: null, refreshToken: null, isAuthenticated: false, isLoading: false });
    }
  },
}));
