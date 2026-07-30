import { supabase } from '../utils/supabase.js';
import {
  BookingDisputeTransition,
  DisputeResolutionAllocation,
} from '../domains/booking/disputeResolutionRules.js';

const ERROR_MAPPING: ReadonlyArray<readonly [string, string, number]> = [
  ['BOOKING_DISPUTE_TRANSITION_INVALID', 'BOOKING_DISPUTE_TRANSITION_INVALID', 400],
  ['BOOKING_DISPUTE_RESOLUTION_INVALID', 'BOOKING_DISPUTE_RESOLUTION_INVALID', 400],
  ['BOOKING_DISPUTE_DECISION_INVALID', 'BOOKING_DISPUTE_DECISION_INVALID', 400],
  ['BOOKING_DISPUTE_RESPONSE_RULE_INVALID', 'BOOKING_DISPUTE_RESPONSE_RULE_INVALID', 400],
  ['BOOKING_DISPUTE_RESPONSE_RULE_DECISION_INVALID', 'BOOKING_DISPUTE_RESPONSE_RULE_DECISION_INVALID', 400],
  ['BOOKING_DISPUTE_NOT_AUTHORIZED', 'BOOKING_DISPUTE_NOT_AUTHORIZED', 403],
  ['BOOKING_DISPUTE_APPROVER_NOT_INDEPENDENT', 'BOOKING_DISPUTE_APPROVER_NOT_INDEPENDENT', 403],
  ['MAKER_CHECKER_REQUIRED', 'MAKER_CHECKER_REQUIRED', 409],
  ['BOOKING_DISPUTE_NOT_FOUND', 'BOOKING_DISPUTE_NOT_FOUND', 404],
  ['BOOKING_DISPUTE_RESOLUTION_NOT_FOUND', 'BOOKING_DISPUTE_RESOLUTION_NOT_FOUND', 404],
  ['BOOKING_DISPUTE_RESPONSE_RULE_NOT_FOUND', 'BOOKING_DISPUTE_RESPONSE_RULE_NOT_FOUND', 404],
  ['IDEMPOTENCY_REPLAY_CONFLICT', 'IDEMPOTENCY_REPLAY_CONFLICT', 409],
  ['BOOKING_DISPUTE_TRANSITION_NOT_ALLOWED', 'BOOKING_DISPUTE_TRANSITION_NOT_ALLOWED', 409],
  ['BOOKING_DISPUTE_RESOLUTION_STATE_INVALID', 'BOOKING_DISPUTE_RESOLUTION_STATE_INVALID', 409],
  ['BOOKING_DISPUTE_RESOLUTION_NOT_CONSERVED', 'BOOKING_DISPUTE_RESOLUTION_NOT_CONSERVED', 409],
  ['BOOKING_DISPUTE_RESOLUTION_ALREADY_PENDING', 'BOOKING_DISPUTE_RESOLUTION_ALREADY_PENDING', 409],
  ['BOOKING_DISPUTE_RESOLUTION_EVIDENCE_INVALID', 'BOOKING_DISPUTE_RESOLUTION_EVIDENCE_INVALID', 409],
  ['BOOKING_DISPUTE_PLATFORM_FEE_MISMATCH', 'BOOKING_DISPUTE_PLATFORM_FEE_MISMATCH', 409],
  ['BOOKING_DISPUTE_DECISION_ALREADY_RECORDED', 'BOOKING_DISPUTE_DECISION_ALREADY_RECORDED', 409],
  ['BOOKING_DISPUTE_RESPONSE_RULE_VERSION_CONFLICT', 'BOOKING_DISPUTE_RESPONSE_RULE_VERSION_CONFLICT', 409],
  ['BOOKING_DISPUTE_RESPONSE_RULE_DECIDED', 'BOOKING_DISPUTE_RESPONSE_RULE_DECIDED', 409],
];

export class BookingDisputeResolutionError extends Error {
  constructor(readonly code: string, readonly status: number) {
    super(code);
  }
}

const mapError = (error: { message?: string } | null) => {
  const message = error?.message ?? '';
  const match = ERROR_MAPPING.find(([needle]) => message.includes(needle));
  return match
    ? new BookingDisputeResolutionError(match[1], match[2])
    : new BookingDisputeResolutionError('BOOKING_DISPUTE_RESOLUTION_FAILED', 503);
};

const rpc = async (name: string, params: Record<string, unknown>) => {
  const { data, error } = await supabase.rpc(name, params);
  if (error || !data) throw mapError(error);
  return data;
};

export const bookingDisputeResolutionService = {
  transition(input: {
    disputeId: string; organizationId: string; actorId: string;
    targetState: BookingDisputeTransition; reason: string;
    idempotencyKey: string; correlationId: string;
  }) {
    return rpc('transition_booking_dispute', {
      p_dispute_id: input.disputeId,
      p_acting_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_target_state: input.targetState,
      p_reason: input.reason,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: input.correlationId,
    });
  },

  propose(input: {
    disputeId: string; organizationId: string; actorId: string;
    allocation: DisputeResolutionAllocation; reason: string; evidenceIds: string[];
    idempotencyKey: string; correlationId: string;
  }) {
    return rpc('propose_booking_dispute_resolution', {
      p_dispute_id: input.disputeId,
      p_acting_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_customer_refund_minor: input.allocation.customerRefundMinor,
      p_supplier_release_minor: input.allocation.supplierReleaseMinor,
      p_platform_fee_minor: input.allocation.platformFeeMinor,
      p_recoverable_amount_minor: input.allocation.recoverableAmountMinor,
      p_loss_amount_minor: input.allocation.lossAmountMinor,
      p_reason: input.reason,
      p_evidence_ids: input.evidenceIds,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: input.correlationId,
    });
  },

  decide(input: {
    proposalId: string; organizationId: string; actorId: string;
    approve: boolean; reason: string;
    idempotencyKey: string; correlationId: string;
  }) {
    return rpc('decide_booking_dispute_resolution_authorized', {
      p_proposal_id: input.proposalId,
      p_acting_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_approve: input.approve,
      p_reason: input.reason,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: input.correlationId,
    });
  },

  readCase(disputeId: string, organizationId: string, actorId: string) {
    return rpc('read_booking_dispute_resolution_case', {
      p_dispute_id: disputeId,
      p_acting_organization_id: organizationId,
      p_actor_id: actorId,
    });
  },

  proposeResponseRule(input: {
    organizationId: string; actorId: string; version: number;
    responsePeriodDays: number; effectiveFrom: string; changeReason: string;
    idempotencyKey: string;
  }) {
    return rpc('propose_booking_dispute_response_rule', {
      p_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_version: input.version,
      p_response_period_days: input.responsePeriodDays,
      p_effective_from: input.effectiveFrom,
      p_change_reason: input.changeReason,
      p_idempotency_key: input.idempotencyKey,
    });
  },

  decideResponseRule(input: {
    ruleId: string; organizationId: string; actorId: string; approve: boolean;
    reason: string; idempotencyKey: string;
  }) {
    return rpc('decide_booking_dispute_response_rule', {
      p_rule_id: input.ruleId,
      p_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_approve: input.approve,
      p_reason: input.reason,
      p_idempotency_key: input.idempotencyKey,
    });
  },
};
