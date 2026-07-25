import {
  AppealEligibility,
  ReviewerEligibility,
  TrustAppealState,
  TrustReviewState,
} from './trustTypes.js';

export class TrustDomainError extends Error {
  constructor(readonly code: string, readonly status: number, message = code) {
    super(message);
  }
}

const reviewTransitions: Record<TrustReviewState, readonly TrustReviewState[]> = {
  open: ['assigned'],
  assigned: ['decided'],
  decided: ['appealed', 'closed'],
  appealed: ['closed'],
  closed: [],
};

const appealTransitions: Record<TrustAppealState, readonly TrustAppealState[]> = {
  filed: ['assigned', 'upheld', 'modified', 'overturned', 'dismissed'],
  assigned: ['upheld', 'modified', 'overturned', 'dismissed'],
  upheld: [],
  modified: [],
  overturned: [],
  dismissed: [],
};

export const assertReviewTransition = (from: TrustReviewState, to: TrustReviewState): void => {
  if (!reviewTransitions[from].includes(to)) throw new TrustDomainError('INVALID_REVIEW_TRANSITION', 409);
};

export const assertAppealTransition = (from: TrustAppealState, to: TrustAppealState): void => {
  if (!appealTransitions[from].includes(to)) throw new TrustDomainError('INVALID_APPEAL_TRANSITION', 409);
};

export const assertReviewerEligible = (input: ReviewerEligibility): void => {
  if (input.subjectType === 'user' && input.reviewerId === input.subjectId) {
    throw new TrustDomainError('REVIEWER_IS_SUBJECT', 409);
  }
  if (input.originalReviewerId && input.reviewerId === input.originalReviewerId) {
    throw new TrustDomainError('APPEAL_REVIEWER_CONFLICT', 409);
  }
  if (input.conflictedReviewerIds?.includes(input.reviewerId)) {
    throw new TrustDomainError('DECLARED_REVIEWER_CONFLICT', 409);
  }
};

export const assertAppealEligible = (input: AppealEligibility): void => {
  if (input.decisionOutcome === 'no_action') {
    throw new TrustDomainError('DECISION_NOT_APPEALABLE', 409);
  }
  if (input.activeAppeal) throw new TrustDomainError('ACTIVE_APPEAL_EXISTS', 409);
  if (!input.appealUntil || new Date(input.appealUntil).getTime() <= input.now.getTime()) {
    throw new TrustDomainError('APPEAL_WINDOW_CLOSED', 409);
  }
};

const codePattern = /^[A-Z][A-Z0-9_]{2,63}$/;
export const boundedCode = (value: string, field: string): string => {
  const normalized = value.trim().toUpperCase();
  if (!codePattern.test(normalized)) throw new TrustDomainError(`INVALID_${field.toUpperCase()}`, 400);
  return normalized;
};

export const boundedText = (value: string | undefined, field: string, min: number, max: number): string | undefined => {
  const normalized = value?.trim();
  if (normalized === undefined || normalized.length < min || normalized.length > max) {
    throw new TrustDomainError(`INVALID_${field.toUpperCase()}`, 400);
  }
  return normalized;
};

export const boundedIdempotencyKey = (value: string): string => {
  const normalized = value.trim();
  if (normalized.length < 8 || normalized.length > 160) throw new TrustDomainError('INVALID_IDEMPOTENCY_KEY', 400);
  return normalized;
};

export const boundedQueueLimit = (value = 50): number => {
  if (!Number.isInteger(value) || value < 1 || value > 200) throw new TrustDomainError('INVALID_QUEUE_LIMIT', 400);
  return value;
};
