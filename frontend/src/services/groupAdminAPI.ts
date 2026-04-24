import { apiClient } from '../api/client';

export const groupAdminApi = {
  getAdminDashboard: (groupId: string) => 
    apiClient.get(`/group-admin/${groupId}/admin/dashboard`),
  
  updateGroup: (groupId: string, data: any) => 
    apiClient.put(`/group-admin/${groupId}`, data),
  
  castVote: (groupId: string, memberId: string, actionType: 'SUSPEND' | 'EXPEL') => 
    apiClient.post(`/group-admin/${groupId}/members/${memberId}/vote`, { actionType }),
  
  getVotes: (groupId: string) => 
    apiClient.get(`/group-admin/${groupId}/votes`),
  
  getMemberDashboard: (groupId: string) => 
    apiClient.get(`/group-admin/${groupId}/member/dashboard`)
};
