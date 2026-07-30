import fc from 'fast-check';
import {
  canTransitionGroupLifecycle,
  evaluateGroupCreationEligibility,
  GroupLifecycleState,
} from '../domains/groups/groupPolicy.js';

describe('GT-01 group policy', () => {
  it('does not use existing group count as a creation eligibility condition', () => {
    expect(evaluateGroupCreationEligibility({
      role: 'member',
      ninVerified: true,
      platformSubscriber: true,
      paidInvitees: 2,
    })).toBe(true);
  });

  it('requires every approved non-admin eligibility condition', () => {
    fc.assert(fc.property(
      fc.boolean(),
      fc.boolean(),
      fc.integer({ min: 0, max: 10 }),
      (ninVerified, platformSubscriber, paidInvitees) => {
        expect(evaluateGroupCreationEligibility({
          role: 'member',
          ninVerified,
          platformSubscriber,
          paidInvitees,
        })).toBe(ninVerified && platformSubscriber && paidInvitees >= 2);
      },
    ));
  });

  it('allows only the additive lifecycle foundation transitions', () => {
    const states: GroupLifecycleState[] = [
      'draft', 'active', 'suspended', 'closing', 'closed',
    ];
    const allowed = new Set([
      'active:active', 'active:suspended', 'active:closing',
      'suspended:suspended', 'suspended:active', 'suspended:closing',
      'closing:closing', 'closing:closed',
      'draft:draft', 'closed:closed',
    ]);
    for (const from of states) {
      for (const to of states) {
        expect(canTransitionGroupLifecycle(from, to))
          .toBe(allowed.has(`${from}:${to}`));
      }
    }
  });
});
