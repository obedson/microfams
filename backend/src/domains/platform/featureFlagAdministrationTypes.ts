import {
  FeatureFlagContext,
  FeatureFlagEnvironment,
  FeatureFlagScope,
} from '../../types/featureFlags.js';

export type FeatureFlagOverrideStatus = 'pending' | 'approved' | 'rejected' | 'revoked';
export type FeatureFlagOverrideDecision = 'approve' | 'reject';

export interface FeatureFlagOverrideRecord {
  id: string;
  featureKey: string;
  scopeType: FeatureFlagScope;
  scopeId: string | null;
  environment: FeatureFlagEnvironment | 'all';
  enabled: boolean;
  config: Record<string, unknown>;
  reason: string;
  status: FeatureFlagOverrideStatus;
  effectiveFrom: string;
  effectiveUntil: string | null;
  createdBy: string;
  approvedBy: string | null;
  decidedBy: string | null;
  createdAt: string;
  decisionAt: string | null;
  decisionReason: string | null;
}

export interface CreateFeatureFlagOverride {
  featureKey: string;
  scopeType: FeatureFlagScope;
  scopeId: string | null;
  environment: FeatureFlagEnvironment | 'all';
  enabled: boolean;
  config: Record<string, unknown>;
  reason: string;
  status: 'pending' | 'approved';
  effectiveFrom: string;
  effectiveUntil: string | null;
  createdBy: string;
  approvedBy: string | null;
  decidedBy: string | null;
}

export interface FeatureFlagAuditRecord {
  id: string;
  featureKey: string;
  action: 'INSERT' | 'UPDATE' | 'DELETE';
  actorId: string | null;
  beforeValue: Record<string, unknown> | null;
  afterValue: Record<string, unknown> | null;
  occurredAt: string;
}

export interface FeatureFlagAdministrationRepository {
  createOverride(input: CreateFeatureFlagOverride): Promise<FeatureFlagOverrideRecord>;
  getOverride(id: string): Promise<FeatureFlagOverrideRecord | null>;
  decideOverride(
    id: string,
    actorId: string,
    decision: FeatureFlagOverrideDecision,
    reason: string,
  ): Promise<FeatureFlagOverrideRecord>;
  setEmergencyStop(
    featureKey: string,
    actorId: string,
    disabled: boolean,
    reason: string,
    incidentReference: string,
  ): Promise<void>;
  listAudit(featureKey?: string, limit?: number): Promise<FeatureFlagAuditRecord[]>;
}

export type FeatureFlagDecisionContext = FeatureFlagContext;
