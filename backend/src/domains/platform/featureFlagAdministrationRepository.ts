import { supabase } from '../../utils/supabase.js';
import {
  CreateFeatureFlagOverride,
  FeatureFlagAdministrationRepository,
  FeatureFlagAuditRecord,
  FeatureFlagOverrideDecision,
  FeatureFlagOverrideRecord,
} from './featureFlagAdministrationTypes.js';

const mapOverride = (row: any): FeatureFlagOverrideRecord => ({
  id: row.id,
  featureKey: row.feature_key,
  scopeType: row.scope_type,
  scopeId: row.scope_id,
  environment: row.environment,
  enabled: row.enabled,
  config: row.config ?? {},
  reason: row.reason,
  status: row.status,
  effectiveFrom: row.effective_from,
  effectiveUntil: row.effective_until,
  createdBy: row.created_by,
  approvedBy: row.approved_by,
  decidedBy: row.decided_by,
  createdAt: row.created_at,
  decisionAt: row.decision_at,
  decisionReason: row.decision_reason,
});

const overrideSelection = [
  'id', 'feature_key', 'scope_type', 'scope_id', 'environment', 'enabled', 'config',
  'reason', 'status', 'effective_from', 'effective_until', 'created_by', 'approved_by',
  'decided_by', 'created_at', 'decision_at', 'decision_reason',
].join(', ');

export class SupabaseFeatureFlagAdministrationRepository implements FeatureFlagAdministrationRepository {
  async createOverride(input: CreateFeatureFlagOverride): Promise<FeatureFlagOverrideRecord> {
    const { data, error } = await supabase
      .from('feature_flag_overrides')
      .insert({
        feature_key: input.featureKey,
        scope_type: input.scopeType,
        scope_id: input.scopeId,
        environment: input.environment,
        enabled: input.enabled,
        config: input.config,
        reason: input.reason,
        status: input.status,
        effective_from: input.effectiveFrom,
        effective_until: input.effectiveUntil,
        created_by: input.createdBy,
        approved_by: input.approvedBy,
        decided_by: input.decidedBy,
        approved_at: input.status === 'approved' ? new Date().toISOString() : null,
        decision_at: input.status === 'approved' ? new Date().toISOString() : null,
        decision_reason: input.status === 'approved' ? input.reason : null,
      })
      .select(overrideSelection)
      .single();
    if (error || !data) throw error ?? new Error('Feature flag override creation failed');
    return mapOverride(data);
  }

  async getOverride(id: string): Promise<FeatureFlagOverrideRecord | null> {
    const { data, error } = await supabase
      .from('feature_flag_overrides')
      .select(overrideSelection)
      .eq('id', id)
      .maybeSingle();
    if (error) throw error;
    return data ? mapOverride(data) : null;
  }

  async decideOverride(
    id: string,
    actorId: string,
    decision: FeatureFlagOverrideDecision,
    reason: string,
  ): Promise<FeatureFlagOverrideRecord> {
    const approved = decision === 'approve';
    const now = new Date().toISOString();
    const { data, error } = await supabase
      .from('feature_flag_overrides')
      .update({
        status: approved ? 'approved' : 'rejected',
        approved_by: approved ? actorId : null,
        approved_at: approved ? now : null,
        decided_by: actorId,
        decision_at: now,
        decision_reason: reason,
      })
      .eq('id', id)
      .eq('status', 'pending')
      .neq('created_by', actorId)
      .select(overrideSelection)
      .maybeSingle();
    if (error || !data) throw error ?? new Error('Feature flag override decision failed');
    return mapOverride(data);
  }

  async setEmergencyStop(
    featureKey: string,
    actorId: string,
    disabled: boolean,
    reason: string,
    incidentReference: string,
  ): Promise<void> {
    const { data, error } = await supabase
      .from('feature_flags')
      .update({
        emergency_disabled: disabled,
        emergency_reason: reason,
        emergency_incident_reference: incidentReference,
        emergency_changed_at: new Date().toISOString(),
        emergency_changed_by: actorId,
      })
      .eq('key', featureKey)
      .select('key')
      .maybeSingle();
    if (error || !data) throw error ?? new Error('Feature flag emergency stop failed');
  }

  async listAudit(featureKey?: string, limit = 100): Promise<FeatureFlagAuditRecord[]> {
    let query = supabase
      .from('feature_flag_audit_log')
      .select('id, feature_key, action, actor_id, before_value, after_value, occurred_at')
      .order('occurred_at', { ascending: false })
      .limit(limit);
    if (featureKey) query = query.eq('feature_key', featureKey);
    const { data, error } = await query;
    if (error) throw error;
    return (data ?? []).map((row: any) => ({
      id: row.id,
      featureKey: row.feature_key,
      action: row.action,
      actorId: row.actor_id,
      beforeValue: row.before_value,
      afterValue: row.after_value,
      occurredAt: row.occurred_at,
    }));
  }
}
