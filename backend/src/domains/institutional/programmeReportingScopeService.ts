import { createHash } from 'node:crypto';
import { supabase } from '../../utils/supabase.js';

export type ProgrammeReportingScopeStatus =
  | 'pending' | 'granted' | 'rejected' | 'revoked' | 'expired';

export interface ProgrammeReportingScope {
  id: string;
  programmeOrganizationId: string;
  programmeId: string;
  participatingOrganizationId: string;
  purpose: string;
  permittedMetrics: string[];
  disclosureVersion: string;
  status: ProgrammeReportingScopeStatus;
  requestedBy: string;
  requestedAt: string;
  decidedBy: string | null;
  decidedAt: string | null;
  decisionReason: string | null;
  effectiveAt: string | null;
  expiresAt: string;
  revokedBy: string | null;
  revokedAt: string | null;
  revocationReason: string | null;
}

interface ReportingScopeRow {
  id: string;
  programme_organization_id: string;
  programme_id: string;
  participating_organization_id: string;
  purpose: string;
  permitted_metrics: string[];
  disclosure_version: string;
  status: ProgrammeReportingScopeStatus;
  requested_by: string;
  requested_at: string;
  decided_by: string | null;
  decided_at: string | null;
  decision_reason: string | null;
  effective_at: string | null;
  expires_at: string;
  revoked_by: string | null;
  revoked_at: string | null;
  revocation_reason: string | null;
}

const metricPattern = /^aggregate\.[a-z][a-z0-9_]*$/;
const disclosurePattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const evidenceHash = (evidence: string) =>
  createHash('sha256').update(evidence, 'utf8').digest('hex');
const hasLength = (value: string | undefined, minimum: number, maximum: number) => {
  const length = value?.trim().length ?? 0;
  return length >= minimum && length <= maximum;
};

const mapScope = (row: ReportingScopeRow): ProgrammeReportingScope => ({
  id: row.id,
  programmeOrganizationId: row.programme_organization_id,
  programmeId: row.programme_id,
  participatingOrganizationId: row.participating_organization_id,
  purpose: row.purpose,
  permittedMetrics: row.permitted_metrics,
  disclosureVersion: row.disclosure_version,
  status: row.status,
  requestedBy: row.requested_by,
  requestedAt: row.requested_at,
  decidedBy: row.decided_by,
  decidedAt: row.decided_at,
  decisionReason: row.decision_reason,
  effectiveAt: row.effective_at,
  expiresAt: row.expires_at,
  revokedBy: row.revoked_by,
  revokedAt: row.revoked_at,
  revocationReason: row.revocation_reason,
});

export class ProgrammeReportingScopeService {
  async list(organizationId: string): Promise<ProgrammeReportingScope[]> {
    const { data, error } = await supabase
      .from('institutional_programme_reporting_scopes')
      .select('*')
      .or(
        `programme_organization_id.eq.${organizationId},participating_organization_id.eq.${organizationId}`,
      )
      .order('created_at', { ascending: false });
    if (error) throw error;
    return (data as ReportingScopeRow[] | null ?? []).map(mapScope);
  }

  async request(input: {
    organizationId: string;
    actorId: string;
    programmeId: string;
    participatingOrganizationId: string;
    purpose: string;
    permittedMetrics: string[];
    disclosureVersion: string;
    requestEvidence: string;
    expiresAt: string;
  }): Promise<ProgrammeReportingScope> {
    const metrics = [...new Set(input.permittedMetrics)].sort();
    if (
      input.organizationId === input.participatingOrganizationId
      || !hasLength(input.purpose, 10, 1000)
      || !disclosurePattern.test(input.disclosureVersion)
      || !hasLength(input.requestEvidence, 10, 4000)
      || !Number.isFinite(Date.parse(input.expiresAt))
      || Date.parse(input.expiresAt) <= Date.now()
      || metrics.length < 1 || metrics.length > 32
      || metrics.some((metric) => !metricPattern.test(metric))
    ) {
      throw new Error('PROGRAMME_REPORTING_SCOPE_INVALID');
    }
    const { data, error } = await supabase.rpc(
      'request_programme_reporting_scope',
      {
        p_programme_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_programme_id: input.programmeId,
        p_participating_organization_id: input.participatingOrganizationId,
        p_purpose: input.purpose,
        p_permitted_metrics: metrics,
        p_disclosure_version: input.disclosureVersion,
        p_request_evidence_hash: evidenceHash(input.requestEvidence),
        p_expires_at: input.expiresAt,
      },
    );
    if (error) throw error;
    return mapScope(data as ReportingScopeRow);
  }

  async decide(input: {
    organizationId: string;
    actorId: string;
    scopeId: string;
    decision: 'granted' | 'rejected';
    reason: string;
    consentEvidence?: string;
    effectiveAt?: string;
  }): Promise<ProgrammeReportingScope> {
    if (
      !hasLength(input.reason, 3, 1000)
      || (input.decision === 'granted' && (
        !hasLength(input.consentEvidence, 10, 4000)
        || !input.effectiveAt
        || Date.parse(input.effectiveAt) <= Date.now()
      ))) {
      throw new Error('PROGRAMME_REPORTING_SCOPE_DECISION_INVALID');
    }
    const { data, error } = await supabase.rpc(
      'decide_programme_reporting_scope',
      {
        p_participating_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_scope_id: input.scopeId,
        p_decision: input.decision,
        p_reason: input.reason,
        p_consent_evidence_hash: input.consentEvidence
          ? evidenceHash(input.consentEvidence) : null,
        p_effective_at: input.effectiveAt ?? null,
      },
    );
    if (error) throw error;
    return mapScope(data as ReportingScopeRow);
  }

  async revoke(input: {
    organizationId: string;
    actorId: string;
    scopeId: string;
    reason: string;
  }): Promise<ProgrammeReportingScope> {
    if (!hasLength(input.reason, 3, 1000)) {
      throw new Error('PROGRAMME_REPORTING_SCOPE_REVOCATION_INVALID');
    }
    const { data, error } = await supabase.rpc(
      'revoke_programme_reporting_scope',
      {
        p_participating_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_scope_id: input.scopeId,
        p_reason: input.reason,
      },
    );
    if (error) throw error;
    return mapScope(data as ReportingScopeRow);
  }
}

export const programmeReportingScopeService =
  new ProgrammeReportingScopeService();
