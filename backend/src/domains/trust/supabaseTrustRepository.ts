import { supabase } from '../../utils/supabase.js';
import {
  AssignTrustReviewInput,
  DeclareReviewerConflictInput,
  DecideTrustAppealInput,
  DecideTrustReviewInput,
  FileTrustAppealInput,
  OpenTrustReviewInput,
  ResumeMembershipInput,
  ResumeOrganizationInput,
  RetentionDryRunInput,
  SuspendMembershipInput,
  SuspendOrganizationInput,
  TrustAppeal,
  TrustAppealQueueFilter,
  TrustDecision,
  TrustQueueFilter,
  TrustRepository,
  TrustReviewCase,
  TrustSubjectStatus,
  TrustSubjectType,
} from './trustTypes.js';

const rpc = async (name: string, parameters: Record<string, unknown>): Promise<unknown> => {
  const { data, error } = await supabase.rpc(name, parameters);
  if (error || data === null) throw error ?? new Error('Trust command failed');
  return data;
};

const mapCase = (row: any): TrustReviewCase => ({
  id: row.id,
  organizationId: row.organization_id ?? null,
  subjectType: row.subject_type,
  subjectId: row.subject_id,
  state: row.status,
  assignedReviewerId: row.assigned_reviewer_id ?? null,
  priority: row.priority,
});

const mapAppeal = (row: any): TrustAppeal => ({
  id: row.id,
  caseId: row.case_id,
  appellantId: row.appellant_id,
  state: row.status,
  assignedReviewerId: row.assigned_reviewer_id ?? null,
  filedAt: row.filed_at,
  decidedAt: row.decided_at ?? null,
});

export class SupabaseTrustRepository implements TrustRepository {
  async getSubjectStatus(
    organizationId: string | undefined,
    subjectType: TrustSubjectType,
    subjectId: string,
  ): Promise<TrustSubjectStatus> {
    let caseQuery = supabase
      .from('trust_review_cases')
      .select('*')
      .eq('subject_type', subjectType)
      .eq('subject_id', subjectId)
      .order('opened_at', { ascending: false })
      .limit(1);
    caseQuery = organizationId ? caseQuery.eq('organization_id', organizationId) : caseQuery.is('organization_id', null);
    const { data: cases, error: caseError } = await caseQuery;
    if (caseError) throw caseError;
    const activeCase = cases?.[0] ? mapCase(cases[0]) : null;

    let activeAppeal: TrustAppeal | null = null;
    if (activeCase) {
      const { data, error } = await supabase
        .from('trust_appeals')
        .select('*')
        .eq('case_id', activeCase.id)
        .in('status', ['filed', 'assigned'])
        .order('filed_at', { ascending: false })
        .limit(1);
      if (error) throw error;
      activeAppeal = data?.[0] ? mapAppeal(data[0]) : null;
    }

    let suspended = false;
    if (subjectType === 'organization') {
      const { data, error } = await supabase
        .from('organization_suspensions')
        .select('id')
        .eq('organization_id', subjectId)
        .eq('status', 'active')
        .limit(1);
      if (error) throw error;
      suspended = Boolean(data?.length);
    } else if (subjectType === 'membership') {
      const { data, error } = await supabase
        .from('organization_membership_suspensions')
        .select('id')
        .eq('membership_id', subjectId)
        .eq('status', 'active')
        .limit(1);
      if (error) throw error;
      suspended = Boolean(data?.length);
    }
    return { subjectType, subjectId, activeCase, activeAppeal, suspended };
  }

  async listDecisions(
    organizationId: string | undefined,
    subjectType: TrustSubjectType,
    subjectId: string,
  ): Promise<TrustDecision[]> {
    let cases = supabase
      .from('trust_review_cases')
      .select('id')
      .eq('subject_type', subjectType)
      .eq('subject_id', subjectId);
    cases = organizationId ? cases.eq('organization_id', organizationId) : cases.is('organization_id', null);
    const { data: caseRows, error: caseError } = await cases;
    if (caseError) throw caseError;
    const caseIds = (caseRows ?? []).map((row: any) => row.id);
    if (!caseIds.length) return [];
    const { data, error } = await supabase
      .from('trust_review_decisions')
      .select('*')
      .in('case_id', caseIds)
      .order('decided_at', { ascending: false });
    if (error) throw error;
    return (data ?? []).map((row: any) => ({
      id: row.id,
      caseId: row.case_id,
      reviewerId: row.reviewer_id,
      outcome: row.outcome,
      reasonCode: row.reason_code,
      decidedAt: row.decided_at,
    }));
  }

