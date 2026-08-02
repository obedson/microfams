import { apiClient } from '../api/client';

const commandHeaders = (scope: string) => ({
  headers: {
    'Idempotency-Key': `${scope}:${Date.now()}:${Math.random().toString(36).slice(2)}`,
  },
});

export interface CreateGroupDisciplineCaseInput {
  proposedAction: 'suspend' | 'expel';
  reasonCode: string;
  publicNotice: string;
  privateEvidenceRefs: string[];
  responseDueAt: string;
  proposalClosesAt: string;
  appealWindowDays: number;
}

export const groupAdminApi = {
  getAdminDashboard: (groupId: string) => 
    apiClient.get(`/group-admin/${groupId}/admin/dashboard`),
  
  updateGroup: (groupId: string, data: any) => 
    apiClient.put(`/group-admin/${groupId}`, data),
  
  createDisciplineCase: (groupId: string, memberId: string, data: CreateGroupDisciplineCaseInput) =>
    apiClient.post(
      `/group-admin/${groupId}/members/${memberId}/discipline-cases`,
      data,
      commandHeaders(`discipline-${memberId}`),
    ),

  getDisciplineCase: (groupId: string, caseId: string) =>
    apiClient.get(`/group-admin/${groupId}/discipline-cases/${caseId}`),

  executeDisciplineCase: (groupId: string, caseId: string, expectedMembershipVersion: number) =>
    apiClient.post(
      `/group-admin/${groupId}/discipline-cases/${caseId}/execute`,
      { expectedMembershipVersion },
      commandHeaders(`discipline-execute-${caseId}`),
    ),

  fileDisciplineAppeal: (groupId: string, caseId: string, grounds: string, evidenceRefs: string[]) =>
    apiClient.post(
      `/group-admin/${groupId}/discipline-cases/${caseId}/appeals`,
      { grounds, evidenceRefs },
      commandHeaders(`discipline-appeal-${caseId}`),
    ),
  
  getMemberDashboard: (groupId: string) => 
    apiClient.get(`/group-admin/${groupId}/member/dashboard`)
};
