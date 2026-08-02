import fc from 'fast-check';
import {
  validateDisciplineSchedule,
  validateEvidenceRefs,
} from '../domains/groups/disciplineRules.js';

describe('group discipline rules', () => {
  const notice = new Date('2026-08-03T09:00:00Z');

  it('requires a real response period before proposal voting', () => {
    expect(() => validateDisciplineSchedule({
      noticeIssuedAt: notice,
      responseDueAt: '2026-08-04T08:59:59Z',
      proposalClosesAt: '2026-08-05T09:00:00Z',
      appealWindowDays: 30,
    })).toThrow('GROUP_DISCIPLINE_RESPONSE_WINDOW_INVALID');
  });

  it('accepts bounded response, voting, and appeal windows', () => {
    expect(validateDisciplineSchedule({
      noticeIssuedAt: notice,
      responseDueAt: '2026-08-04T09:00:00Z',
      proposalClosesAt: '2026-08-05T09:00:00Z',
      appealWindowDays: 30,
    })).toEqual(expect.objectContaining({ appealWindowDays: 30 }));
  });

  it('never accepts an appeal window outside one through ninety days', () => {
    fc.assert(fc.property(
      fc.oneof(fc.integer({ max: 0 }), fc.integer({ min: 91, max: 10_000 })),
      (appealWindowDays) => {
        expect(() => validateDisciplineSchedule({
          noticeIssuedAt: notice,
          responseDueAt: '2026-08-04T09:00:00Z',
          proposalClosesAt: '2026-08-05T09:00:00Z',
          appealWindowDays,
        })).toThrow('GROUP_DISCIPLINE_APPEAL_WINDOW_INVALID');
      },
    ));
  });

  it('requires at least one private evidence reference for a new case', () => {
    expect(() => validateEvidenceRefs([], true)).toThrow('GROUP_DISCIPLINE_EVIDENCE_INVALID');
    expect(validateEvidenceRefs([' evidence://case/1 '], true)).toEqual(['evidence://case/1']);
  });
});