  async listReviewQueue(filter: TrustQueueFilter = {}): Promise<TrustReviewCase[]> {
    let query = supabase.from('trust_review_cases').select('*').order('opened_at').limit(filter.limit ?? 50);
    if (filter.organizationId) query = query.eq('organization_id', filter.organizationId);
    if (filter.state) query = query.eq('status', filter.state);
    const { data, error } = await query;
    if (error) throw error;
    return (data ?? []).map(mapCase);
  }

  async listAppealQueue(filter: TrustAppealQueueFilter = {}): Promise<TrustAppeal[]> {
    let query = supabase.from('trust_appeals').select('*').order('filed_at').limit(filter.limit ?? 50);
    if (filter.state) query = query.eq('status', filter.state);
    if (filter.organizationId) {
      const { data: cases, error: caseError } = await supabase
        .from('trust_review_cases')
        .select('id')
        .eq('organization_id', filter.organizationId);
      if (caseError) throw caseError;
      const ids = (cases ?? []).map((row: any) => row.id);
      if (!ids.length) return [];
      query = query.in('case_id', ids);
    }
    const { data, error } = await query;
    if (error) throw error;
    return (data ?? []).map(mapAppeal);
  }

  openReview(actorId: string, input: OpenTrustReviewInput, requestHash: string) {
    return rpc('open_trust_review_case', {
      p_actor: actorId, p_organization: input.organizationId ?? null,
      p_subject_type: input.subjectType, p_subject_id: input.subjectId,
      p_reason_code: input.reasonCode, p_priority: input.priority ?? 'normal',
      p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  assignReview(actorId: string, input: AssignTrustReviewInput, requestHash: string) {
    return rpc('assign_trust_review_case', {
      p_actor: actorId, p_case: input.caseId, p_reviewer: input.reviewerId,
      p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  declareReviewerConflict(actorId: string, input: DeclareReviewerConflictInput, requestHash: string) {
    return rpc('declare_trust_reviewer_conflict', {
      p_actor: actorId, p_case: input.caseId, p_conflict_type: input.conflictType,
      p_note: input.note ?? null, p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  decideReview(actorId: string, input: DecideTrustReviewInput, requestHash: string) {
    return rpc('decide_trust_review_case', {
      p_actor: actorId, p_case: input.caseId, p_outcome: input.outcome,
      p_reason_code: input.reasonCode, p_rationale: input.rationale,
      p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  fileAppeal(actorId: string, input: FileTrustAppealInput, requestHash: string) {
    return rpc('file_trust_appeal', {
      p_actor: actorId, p_case: input.caseId, p_grounds: input.grounds,
      p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  decideAppeal(actorId: string, input: DecideTrustAppealInput, requestHash: string) {
    return rpc('decide_trust_appeal', {
      p_actor: actorId, p_appeal: input.appealId, p_outcome: input.outcome,
      p_reason_code: input.reasonCode, p_rationale: input.rationale,
      p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  suspendOrganization(actorId: string, input: SuspendOrganizationInput, requestHash: string) {
    return rpc('suspend_trust_organization', {
      p_actor: actorId, p_organization: input.organizationId, p_case: input.caseId,
      p_reason_code: input.reasonCode, p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  resumeOrganization(actorId: string, input: ResumeOrganizationInput, requestHash: string) {
    return rpc('resume_trust_organization', {
      p_actor: actorId, p_organization: input.organizationId,
      p_reason_code: input.reasonCode,
      p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  suspendMembership(actorId: string, input: SuspendMembershipInput, requestHash: string) {
    return rpc('suspend_trust_membership', {
      p_actor: actorId, p_membership: input.membershipId, p_case: input.caseId,
      p_reason_code: input.reasonCode, p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  resumeMembership(actorId: string, input: ResumeMembershipInput, requestHash: string) {
    return rpc('resume_trust_membership', {
      p_actor: actorId, p_membership: input.membershipId,
      p_reason_code: input.reasonCode,
      p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }

  createRetentionDryRun(actorId: string, input: RetentionDryRunInput, requestHash: string) {
    return rpc('create_retention_dry_run', {
      p_actor: actorId, p_organization: input.organizationId ?? null, p_policy: input.policyId,
      p_idempotency_key: input.idempotencyKey, p_request_hash: requestHash,
    });
  }
}
