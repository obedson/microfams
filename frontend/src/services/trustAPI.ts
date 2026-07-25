import { apiClient } from '../api/client';

export type TrustReviewState = 'open' | 'assigned' | 'decided' | 'appealed' | 'closed';
export type AppealState = 'filed' | 'assigned' | 'upheld' | 'modified' | 'overturned' | 'dismissed';

export interface TrustDecision {
  id: string;
  caseId: string;
  reviewerId: string;
  outcome: 'no_action' | 'warning' | 'suspend_membership' | 'suspend_organization' | 'suspend_user' | 'refer';
  reasonCode: string;
  decidedAt: string;
}

export interface TrustReviewCase {
  id: string;
  organizationId: string | null;
  subjectType: 'user' | 'membership' | 'organization' | 'transaction' | 'content' | 'other';
  subjectId: string;
  priority: 'low' | 'normal' | 'high' | 'urgent';
  state: TrustReviewState;
  assignedReviewerId: string | null;
}

export interface TrustAppeal {
  id: string;
  caseId: string;
  appellantId: string;
  state: AppealState;
  assignedReviewerId: string | null;
  filedAt: string;
  decidedAt: string | null;
}

export interface IdentityTrustStatus {
  subjectType: TrustReviewCase['subjectType'];
  subjectId: string;
  activeCase: TrustReviewCase | null;
  activeAppeal: TrustAppeal | null;
  suspended: boolean;
}

const data = <T>(response: { data: { data?: T } | T }): T => {
  const body = response.data as { data?: T };
  return body.data === undefined ? response.data as T : body.data;
};

const commandHeaders = (scope: string) => ({
  'Idempotency-Key': `${scope}:${Date.now()}:${Math.random().toString(36).slice(2)}`
});

export interface LegalHold { id:string; organizationId:string|null; subjectType:'user'|'organization'|'membership'|'case'|'data_class'; subjectId:string; reasonCode:string; status:'active'|'released'; placedAt:string; releasedAt:string|null; }

export interface SuspendedRecoveryStatus { caseId: string; suspended: boolean; expiresAt: string; appealStatus: AppealState | null; }

export const trustAPI = {
  listLegalHolds: async () => data<LegalHold[]>(await apiClient.get('/admin/trust/legal-holds')),
  placeLegalHold: async (input: {organizationId?:string;subjectType:LegalHold['subjectType'];subjectId:string;reasonCode:string;note?:string}) => data<LegalHold>(await apiClient.post('/admin/trust/legal-holds', input, {headers:commandHeaders('legal-hold-place')})),
  releaseLegalHold: async (holdId:string,reasonCode:string,note?:string) => data<LegalHold>(await apiClient.post(`/admin/trust/legal-holds/${holdId}/release`, {reasonCode,note}, {headers:commandHeaders(`legal-hold-release:${holdId}`)})),
  requestSuspendedRecovery: async (email: string) => apiClient.post('/trust/recovery/request', { email }),
  inspectSuspendedRecovery: async (token: string) => data<SuspendedRecoveryStatus>(await apiClient.get('/trust/recovery/status', { params: { token } })),
  submitSuspendedRecoveryAppeal: async (token: string, grounds: string) => data<TrustAppeal>(await apiClient.post('/trust/recovery/appeals', { token, grounds }, { headers: commandHeaders('suspended-recovery-appeal') })),
  getIdentityStatus: async () => data<IdentityTrustStatus>(await apiClient.get('/trust/self/status')),
  listSelfDecisions: async () => data<TrustDecision[]>(await apiClient.get('/trust/self/decisions')),
  submitAppeal: async (caseId: string, grounds: string) =>
    data<TrustAppeal>(await apiClient.post('/trust/self/appeals', { caseId, grounds }, { headers: commandHeaders(`appeal:${caseId}`) })),
  listReviews: async () => data<TrustReviewCase[]>(await apiClient.get('/admin/trust/reviews')),
  assignReview: async (reviewId: string, reviewerId: string) => data<TrustReviewCase>(await apiClient.post(`/admin/trust/reviews/${reviewId}/assign`, { reviewerId }, { headers: commandHeaders(`assign:${reviewId}`) })),
  decideReview: async (reviewId: string, outcome: TrustDecision['outcome'], reasonCode: string, rationale: string) =>
    data<TrustDecision>(await apiClient.post(`/admin/trust/reviews/${reviewId}/decision`, { outcome, reasonCode, rationale }, { headers: commandHeaders(`review-decision:${reviewId}`) })),
  listAppeals: async () => data<TrustAppeal[]>(await apiClient.get('/admin/trust/appeals')),
  decideAppeal: async (appealId: string, outcome: 'upheld' | 'overturned', reasonCode: string, rationale: string) =>
    data<TrustAppeal>(await apiClient.post(`/admin/trust/appeals/${appealId}/decision`, { outcome, reasonCode, rationale }, { headers: commandHeaders(`appeal-decision:${appealId}`) }))
};
