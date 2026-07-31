export interface ConstitutionRules {
  minimumMembers: number;
  ordinaryQuorumBps: number;
  ordinaryApprovalBps: number;
  specialQuorumBps: number;
  specialApprovalBps: number;
  voteChangeAllowed: boolean;
}

export const REQUIRED_INITIAL_OFFICES = ['chair', 'secretary', 'treasurer'] as const;

export class GroupConstitutionRuleError extends Error {
  constructor(public readonly code: string) {
    super(code);
  }
}

const assertBps = (value: number, field: string) => {
  if (!Number.isInteger(value) || value < 1 || value > 10_000) {
    throw new GroupConstitutionRuleError(`INVALID_${field.toUpperCase()}`);
  }
};

export const normalizeConstitutionRules = (
  input: ConstitutionRules,
): Record<string, number | boolean> => {
  if (!Number.isInteger(input.minimumMembers) || input.minimumMembers < 1) {
    throw new GroupConstitutionRuleError('INVALID_MINIMUM_MEMBERS');
  }
  assertBps(input.ordinaryQuorumBps, 'ordinary_quorum_bps');
  assertBps(input.ordinaryApprovalBps, 'ordinary_approval_bps');
  assertBps(input.specialQuorumBps, 'special_quorum_bps');
  assertBps(input.specialApprovalBps, 'special_approval_bps');
  if (typeof input.voteChangeAllowed !== 'boolean') {
    throw new GroupConstitutionRuleError('INVALID_VOTE_CHANGE_ALLOWED');
  }
  return {
    minimum_members: input.minimumMembers,
    ordinary_quorum_bps: input.ordinaryQuorumBps,
    ordinary_approval_bps: input.ordinaryApprovalBps,
    special_quorum_bps: input.specialQuorumBps,
    special_approval_bps: input.specialApprovalBps,
    vote_change_allowed: input.voteChangeAllowed,
  };
};

export const missingRequiredOffices = (activeOfficeKeys: readonly string[]) => {
  const active = new Set(activeOfficeKeys);
  return REQUIRED_INITIAL_OFFICES.filter((office) => !active.has(office));
};

export const thresholdCount = (eligibleCount: number, basisPoints: number) => {
  if (!Number.isInteger(eligibleCount) || eligibleCount < 0) {
    throw new GroupConstitutionRuleError('INVALID_ELIGIBLE_COUNT');
  }
  assertBps(basisPoints, 'threshold_bps');
  return Math.ceil((eligibleCount * basisPoints) / 10_000);
};
