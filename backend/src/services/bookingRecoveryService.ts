import { supabase } from '../utils/supabase.js';

const ERROR_MAPPING: ReadonlyArray<readonly [string, string, number]> = [
  ['BOOKING_RECOVERY_OFFSET_AGREEMENT_INVALID', 'BOOKING_RECOVERY_OFFSET_AGREEMENT_INVALID', 400],
  ['BOOKING_RECOVERY_OFFSET_DECISION_INVALID', 'BOOKING_RECOVERY_OFFSET_DECISION_INVALID', 400],
  ['BOOKING_RECOVERY_ACTION_INVALID', 'BOOKING_RECOVERY_ACTION_INVALID', 400],
  ['BOOKING_RECOVERY_DECISION_INVALID', 'BOOKING_RECOVERY_DECISION_INVALID', 400],
  ['BOOKING_RECOVERY_NOT_AUTHORIZED', 'BOOKING_RECOVERY_NOT_AUTHORIZED', 403],
  ['BOOKING_RECOVERY_PROVIDER_NOT_FOUND', 'BOOKING_RECOVERY_PROVIDER_NOT_FOUND', 404],
  ['BOOKING_RECOVERY_OFFSET_AGREEMENT_NOT_FOUND', 'BOOKING_RECOVERY_OFFSET_AGREEMENT_NOT_FOUND', 404],
  ['BOOKING_RECOVERY_CASE_NOT_FOUND', 'BOOKING_RECOVERY_CASE_NOT_FOUND', 404],
  ['BOOKING_RECOVERY_ACTION_NOT_FOUND', 'BOOKING_RECOVERY_ACTION_NOT_FOUND', 404],
  ['BOOKING_RECOVERY_OFFSET_RELEASE_INVALID', 'BOOKING_RECOVERY_OFFSET_RELEASE_INVALID', 409],
  ['BOOKING_RECOVERY_AMOUNT_EXCEEDS_REMAINING', 'BOOKING_RECOVERY_AMOUNT_EXCEEDS_REMAINING', 409],
  ['BOOKING_RECOVERY_OFFSET_AGREEMENT_DECIDED', 'BOOKING_RECOVERY_OFFSET_AGREEMENT_DECIDED', 409],
  ['BOOKING_RECOVERY_ACTION_DECIDED', 'BOOKING_RECOVERY_ACTION_DECIDED', 409],
  ['MAKER_CHECKER_REQUIRED', 'MAKER_CHECKER_REQUIRED', 409],
  ['IDEMPOTENCY_REPLAY_CONFLICT', 'IDEMPOTENCY_REPLAY_CONFLICT', 409],
];

export class BookingRecoveryError extends Error {
  constructor(readonly code: string, readonly status: number) {
    super(code);
  }
}

const mapError = (error: { message?: string } | null) => {
  const message = error?.message ?? '';
  const match = ERROR_MAPPING.find(([needle]) => message.includes(needle));
  return match
    ? new BookingRecoveryError(match[1], match[2])
    : new BookingRecoveryError('BOOKING_RECOVERY_FAILED', 503);
};

export const bookingRecoveryService = {
  async proposeOffsetAgreement(input: {
    organizationId: string;
    providerOrganizationId: string;
    actorId: string;
    currency: string;
    maximumAmountMinor: number;
    effectiveFrom: string;
    effectiveUntil: string;
    reason: string;
    evidenceReference: string;
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc(
      'propose_booking_recovery_offset_agreement',
      {
        p_organization_id: input.organizationId,
        p_provider_organization_id: input.providerOrganizationId,
        p_actor_id: input.actorId,
        p_currency: input.currency,
        p_maximum_amount_minor: input.maximumAmountMinor,
        p_effective_from: input.effectiveFrom,
        p_effective_until: input.effectiveUntil,
        p_reason: input.reason,
        p_evidence_reference: input.evidenceReference,
        p_idempotency_key: input.idempotencyKey,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },

  async decideOffsetAgreement(input: {
    agreementId: string;
    organizationId: string;
    actorId: string;
    approve: boolean;
    reason: string;
  }) {
    const { data, error } = await supabase.rpc(
      'decide_booking_recovery_offset_agreement',
      {
        p_agreement_id: input.agreementId,
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_approve: input.approve,
        p_reason: input.reason,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },

  async proposeAction(input: {
    recoveryCaseId: string;
    organizationId: string;
    actorId: string;
    method: string;
    amountMinor: number;
    offsetAgreementId: string | null;
    settlementReleaseId: string | null;
    evidenceReference: string;
    reason: string;
    idempotencyKey: string;
  }) {
    const { data, error } = await supabase.rpc(
      'propose_booking_recovery_action',
      {
        p_recovery_case_id: input.recoveryCaseId,
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_method: input.method,
        p_amount_minor: input.amountMinor,
        p_offset_agreement_id: input.offsetAgreementId,
        p_settlement_release_id: input.settlementReleaseId,
        p_evidence_reference: input.evidenceReference,
        p_reason: input.reason,
        p_idempotency_key: input.idempotencyKey,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },

  async decideAction(input: {
    actionId: string;
    organizationId: string;
    actorId: string;
    approve: boolean;
    reason: string;
  }) {
    const { data, error } = await supabase.rpc(
      'decide_booking_recovery_action',
      {
        p_action_id: input.actionId,
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_approve: input.approve,
        p_reason: input.reason,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },
};
