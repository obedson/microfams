export interface GroupCreationEligibility {
  role: string;
  ninVerified: boolean;
  platformSubscriber: boolean;
  paidInvitees: number;
}

export const evaluateGroupCreationEligibility = (
  input: GroupCreationEligibility,
) => input.role === 'admin' || (
  input.ninVerified
  && input.platformSubscriber
  && input.paidInvitees >= 2
);

export type GroupLifecycleState =
  | 'draft'
  | 'active'
  | 'suspended'
  | 'closing'
  | 'closed';

const TRANSITIONS: Readonly<Record<GroupLifecycleState, readonly GroupLifecycleState[]>> = {
  draft: [],
  active: ['suspended', 'closing'],
  suspended: ['active', 'closing'],
  closing: ['closed'],
  closed: [],
};

export const canTransitionGroupLifecycle = (
  from: GroupLifecycleState,
  to: GroupLifecycleState,
) => from === to || TRANSITIONS[from].includes(to);
