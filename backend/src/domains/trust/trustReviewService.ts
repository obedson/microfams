import crypto from 'node:crypto';
import { SupabaseFeatureFlagRepository } from '../../repositories/featureFlagRepository.js';
import { FeatureFlagService } from '../../services/featureFlagService.js';
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
  SelectRetentionItemsInput,
  SuspendMembershipInput,
  SuspendOrganizationInput,
  TrustActorContext,
  TrustAppealQueueFilter,
  TrustFeatureContext,
  TrustFeatureGate,
  TrustQueueFilter,
  TrustRepository,
  TrustSubjectType,
} from './trustTypes.js';
import {
  boundedCode,
  boundedIdempotencyKey,
  boundedQueueLimit,
  boundedText,
  TrustDomainError,
} from './trustRules.js';
import { SupabaseTrustRepository } from './supabaseTrustRepository.js';

const hash = (value: object): string => crypto
  .createHash('sha256')
  .update(JSON.stringify(value))
  .digest('hex');

const identifier = (value: string, field: string): string => (
  boundedText(value, field, 1, 128) as string
);

const normalizeBase = <T extends { idempotencyKey: string }>(input: T): T => ({
  ...input,
  idempotencyKey: boundedIdempotencyKey(input.idempotencyKey),
});

const commandFailed = () => new TrustDomainError(
  'TRUST_COMMAND_FAILED',
  409,
  'The trust command could not be completed',
);

const featureKeys: Record<TrustFeatureContext['capability'], string> = {
  review: 'trust.review_cases',
  appeal: 'trust.appeals',
  suspension: 'trust.suspensions',
  retention: 'trust.retention.dry_run',
};

export class FeatureFlagTrustGate implements TrustFeatureGate {
  constructor(private readonly flags: FeatureFlagService) {}

  async assertNewOperationEnabled(context: TrustFeatureContext): Promise<void> {
    const decision = await this.flags.evaluate(featureKeys[context.capability], {
      environment: context.environment ?? (
        process.env.NODE_ENV === 'production' ? 'production' : 'development'
      ),
      tenantId: context.organizationId,
      actorId: context.actorId,
    });
    if (!decision.enabled) throw new TrustDomainError('TRUST_FEATURE_DISABLED', 403);
  }
}

export class TrustReviewService {
  constructor(
    private readonly repository: TrustRepository,
    private readonly featureGate: TrustFeatureGate,
  ) {}

  getSubjectStatus(context: TrustActorContext, subjectType: TrustSubjectType, subjectId: string) {
    return this.repository.getSubjectStatus(
      context.organizationId,
      subjectType,
      identifier(subjectId, 'subject_id'),
    );
  }

  listDecisions(context: TrustActorContext, subjectType: TrustSubjectType, subjectId: string) {
    return this.repository.listDecisions(
      context.organizationId,
      subjectType,
      identifier(subjectId, 'subject_id'),
    );
  }

  listReviewQueue(_context: TrustActorContext, filter: TrustQueueFilter = {}) {
    return this.repository.listReviewQueue({ ...filter, limit: boundedQueueLimit(filter.limit) });
  }

  listAppealQueue(_context: TrustActorContext, filter: TrustAppealQueueFilter = {}) {
    return this.repository.listAppealQueue({ ...filter, limit: boundedQueueLimit(filter.limit) });
  }

  async openReview(context: TrustActorContext, raw: OpenTrustReviewInput) {
    await this.featureGate.assertNewOperationEnabled({ ...context, capability: 'review' });
    const input = normalizeBase({
      ...raw,
      organizationId: raw.organizationId ? identifier(raw.organizationId, 'organization_id') : undefined,
      subjectId: identifier(raw.subjectId, 'subject_id'),
      reasonCode: boundedCode(raw.reasonCode, 'reason_code'),
      priority: raw.priority ?? 'normal',
    });
    return this.command(() => this.repository.openReview(context.actorId, input, hash(input)));
  }

  async assignReview(context: TrustActorContext, raw: AssignTrustReviewInput) {
    const input = normalizeBase({
      ...raw,
      caseId: identifier(raw.caseId, 'case_id'),
      reviewerId: identifier(raw.reviewerId, 'reviewer_id'),
    });
    return this.command(() => this.repository.assignReview(context.actorId, input, hash(input)));
  }

  async declareReviewerConflict(context: TrustActorContext, raw: DeclareReviewerConflictInput) {
    const input = normalizeBase({
      ...raw,
      caseId: identifier(raw.caseId, 'case_id'),
      conflictType: boundedCode(raw.conflictType, 'conflict_type'),
      note: raw.note === undefined ? undefined : boundedText(raw.note, 'conflict_note', 1, 1000),
    });
    return this.command(() => this.repository.declareReviewerConflict(context.actorId, input, hash(input)));
  }

