import {
  missingRequiredOffices,
  normalizeConstitutionRules,
  thresholdCount,
} from '../domains/groups/constitutionRules.js';

describe('group constitution rules', () => {
  const rules = {
    minimumMembers: 3,
    ordinaryQuorumBps: 5000,
    ordinaryApprovalBps: 5001,
    specialQuorumBps: 6667,
    specialApprovalBps: 6667,
    voteChangeAllowed: false,
  };

  it('normalizes approved basis-point rules for persistence', () => {
    expect(normalizeConstitutionRules(rules)).toEqual({
      minimum_members: 3,
      ordinary_quorum_bps: 5000,
      ordinary_approval_bps: 5001,
      special_quorum_bps: 6667,
      special_approval_bps: 6667,
      vote_change_allowed: false,
    });
  });

  it('uses integer ceiling for constitution thresholds', () => {
    expect(thresholdCount(5, 6667)).toBe(4);
    expect(thresholdCount(3, 5000)).toBe(2);
    expect(thresholdCount(0, 5000)).toBe(0);
  });

  it('requires chair, secretary, and treasurer before activation', () => {
    expect(missingRequiredOffices(['chair'])).toEqual(['secretary', 'treasurer']);
    expect(missingRequiredOffices(['chair', 'secretary', 'treasurer'])).toEqual([]);
  });

  it('rejects invalid thresholds and member minimums', () => {
    expect(() => normalizeConstitutionRules({ ...rules, minimumMembers: 0 }))
      .toThrow('INVALID_MINIMUM_MEMBERS');
    expect(() => normalizeConstitutionRules({ ...rules, specialQuorumBps: 10001 }))
      .toThrow('INVALID_SPECIAL_QUORUM_BPS');
  });
});
