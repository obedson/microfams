import { apiClient } from './client';

export const walletApi = {
  getWallet: (page = 1, limit = 10) => 
    apiClient.get(`/wallet?page=${page}&limit=${limit}`),
  
  getTransaction: (id: string) => 
    apiClient.get(`/wallet/transactions/${id}`),
  
  lookupP2PRecipient: (email: string) =>
    apiClient.post('/wallet/p2p/lookup', { email }),
    
  initiateP2P: (recipientEmail: string, amount: number) => 
    apiClient.post('/wallet/p2p', { recipientEmail, amount }),
  
  previewWithdrawal: (data: { accountNumber: string; bankCode: string; amount: number }) => 
    apiClient.post('/wallet/withdraw', data),
  
  confirmWithdrawal: (data: { previewToken: string }) => 
    apiClient.post('/wallet/withdraw/confirm', data),
  
  syncWithdrawal: (requestId: string) => 
    apiClient.post(`/wallet/withdraw/${requestId}/sync`),
  
  getGroupWallet: (groupId: string) => 
    apiClient.get(`/wallet/groups/${groupId}`),
  
  initiateGroupWithdrawal: (groupId: string, data: { amount: number; targetUserId: string }) => 
    apiClient.post(`/wallet/groups/${groupId}/withdraw`, data),
  
  castApprovalVote: (requestId: string) => 
    apiClient.post(`/wallet/groups/withdraw/${requestId}/approve`),
    
  getGroupWithdrawalRequest: (requestId: string) => 
    apiClient.get(`/wallet/groups/withdraw/${requestId}`)
};
