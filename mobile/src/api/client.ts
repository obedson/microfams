import axios from 'axios';
import AsyncStorage from '@react-native-async-storage/async-storage';

export const API_URL = 'http://10.148.47.234:3001/api'; // Your computer's IP

const apiClient = axios.create({
  baseURL: API_URL,
  headers: {
    'Content-Type': 'application/json',
  },
});

apiClient.interceptors.request.use(async (config) => {
  const token = await AsyncStorage.getItem('token');
  if (token) {
    config.headers.Authorization = `Bearer ${token}`;
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
        const refreshToken = await AsyncStorage.getItem('refreshToken');
        if (refreshToken) {
          const res = await axios.post(`${API_URL}/auth/refresh-token`, { refreshToken });
          if (res.data?.success && res.data.data?.token) {
            const newAccessToken = res.data.data.token;
            await AsyncStorage.setItem('token', newAccessToken);
            originalRequest.headers.Authorization = `Bearer ${newAccessToken}`;
            // Optional: update authStore if possible, but AsyncStorage is enough for next requests
            return apiClient(originalRequest);
          }
        }
      } catch (refreshError) {
        await AsyncStorage.removeItem('token');
        await AsyncStorage.removeItem('refreshToken');
        // Let the app handle the unauthenticated state naturally on next load/check
      }
    }
    return Promise.reject(error);
  }
);

export default apiClient;
