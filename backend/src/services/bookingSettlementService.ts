import { supabase } from '../utils/supabase.js';

const ERROR_MAPPING: ReadonlyArray<readonly [string, string, number]> = [
  ['BOOKING_RULE_NOT_AUTHORIZED', 'BOOKING_RULE_NOT_AUTHORIZED', 403],
  ['MAKER_CHECKER_REQUIRED', 'MAKER_CHECKER_REQUIRED', 403],
  ['BOOKING_RULE_INVALID', 'BOOKING_RULE_INVALID', 400],
  ['BOOKING_RULE_DECISION_REASON_INVALID', 'BOOKING_RULE_DECISION_REASON_INVALID', 400],
  ['BOOKING_RULE_APPROVAL_NOT_FOUND', 'BOOKING_RULE_APPROVAL_NOT_FOUND', 404],
  ['BOOKING_RULE_EFFECTIVE_WINDOW_CONFLICT', 'BOOKING_RULE_EFFECTIVE_WINDOW_CONFLICT', 409],
  ['BOOKING_FEE_BENEFICIARY_INVALID', 'BOOKING_FEE_BENEFICIARY_INVALID', 409],
  ['BOOKING_CUSTOMER_FEE_REQUIRES_PREPAYMENT', 'BOOKING_CUSTOMER_FEE_REQUIRES_PREPAYMENT', 409],
  ['BOOKING_SETTLEMENT_NOT_FOUND', 'BOOKING_SETTLEMENT_NOT_FOUND', 404],
  ['BOOKING_SETTLEMENT_NOT_AUTHORIZED', 'BOOKING_SETTLEMENT_NOT_AUTHORIZED', 403],
  ['BOOKING_SETTLEMENT_REQUEST_INVALID', 'BOOKING_SETTLEMENT_REQUEST_INVALID', 400],
  ['IDEMPOTENCY_REPLAY_CONFLICT', 'IDEMPOTENCY_REPLAY_CONFLICT', 409],
  ['BOOKING_SETTLEMENT_DISPUTE_WINDOW_OPEN', 'BOOKING_SETTLEMENT_DISPUTE_WINDOW_OPEN', 409],
  ['BOOKING_SETTLEMENT_NOT_COMPLETED', 'BOOKING_SETTLEMENT_NOT_COMPLETED', 409],
  ['BOOKING_SETTLEMENT_PAYMENT_NOT_ELIGIBLE', 'BOOKING_SETTLEMENT_PAYMENT_NOT_ELIGIBLE', 409],
  ['BOOKING_SETTLEMENT_NO_RELEASABLE_AMOUNT', 'BOOKING_SETTLEMENT_NO_RELEASABLE_AMOUNT', 409],
  ['BOOKING_SETTLEMENT_REVERSED', 'BOOKING_SETTLEMENT_REVERSED', 409],
  ['BOOKING_SETTLEMENT_REFUND_REVIEW_REQUIRED', 'BOOKING_SETTLEMENT_REFUND_REVIEW_REQUIRED', 409],
  ['BOOKING_SETTLEMENT_ORGANIZATION_INACTIVE', 'BOOKING_SETTLEMENT_ORGANIZATION_INACTIVE', 409],
  ['BOOKING_SETTLEMENT_ORGANIZATION_SUSPENDED', 'BOOKING_SETTLEMENT_ORGANIZATION_SUSPENDED', 409],
  ['BOOKING_SETTLEMENT_LEGAL_HOLD', 'BOOKING_SETTLEMENT_LEGAL_HOLD', 409],
  ['BOOKING_SETTLEMENT_RISK_HOLD', 'BOOKING_SETTLEMENT_RISK_HOLD', 409],
  ['BOOKING_SETTLEMENT_ACTIVE_HOLD', 'BOOKING_SETTLEMENT_ACTIVE_HOLD', 409],
  ['BOOKING_SETTLEMENT_ACCOUNTING_ACTOR_UNAVAILABLE', 'BOOKING_SETTLEMENT_ACCOUNTING_ACTOR_UNAVAILABLE', 409],
  ['BOOKING_FEE_RULE_UNAVAILABLE', 'BOOKING_FEE_RULE_UNAVAILABLE', 409],
  ['BOOKING_FEE_BENEFICIARY_INVALID', 'BOOKING_FEE_BENEFICIARY_INVALID', 409],
];

