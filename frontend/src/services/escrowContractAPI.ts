import { apiClient } from '../api/client';

export type EscrowContractCommand = {
  payerId: string;
  beneficiaryId: string;
  currency: string;
  amountMinor: number;
  purpose: string;
  milestones?: unknown[];
  releaseRules?: Record<string, unknown>;
  authorizedArbiters?: string[];
  disputeWindowEndsAt?: string;
  expiresAt?: string;
};

const key = (prefix: string) => `${prefix}-${Date.now()}`;

export const escrowContractAPI = {
  create: async (command: EscrowContractCommand) => (await apiClient.post('/escrow/contracts', command, { headers: { 'Idempotency-Key': key('escrow-create') } })).data,
  activate: async (contractId: string) => (await apiClient.post(`/escrow/contracts/${contractId}/activate`, {}, { headers: { 'Idempotency-Key': key('escrow-activate') } })).data,
};
