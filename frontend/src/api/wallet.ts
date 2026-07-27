import { apiClient } from './client';

export const walletApi = {
  getWallet: (page = 1, limit = 10) =>
    apiClient.get(`/wallet?page=${page}&limit=${limit}`),

  getStatement: (from: string, to: string, cutoff: string, page = 1, limit = 25) =>
    apiClient.get('/wallet/statement', { params: { from, to, cutoff, page, limit, currency: 'NGN' } }),
  
  getTransaction: (id: string) => 
    apiClient.get(`/wallet/transactions/${id}`),
  
  lookupP2PRecipient: (email: string) =>
    apiClient.post('/wallet/p2p/lookup', { email }),
    
  initiateP2P: (recipientEmail: string, amountMinor: number, idempotencyKey: string) =>
    apiClient.post('/wallet/p2p', { recipientEmail, amountMinor, currency: 'NGN', idempotencyKey }),
  
  previewWithdrawal: (data: { accountNumber: string; bankCode: string; amountMinor: number; idempotencyKey: string; currency: 'NGN' }) =>
    apiClient.post('/wallet/withdraw', data),
  
  confirmWithdrawal: (data: { previewToken: string }) => 
    apiClient.post('/wallet/withdraw/confirm', data),
  
  syncWithdrawal: (requestId: string) => 
    apiClient.post(`/wallet/withdraw/${requestId}/sync`),
  
  getGroupWallet: (groupId: string) =>
    apiClient.get(`/wallet/groups/${groupId}`),

  getGroupStatement: (groupId: string, from: string, to: string, cutoff: string, page = 1, limit = 25) =>
    apiClient.get(`/wallet/groups/${groupId}/statement`, {
      params: { from, to, cutoff, page, limit, currency: 'NGN' },
    }),
  
  initiateGroupWithdrawal: (groupId: string, data: { amountMinor: number; currency: 'NGN'; idempotencyKey: string; targetUserId: string }) =>
    apiClient.post(`/wallet/groups/${groupId}/withdraw`, data),
  
  castApprovalVote: (requestId: string) => 
    apiClient.post(`/wallet/groups/withdraw/${requestId}/approve`),
    
  getGroupWithdrawalRequest: (requestId: string) => 
    apiClient.get(`/wallet/groups/withdraw/${requestId}`)
};
