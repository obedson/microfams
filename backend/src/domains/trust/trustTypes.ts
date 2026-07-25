export type TrustSubjectType = 'user' | 'membership' | 'organization' | 'transaction' | 'content' | 'other';
export type TrustPriority = 'low' | 'normal' | 'high' | 'urgent';
export type TrustReviewState = 'open' | 'assigned' | 'decided' | 'appealed' | 'closed';
export type TrustReviewOutcome = 'no_action' | 'warning' | 'suspend_membership' | 'suspend_organization' | 'suspend_user' | 'refer';
export type TrustAppealState = 'filed' | 'assigned' | 'upheld' | 'modified' | 'overturned' | 'dismissed';
export type TrustAppealOutcome = 'upheld' | 'overturned' | 'modified' | 'dismissed';
export type TrustEnvironment = 'development' | 'test' | 'staging' | 'production';

export interface TrustActorContext {
  actorId: string;
  organizationId?: string;
  platformAdministrator?: boolean;
  environment?: TrustEnvironment;
}

export interface TrustFeatureContext extends TrustActorContext {
  capability: 'review' | 'appeal' | 'suspension' | 'retention';
}

/** Flags stop new exposure only; completion and remediation commands remain available. */
export interface TrustFeatureGate {
  assertNewOperationEnabled(context: TrustFeatureContext): Promise<void>;
}

export interface TrustReviewCase {
  id: string;
  organizationId: string | null;
  subjectType: TrustSubjectType;
  subjectId: string;
  state: TrustReviewState;
  assignedReviewerId: string | null;
  priority: TrustPriority;
}

export interface TrustDecision {
  id: string;
  caseId: string;
  reviewerId: string;
  outcome: TrustReviewOutcome;
  reasonCode: string;
  decidedAt: string;
}

export interface TrustAppeal {
  id: string;
  caseId: string;
  appellantId: string;
  state: TrustAppealState;
  assignedReviewerId: string | null;
  filedAt: string;
  decidedAt: string | null;
}

export interface OpenTrustReviewInput {
  organizationId?: string;
  subjectType: TrustSubjectType;
  subjectId: string;
  reasonCode: string;
  priority?: TrustPriority;
  idempotencyKey: string;
}

export interface AssignTrustReviewInput { caseId: string; reviewerId: string; idempotencyKey: string; }
export interface DeclareReviewerConflictInput {
  caseId: string;
  conflictType: string;
  note?: string;
  idempotencyKey: string;
}
export interface DecideTrustReviewInput {
  caseId: string;
  outcome: TrustReviewOutcome;
  reasonCode: string;
  rationale: string;
  idempotencyKey: string;
}
export interface FileTrustAppealInput { caseId: string; grounds: string; idempotencyKey: string; }
export interface DecideTrustAppealInput {
  appealId: string;
  outcome: TrustAppealOutcome;
  reasonCode: string;
  rationale: string;
  idempotencyKey: string;
}
export interface SuspendOrganizationInput { organizationId: string; caseId: string; reasonCode: string; idempotencyKey: string; }
export interface ResumeOrganizationInput { organizationId: string; reasonCode: string; idempotencyKey: string; }
export interface SuspendMembershipInput { membershipId: string; caseId: string; reasonCode: string; idempotencyKey: string; }
export interface ResumeMembershipInput { membershipId: string; reasonCode: string; idempotencyKey: string; }
export interface RetentionDryRunInput { organizationId?: string; policyId: string; idempotencyKey: string; }

export interface TrustQueueFilter { organizationId?: string; state?: TrustReviewState; limit?: number; }
export interface TrustAppealQueueFilter { organizationId?: string; state?: TrustAppealState; limit?: number; }

export interface TrustSubjectStatus {
  subjectType: TrustSubjectType;
  subjectId: string;
  activeCase: TrustReviewCase | null;
  activeAppeal: TrustAppeal | null;
  suspended: boolean;
}

export interface AppealEligibility {
  decisionOutcome: TrustReviewOutcome;
  appealUntil: string | null;
  now: Date;
  activeAppeal: boolean;
}

export interface ReviewerEligibility {
  reviewerId: string;
  subjectType: TrustSubjectType;
  subjectId: string;
  originalReviewerId?: string | null;
  conflictedReviewerIds?: readonly string[];
}

export interface TrustRepository {
  getSubjectStatus(organizationId: string | undefined, subjectType: TrustSubjectType, subjectId: string): Promise<TrustSubjectStatus>;
  listDecisions(organizationId: string | undefined, subjectType: TrustSubjectType, subjectId: string): Promise<TrustDecision[]>;
  listReviewQueue(filter?: TrustQueueFilter): Promise<TrustReviewCase[]>;
  listAppealQueue(filter?: TrustAppealQueueFilter): Promise<TrustAppeal[]>;
  openReview(actorId: string, input: OpenTrustReviewInput, requestHash: string): Promise<unknown>;
  assignReview(actorId: string, input: AssignTrustReviewInput, requestHash: string): Promise<unknown>;
  declareReviewerConflict(actorId: string, input: DeclareReviewerConflictInput, requestHash: string): Promise<unknown>;
  decideReview(actorId: string, input: DecideTrustReviewInput, requestHash: string): Promise<unknown>;
  fileAppeal(actorId: string, input: FileTrustAppealInput, requestHash: string): Promise<unknown>;
  decideAppeal(actorId: string, input: DecideTrustAppealInput, requestHash: string): Promise<unknown>;
  suspendOrganization(actorId: string, input: SuspendOrganizationInput, requestHash: string): Promise<unknown>;
  resumeOrganization(actorId: string, input: ResumeOrganizationInput, requestHash: string): Promise<unknown>;
  suspendMembership(actorId: string, input: SuspendMembershipInput, requestHash: string): Promise<unknown>;
  resumeMembership(actorId: string, input: ResumeMembershipInput, requestHash: string): Promise<unknown>;
  createRetentionDryRun(actorId: string, input: RetentionDryRunInput, requestHash: string): Promise<unknown>;
}