export class BookingSettlementError extends Error {
  constructor(readonly code: string, readonly status: number) {
    super(code);
  }
}

const mapDatabaseError = (error: { message?: string } | null): BookingSettlementError => {
  const message = error?.message ?? '';
  const mapped = ERROR_MAPPING.find(([needle]) => message.includes(needle));
  return mapped
    ? new BookingSettlementError(mapped[1], mapped[2])
    : new BookingSettlementError('BOOKING_SETTLEMENT_COMMAND_FAILED', 503);
};

export const bookingSettlementService = {
  async readRules(organizationId: string, actorId: string) {
    const { data, error } = await supabase.rpc('read_booking_financial_rules', {
      p_organization_id: organizationId,
      p_actor_id: actorId,
    });
    if (error || !data) throw mapDatabaseError(error);
    return data;
  },

  async proposeSettlementRule(input: {
    organizationId: string;
    actorId: string;
    version: number;
    disputeWindowHours: number;
    effectiveFrom: string;
    changeReason: string;
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('propose_booking_settlement_rule', {
      p_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_version: input.version,
      p_dispute_window_hours: input.disputeWindowHours,
      p_effective_from: input.effectiveFrom,
      p_change_reason: input.changeReason,
      p_idempotency_key: input.idempotencyKey,
    });
    if (error || !data) throw mapDatabaseError(error);
    return data;
  },

  async proposeFeeRule(input: {
    organizationId: string;
    actorId: string;
    version: number;
    currency: string;
    payer: 'customer' | 'supplier';
    beneficiaryOrganizationId: string | null;
    fixedAmountMinor: number;
    basisPoints: number;
    minimumAmountMinor: number;
    maximumAmountMinor: number | null;
    taxWithholdingMetadata: Record<string, unknown>;
    effectiveFrom: string;
    changeReason: string;
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('propose_booking_fee_rule', {
      p_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_version: input.version,
      p_currency: input.currency,
      p_payer: input.payer,
      p_beneficiary_organization_id: input.beneficiaryOrganizationId,
      p_fixed_amount_minor: input.fixedAmountMinor,
      p_basis_points: input.basisPoints,
      p_minimum_amount_minor: input.minimumAmountMinor,
      p_maximum_amount_minor: input.maximumAmountMinor,
      p_tax_withholding_metadata: input.taxWithholdingMetadata,
      p_effective_from: input.effectiveFrom,
      p_change_reason: input.changeReason,
      p_idempotency_key: input.idempotencyKey,
    });
    if (error || !data) throw mapDatabaseError(error);
    return data;
  },

  async decideRule(input: {
    approvalId: string;
    organizationId: string;
    actorId: string;
    approve: boolean;
    reason: string;
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc('decide_booking_financial_rule', {
      p_approval_id: input.approvalId,
      p_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_approve: input.approve,
      p_reason: input.reason,
      p_idempotency_key: input.idempotencyKey,
    });
    if (error || !data) throw mapDatabaseError(error);
    return data;
  },

  async read(bookingId: string, organizationId: string, actorId: string) {
    const { data, error } = await supabase.rpc('read_booking_settlement_summary', {
      p_booking_id: bookingId,
      p_acting_organization_id: organizationId,
      p_actor_id: actorId,
    });
    if (error || !data) throw mapDatabaseError(error);
    return data;
  },

  async release(input: {
    bookingId: string;
    organizationId: string;
    actorId: string;
    idempotencyKey: string;
    correlationId: string;
  }) {
    const { data, error } = await supabase.rpc('release_booking_settlement', {
      p_booking_id: input.bookingId,
      p_acting_organization_id: input.organizationId,
      p_actor_id: input.actorId,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: input.correlationId,
    });
    if (error || !data) throw mapDatabaseError(error);
    return data;
  },
};
