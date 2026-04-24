import { apiClient } from '../api/client';

export const profileApi = {
  getProfile: () => 
    apiClient.get('/auth/profile'),
  
  verifyNIN: (nin: string, consent: boolean) => 
    apiClient.post('/auth/profile/verify-nin', { nin, consent }),

  sendOTP: (requestRef: string, fullPhone: string) =>
    apiClient.post('/auth/profile/send-otp', { requestRef, fullPhone }),
  
  confirmOTP: (requestRef: string, otp: string) => 
    apiClient.post('/auth/profile/confirm-otp', { requestRef, otp }),
  
  uploadProfilePicture: (file: File) => {
    const formData = new FormData();
    formData.append('image', file);
    return apiClient.post('/auth/profile/upload-profile-picture', formData, {
      headers: { 'Content-Type': 'multipart/form-data' }
    });
  },
  
  subscribe: (paymentReference: string) => 
    apiClient.post('/auth/profile/subscribe', { payment_reference: paymentReference })
};
