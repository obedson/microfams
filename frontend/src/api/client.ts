import axios from 'axios';
import { useAuthStore } from '../store/authStore';
import { getActiveOrganizationId } from './tenantHeaders';

const API_BASE_URL = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

export const apiClient = axios.create({
  baseURL: API_BASE_URL,
});

apiClient.interceptors.request.use((config) => {
  const token = useAuthStore.getState().token;
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
  }
  const organizationId = getActiveOrganizationId();
  if (organizationId) {
    config.headers['X-Organization-ID'] = organizationId;
  }
  return config;
});

apiClient.interceptors.response.use(
  (response) => response,
  async (error) => {
    const originalRequest = error.config;
    if (error.response?.status === 401 && !originalRequest._retry && originalRequest.url !== '/auth/login' && originalRequest.url !== '/auth/refresh-token') {
      originalRequest._retry = true;
      try {
        const refreshToken = localStorage.getItem('refreshToken');
        if (refreshToken) {
          const res = await axios.post(`${API_BASE_URL}/auth/refresh-token`, { refreshToken });
          if (res.data?.success && res.data.data?.token) {
            const newAccessToken = res.data.data.token;
            useAuthStore.setState({ token: newAccessToken });
            localStorage.setItem('token', newAccessToken);
            originalRequest.headers.Authorization = `Bearer ${newAccessToken}`;
            return apiClient(originalRequest);
          }
        }
      } catch (refreshError) {
        useAuthStore.getState().logout();
        window.location.href = '/login';
      }
    }
    return Promise.reject(error);
  }
);

export const authAPI = {
  login: (email: string, password: string) =>
    apiClient.post('/auth/login', { email, password }),
  register: (data: any) =>
    apiClient.post('/auth/register', data),
  forgotPassword: (email: string) =>
    apiClient.post('/auth/forgot-password', { email }),
  resetPassword: (token: string, password: string) =>
    apiClient.post('/auth/reset-password', { token, password }),
};

export const propertyAPI = {
  getAll: (filters?: any) =>
    apiClient.get('/properties', { params: filters }),
  getById: (id: string) =>
    apiClient.get(`/properties/${id}`),
  create: (data: any) =>
    apiClient.post('/properties', data),
  update: (id: string, data: any) => {
    const headers: any = {
      'Authorization': `Bearer ${localStorage.getItem('token')}`
    };
    
    // Don't set Content-Type for FormData
    if (!(data instanceof FormData)) {
      headers['Content-Type'] = 'application/json';
      data = JSON.stringify(data);
    }
    
    return apiClient.put(`/properties/${id}`, data, { headers });
  },
  delete: (id: string) =>
    apiClient.delete(`/properties/${id}`),
  deleteImage: (id: string, imageUrl: string) =>
    apiClient.delete(`/properties/${id}/images`, { data: { imageUrl } }),
  reorderImages: (id: string, images: string[]) =>
    apiClient.put(`/properties/${id}/images/reorder`, { images }),};

export const bookingAPI = {
  create: (data: any) =>
    apiClient.post('/bookings', data),
  getMyBookings: () =>
    apiClient.get('/bookings/my-bookings'),
  getBookedDates: (propertyId: string) =>
    apiClient.get(`/bookings/property/${propertyId}/booked-dates`),
};

export const paymentAPI = {
  initialize: (booking_id: string) =>
    apiClient.post('/payments/initialize', { booking_id }),
  verify: (reference: string) =>
    apiClient.get(`/payments/verify/${reference}`),
};
