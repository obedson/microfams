import { apiClient } from '../api/client';

export interface SavingsProductRecord {
  product: { id: string; code: string; name: string; currency: string; state: string };
  version: {
    id: string; version: number; minimum_contribution_minor: number; maximum_contribution_minor: number;
    contribution_frequency: string; default_target_minor: number | null; lock_period_days: number;
    grace_period_days: number; early_withdrawal_rule: string; early_withdrawal_fee_minor: number;
    return_method: string; annual_rate_basis_points: number; day_count_convention: string;
    disclosure_version: string; disclosure_content_hash: string; eligibility: Record<string, unknown>;
  };
}

export interface SavingsEnrolmentRecord {
  enrolment: { id: string; state: string; currency: string; target_minor: number | null; accepted_disclosure_version: string };
  product: SavingsProductRecord['product']; version: SavingsProductRecord['version'];
}

const idempotencyKey = (scope: string) => `${scope}:${Date.now()}:${Math.random().toString(36).slice(2)}`;

export const savingsAPI = {
  listProducts: async () => (await apiClient.get<{ products: SavingsProductRecord[] }>('/savings/products')).data.products,
  listEnrolments: async () => (await apiClient.get<{ enrolments: SavingsEnrolmentRecord[] }>('/savings/enrolments')).data.enrolments,
  enrol: async (productId: string, input: { targetMinor?: number; disclosureVersion: string; disclosureContentHash: string }) =>
    (await apiClient.post<SavingsEnrolmentRecord>(`/savings/products/${productId}/enrolments`, input, {
      headers: { 'Idempotency-Key': idempotencyKey(`savings-enrol:${productId}`) },
    })).data,
};