  async decideReview(context: TrustActorContext, raw: DecideTrustReviewInput) {
    const input = normalizeBase({
      ...raw,
      caseId: identifier(raw.caseId, 'case_id'),
      reasonCode: boundedCode(raw.reasonCode, 'reason_code'),
      rationale: boundedText(raw.rationale, 'rationale', 10, 4000) as string,
    });
    return this.command(() => this.repository.decideReview(context.actorId, input, hash(input)));
  }

  async fileAppeal(context: TrustActorContext, raw: FileTrustAppealInput) {
    await this.featureGate.assertNewOperationEnabled({ ...context, capability: 'appeal' });
    const input = normalizeBase({
      ...raw,
      caseId: identifier(raw.caseId, 'case_id'),
      grounds: boundedText(raw.grounds, 'grounds', 10, 4000) as string,
    });
    return this.command(() => this.repository.fileAppeal(context.actorId, input, hash(input)));
  }

  async decideAppeal(context: TrustActorContext, raw: DecideTrustAppealInput) {
    const input = normalizeBase({
      ...raw,
      appealId: identifier(raw.appealId, 'appeal_id'),
      reasonCode: boundedCode(raw.reasonCode, 'reason_code'),
      rationale: boundedText(raw.rationale, 'rationale', 10, 4000) as string,
    });
    return this.command(() => this.repository.decideAppeal(context.actorId, input, hash(input)));
  }

  async suspendOrganization(context: TrustActorContext, raw: SuspendOrganizationInput) {
    await this.featureGate.assertNewOperationEnabled({ ...context, capability: 'suspension' });
    const input = this.organizationCommand(raw);
    return this.command(() => this.repository.suspendOrganization(context.actorId, input, hash(input)));
  }

  resumeOrganization(context: TrustActorContext, raw: ResumeOrganizationInput) {
    const input = this.organizationCommand(raw);
    return this.command(() => this.repository.resumeOrganization(context.actorId, input, hash(input)));
  }

  async suspendMembership(context: TrustActorContext, raw: SuspendMembershipInput) {
    await this.featureGate.assertNewOperationEnabled({ ...context, capability: 'suspension' });
    const input = this.membershipCommand(raw);
    return this.command(() => this.repository.suspendMembership(context.actorId, input, hash(input)));
  }

  resumeMembership(context: TrustActorContext, raw: ResumeMembershipInput) {
    const input = this.membershipCommand(raw);
    return this.command(() => this.repository.resumeMembership(context.actorId, input, hash(input)));
  }

  async createRetentionDryRun(context: TrustActorContext, raw: RetentionDryRunInput) {
    await this.featureGate.assertNewOperationEnabled({ ...context, capability: 'retention' });
    const input = normalizeBase({
      ...raw,
      organizationId: raw.organizationId ? identifier(raw.organizationId, 'organization_id') : undefined,
      policyId: identifier(raw.policyId, 'policy_id'),
    });
    return this.command(() => this.repository.createRetentionDryRun(context.actorId, input, hash(input)));
  }

  selectRetentionItems(context: TrustActorContext, raw: SelectRetentionItemsInput) {
    const input = normalizeBase({
      ...raw,
      runId: identifier(raw.runId, 'run_id'),
    });
    return this.command(() => this.repository.selectRetentionItems(context.actorId, input, hash(input)));
  }
  private organizationCommand<T extends SuspendOrganizationInput | ResumeOrganizationInput>(raw: T): T {
    return normalizeBase({
      ...raw,
      organizationId: identifier(raw.organizationId, 'organization_id'),
      ...('caseId' in raw ? { caseId: identifier(raw.caseId, 'case_id') } : {}),
      reasonCode: boundedCode(raw.reasonCode, 'reason_code'),
    });
  }

  private membershipCommand<T extends SuspendMembershipInput | ResumeMembershipInput>(raw: T): T {
    return normalizeBase({
      ...raw,
      membershipId: identifier(raw.membershipId, 'membership_id'),
      ...('caseId' in raw ? { caseId: identifier(raw.caseId, 'case_id') } : {}),
      reasonCode: boundedCode(raw.reasonCode, 'reason_code'),
    });
  }

  private async command<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await operation();
    } catch (error) {
      if (error instanceof TrustDomainError) throw error;
      throw commandFailed();
    }
  }
}

export const trustReviewService = new TrustReviewService(
  new SupabaseTrustRepository(),
  new FeatureFlagTrustGate(new FeatureFlagService(new SupabaseFeatureFlagRepository())),
);
