import fc from 'fast-check';
import {
  normalizeCommitteePermissions,
  normalizeSpendingCeiling,
  normalizeCommitteeProposalPayload,
  assertMeetingNotice,
  isQuorumMet,
  GROUP_COMMITTEE_DELEGABLE_PERMISSIONS,
} from '../domains/groups/committeeRules.js';

describe('group committee and meeting rules', () => {
  describe('normalizeCommitteePermissions', () => {
    it('returns empty array for null or undefined', () => {
      expect(normalizeCommitteePermissions(null)).toEqual([]);
      expect(normalizeCommitteePermissions(undefined)).toEqual([]);
    });

    it('accepts valid delegable permissions', () => {
      const permissions = normalizeCommitteePermissions([
        'groups.committee.recommend',
        'groups.meeting.schedule',
      ]);
      expect(permissions).toHaveLength(2);
      expect(permissions).toContain('groups.committee.recommend');
      expect(permissions).toContain('groups.meeting.schedule');
    });

    it('deduplicates repeated permissions', () => {
      const permissions = normalizeCommitteePermissions([
        'groups.committee.recommend',
        'groups.committee.recommend',
        'groups.meeting.schedule',
      ]);
      expect(permissions).toHaveLength(2);
    });

    it('rejects non-delegable permissions', () => {
      expect(() => normalizeCommitteePermissions(['groups.governance.manage']))
        .toThrow('GROUP_COMMITTEE_PERMISSION_NOT_DELEGABLE');
      expect(() => normalizeCommitteePermissions(['arbitrary.permission']))
        .toThrow('GROUP_COMMITTEE_PERMISSION_NOT_DELEGABLE');
    });

    it('rejects non-array input', () => {
      expect(() => normalizeCommitteePermissions('not-an-array'))
        .toThrow('GROUP_COMMITTEE_PERMISSIONS_INVALID');
    });
  });

  describe('normalizeSpendingCeiling', () => {
    it('returns null for both when both are null', () => {
      const result = normalizeSpendingCeiling(null, null);
      expect(result).toEqual({ minorUnits: null, currency: null });
    });

    it('accepts valid ceiling with amount and currency', () => {
      const result = normalizeSpendingCeiling(500000, 'NGN');
      expect(result).toEqual({ minorUnits: 500000, currency: 'NGN' });
    });

    it('rejects amount without currency', () => {
      expect(() => normalizeSpendingCeiling(500000, null))
        .toThrow('GROUP_COMMITTEE_CEILING_INVALID');
    });

    it('rejects currency without amount', () => {
      expect(() => normalizeSpendingCeiling(null, 'NGN'))
        .toThrow('GROUP_COMMITTEE_CEILING_INVALID');
    });

    it('rejects negative amounts', () => {
      expect(() => normalizeSpendingCeiling(-100, 'NGN'))
        .toThrow('GROUP_COMMITTEE_CEILING_INVALID');
    });

    it('rejects invalid currency codes', () => {
      expect(() => normalizeSpendingCeiling(500000, 'ng'))
        .toThrow('GROUP_COMMITTEE_CEILING_INVALID');
      expect(() => normalizeSpendingCeiling(500000, 'NGNN'))
        .toThrow('GROUP_COMMITTEE_CEILING_INVALID');
    });
  });

  describe('assertMeetingNotice', () => {
    const now = new Date('2026-08-06T10:00:00Z');

    it('accepts general meeting with sufficient notice', () => {
      const result = assertMeetingNotice({
        meetingType: 'general',
        scheduledAt: new Date('2026-08-08T14:00:00Z'),
        requiredNoticeHours: 48,
        now,
      });
      expect(result).toBe('2026-08-08T14:00:00.000Z');
    });

    it('rejects general meeting with insufficient notice', () => {
      expect(() => assertMeetingNotice({
        meetingType: 'general',
        scheduledAt: new Date('2026-08-06T18:00:00Z'),
        requiredNoticeHours: 48,
        now,
      })).toThrow('GROUP_MEETING_NOTICE_TOO_SHORT');
    });

    it('allows emergency meeting with short notice when reason is supplied', () => {
      const result = assertMeetingNotice({
        meetingType: 'emergency',
        scheduledAt: new Date('2026-08-06T12:00:00Z'),
        requiredNoticeHours: 48,
        emergencyReason: 'Urgent security matter requiring immediate attention',
        now,
      });
      expect(result).toBe('2026-08-06T12:00:00.000Z');
    });

    it('requires emergency reason for emergency meetings', () => {
      expect(() => assertMeetingNotice({
        meetingType: 'emergency',
        scheduledAt: new Date('2026-08-08T14:00:00Z'),
        requiredNoticeHours: 48,
        now,
      })).toThrow('GROUP_MEETING_EMERGENCY_REASON_REQUIRED');
    });

    it('forbids emergency reason for non-emergency meetings', () => {
      expect(() => assertMeetingNotice({
        meetingType: 'general',
        scheduledAt: new Date('2026-08-08T14:00:00Z'),
        requiredNoticeHours: 48,
        emergencyReason: 'Not actually emergency',
        now,
      })).toThrow('GROUP_MEETING_EMERGENCY_REASON_REQUIRED');
    });

    it('rejects past scheduled times', () => {
      expect(() => assertMeetingNotice({
        meetingType: 'general',
        scheduledAt: new Date('2026-08-05T10:00:00Z'),
        requiredNoticeHours: 48,
        now,
      })).toThrow('GROUP_MEETING_SCHEDULE_INVALID');
    });
  });

  describe('normalizeCommitteeProposalPayload', () => {
    const committeeId = '00000000-0000-4000-8000-000000000801';

    it('normalizes a create mandate to the database contract', () => {
      expect(normalizeCommitteeProposalPayload('committee_mandate', {
        action: 'create',
        committeeKey: 'finance',
        displayName: 'Finance Committee',
        mandate: 'Review treasury activity.',
        delegatedPermissions: ['groups.committee.recommend'],
        spendingCeilingMinorUnits: 500000,
        spendingCeilingCurrency: 'NGN',
        termEndsAt: '2027-01-01T00:00:00Z',
      })).toEqual({
        action: 'create',
        committee_key: 'finance',
        display_name: 'Finance Committee',
        mandate: 'Review treasury activity.',
        delegated_permissions: ['groups.committee.recommend'],
        spending_ceiling_minor_units: '500000',
        spending_ceiling_currency: 'NGN',
        reporting_duties: null,
        term_ends_at: '2027-01-01T00:00:00.000Z',
      });
    });

    it('refuses a mandate carrying a non-delegable permission', () => {
      expect(() => normalizeCommitteeProposalPayload('committee_mandate', {
        action: 'create',
        committeeKey: 'seizure',
        displayName: 'Seizure Committee',
        mandate: 'Attempt to seize governance rights.',
        delegatedPermissions: ['groups.governance.manage'],
      })).toThrow('GROUP_COMMITTEE_PERMISSION_NOT_DELEGABLE');
    });

    it('requires an immutable target and reason for dissolution', () => {
      expect(normalizeCommitteeProposalPayload('committee_mandate', {
        action: 'dissolve', committeeId, reasonCode: 'MANDATE_COMPLETE',
      })).toEqual({
        action: 'dissolve', committee_id: committeeId, reason_code: 'MANDATE_COMPLETE',
      });
      expect(() => normalizeCommitteeProposalPayload('committee_mandate', {
        action: 'dissolve', committeeId, reasonCode: 'not-uppercase',
      })).toThrow('GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID');
    });

    it('rejects an unknown mandate action', () => {
      expect(() => normalizeCommitteeProposalPayload('committee_mandate', {
        action: 'seize', committeeId,
      })).toThrow('GROUP_COMMITTEE_PROPOSAL_PAYLOAD_INVALID');
    });

    it('leaves unrelated proposal payloads intact', () => {
      expect(normalizeCommitteeProposalPayload('ordinary', { project: 'dryer' }))
        .toEqual({ project: 'dryer' });
    });
  });

  describe('isQuorumMet', () => {
    it('confirms quorum for simple majority', () => {
      expect(isQuorumMet({
        presentCount: 6,
        eligibleCount: 10,
        numerator: 1,
        denominator: 2,
      })).toBe(true);
      expect(isQuorumMet({
        presentCount: 5,
        eligibleCount: 10,
        numerator: 1,
        denominator: 2,
      })).toBe(true);
    });

    it('rejects when quorum not met', () => {
      expect(isQuorumMet({
        presentCount: 4,
        eligibleCount: 10,
        numerator: 1,
        denominator: 2,
      })).toBe(false);
    });

    it('confirms quorum for two-thirds requirement', () => {
      expect(isQuorumMet({
        presentCount: 7,
        eligibleCount: 10,
        numerator: 2,
        denominator: 3,
      })).toBe(true);
      expect(isQuorumMet({
        presentCount: 6,
        eligibleCount: 10,
        numerator: 2,
        denominator: 3,
      })).toBe(false);
    });

    it('uses integer comparison avoiding floating point', () => {
      fc.assert(fc.property(
        fc.integer({ min: 0, max: 100 }),
        fc.integer({ min: 1, max: 100 }),
        fc.integer({ min: 1, max: 10 }),
        fc.integer({ min: 1, max: 10 }),
        (present, eligible, num, denom) => {
          if (present > eligible || num > denom) return true;
          const result = isQuorumMet({
            presentCount: present,
            eligibleCount: eligible,
            numerator: num,
            denominator: denom,
          });
          const expected = present * denom >= eligible * num;
          expect(result).toBe(expected);
        },
      ));
    });

    it('rejects invalid counts', () => {
      expect(() => isQuorumMet({
        presentCount: -1,
        eligibleCount: 10,
        numerator: 1,
        denominator: 2,
      })).toThrow('GROUP_MEETING_QUORUM_INVALID');
      expect(() => isQuorumMet({
        presentCount: 11,
        eligibleCount: 10,
        numerator: 1,
        denominator: 2,
      })).toThrow('GROUP_MEETING_QUORUM_INVALID');
    });

    it('rejects invalid ratio', () => {
      expect(() => isQuorumMet({
        presentCount: 5,
        eligibleCount: 10,
        numerator: 3,
        denominator: 2,
      })).toThrow('GROUP_MEETING_QUORUM_INVALID');
    });
  });
});
