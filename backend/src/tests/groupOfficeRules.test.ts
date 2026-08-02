import fc from 'fast-check';
import {
  normalizeOfficeProposalPayload,
  validateDelegationWindow,
} from '../domains/groups/officeRules.js';

describe('group office lifecycle rules', () => {
  const memberId = '00000000-0000-4000-8000-000000000701';

  it('normalizes appointment payloads to the database contract', () => {
    expect(normalizeOfficeProposalPayload('office_appointment', {
      officeKey: 'treasurer', memberId, termEndsAt: '2027-01-01T00:00:00Z',
    })).toEqual({
      office_key: 'treasurer', member_id: memberId,
      term_ends_at: '2027-01-01T00:00:00.000Z',
    });
  });

  it('requires an immutable target and reason for removals', () => {
    expect(() => normalizeOfficeProposalPayload('office_removal', {
      assignmentId: memberId, reasonCode: 'not-uppercase',
    })).toThrow('GROUP_OFFICE_PROPOSAL_PAYLOAD_INVALID');
  });

  it('leaves unrelated proposal payloads intact', () => {
    expect(normalizeOfficeProposalPayload('ordinary', { project: 'dryer' }))
      .toEqual({ project: 'dryer' });
  });

  it('accepts only positive bounded delegation windows', () => {
    const start = new Date('2026-08-03T00:00:00Z');
    fc.assert(fc.property(fc.integer({ min: 1, max: 30 }), (days) => {
      const end = new Date(start.getTime() + days * 86_400_000);
      expect(validateDelegationWindow(start, end, 30)).toEqual({
        startsAt: start.toISOString(), endsAt: end.toISOString(),
      });
    }));
  });

  it('rejects zero, negative, and over-limit delegation windows', () => {
    const start = new Date('2026-08-03T00:00:00Z');
    fc.assert(fc.property(
      fc.oneof(fc.integer({ max: 0 }), fc.integer({ min: 31, max: 1000 })),
      (days) => {
        const end = new Date(start.getTime() + days * 86_400_000);
        expect(() => validateDelegationWindow(start, end, 30))
          .toThrow('GROUP_OFFICE_DELEGATION_WINDOW_INVALID');
      },
    ));
  });
});
