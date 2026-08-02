import fc from 'fast-check';
import { decideProposal } from '../domains/groups/proposalRules.js';

describe('group proposal rules', () => {
  it('uses strict approval-over-rejection for ordinary proposals', () => {
    expect(decideProposal({
      eligibleCount: 4,
      quorumBps: 5000,
      approvalBps: 5001,
      approvalRule: 'majority_non_abstaining',
      approvals: 1,
      rejections: 1,
      abstentions: 0,
    })).toBe('rejected');
    expect(decideProposal({
      eligibleCount: 4,
      quorumBps: 5000,
      approvalBps: 5001,
      approvalRule: 'majority_non_abstaining',
      approvals: 2,
      rejections: 0,
      abstentions: 0,
    })).toBe('approved');
  });

  it('requires integer-ceiling eligible-voter thresholds for special proposals', () => {
    expect(decideProposal({
      eligibleCount: 3,
      quorumBps: 6667,
      approvalBps: 6667,
      approvalRule: 'eligible_threshold',
      approvals: 2,
      rejections: 1,
      abstentions: 0,
    })).toBe('rejected');
    expect(decideProposal({
      eligibleCount: 3,
      quorumBps: 6667,
      approvalBps: 6667,
      approvalRule: 'eligible_threshold',
      approvals: 3,
      rejections: 0,
      abstentions: 0,
    })).toBe('approved');
  });

  it('never approves when quorum is absent', () => {
    fc.assert(fc.property(
      fc.integer({ min: 1, max: 1_000 }),
      fc.integer({ min: 1, max: 10_000 }),
      (eligibleCount, quorumBps) => {
        expect(decideProposal({
          eligibleCount,
          quorumBps,
          approvalBps: 5001,
          approvalRule: 'majority_non_abstaining',
          approvals: 0,
          rejections: 0,
          abstentions: 0,
        })).toBe('expired');
      },
    ));
  });

  it('rejects impossible tallies', () => {
    expect(() => decideProposal({
      eligibleCount: 1,
      quorumBps: 5000,
      approvalBps: 5001,
      approvalRule: 'majority_non_abstaining',
      approvals: 1,
      rejections: 1,
      abstentions: 0,
    })).toThrow('GROUP_VOTE_TALLY_INVALID');
  });
});
