import {
  assertAppealEligible,
  assertAppealTransition,
  assertReviewerEligible,
  assertReviewTransition,
} from '../domains/trust/trustRules.js';

describe('trust domain rules', () => {
  it('allows only explicit review and appeal state transitions', () => {
    expect(() => assertReviewTransition('open', 'assigned')).not.toThrow();
    expect(() => assertReviewTransition('closed', 'assigned'))
      .toThrow(expect.objectContaining({ code: 'INVALID_REVIEW_TRANSITION' }));
    expect(() => assertAppealTransition('assigned', 'overturned')).not.toThrow();
    expect(() => assertAppealTransition('dismissed', 'filed'))
      .toThrow(expect.objectContaining({ code: 'INVALID_APPEAL_TRANSITION' }));
  });

  it('prevents self-review, declared conflicts, and the original reviewer deciding an appeal', () => {
    expect(() => assertReviewerEligible({
      reviewerId: 'user-1', subjectType: 'user', subjectId: 'user-1',
    })).toThrow(expect.objectContaining({ code: 'REVIEWER_IS_SUBJECT' }));
    expect(() => assertReviewerEligible({
      reviewerId: 'reviewer-1', subjectType: 'organization', subjectId: 'org-1',
      originalReviewerId: 'reviewer-1',
    })).toThrow(expect.objectContaining({ code: 'APPEAL_REVIEWER_CONFLICT' }));
    expect(() => assertReviewerEligible({
      reviewerId: 'reviewer-2', subjectType: 'membership', subjectId: 'member-1',
      conflictedReviewerIds: ['reviewer-2'],
    })).toThrow(expect.objectContaining({ code: 'DECLARED_REVIEWER_CONFLICT' }));
  });

  it('limits appeals to adverse decisions within the open window and one active appeal', () => {
    const now = new Date('2026-07-25T12:00:00Z');
    expect(() => assertAppealEligible({
      decisionOutcome: 'suspend_membership',
      appealUntil: '2026-07-26T12:00:00Z',
      now,
      activeAppeal: false,
    })).not.toThrow();
    expect(() => assertAppealEligible({
      decisionOutcome: 'no_action',
      appealUntil: '2026-07-26T12:00:00Z',
      now,
      activeAppeal: false,
    })).toThrow(expect.objectContaining({ code: 'DECISION_NOT_APPEALABLE' }));
    expect(() => assertAppealEligible({
      decisionOutcome: 'warning',
      appealUntil: '2026-07-26T12:00:00Z',
      now,
      activeAppeal: true,
    })).toThrow(expect.objectContaining({ code: 'ACTIVE_APPEAL_EXISTS' }));
  });
});
