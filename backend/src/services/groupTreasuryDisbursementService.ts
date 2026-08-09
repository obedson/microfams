import { createHash, randomBytes, createCipheriv, createDecipheriv } from 'crypto';
import supabase from '../utils/supabase.js';
import {
  assertFundsAvailable,
  assertSeparationOfDuties,
  validateDisbursementRequest,
  validateExternalBeneficiary,
  validateReleaseReasonCode,
} from '../domains/groups/treasuryDisbursementRules.js';
import { configuredPayoutAdapter } from '../domains/financial/payoutAdapters.js';
import { payoutService } from '../domains/financial/payoutService.js';
import { PayoutDestination } from '../domains/financial/payoutTypes.js';

export interface GroupTreasuryContext {
  organizationId: string;
  groupId: string;
  actorId: string;
}

const correlationId = (context: GroupTreasuryContext, command: string, key: string) => {
  const digest = createHash('sha256')
    .update(`${context.organizationId}:${context.groupId}:${context.actorId}:${command}:${key}`)
    .digest('hex');
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-4${digest.slice(13, 16)}-a${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
};

// An external destination is held encrypted at rest, exactly as BS-08 holds a
// booking supplier destination, but under its own key so a treasury key leak
// cannot decrypt supplier accounts and vice versa. AES-256-GCM, versioned
// ciphertext, base64url segments — the same format the booking registry uses.
class GroupTreasuryEncryptionError extends Error {
  statusCode = 503;
}
const encryptionKey = (
  configured = process.env.GROUP_TREASURY_DESTINATION_ENCRYPTION_KEY,
) => {
  if (!configured) {
    throw new GroupTreasuryEncryptionError('GROUP_TREASURY_ENCRYPTION_NOT_CONFIGURED');
  }
  const key = Buffer.from(configured, 'base64');
  if (key.length !== 32) {
    throw new GroupTreasuryEncryptionError('GROUP_TREASURY_ENCRYPTION_NOT_CONFIGURED');
  }
  return key;
};

export const encryptGroupTreasuryDestination = (
  destination: PayoutDestination,
  configuredKey?: string,
) => {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', encryptionKey(configuredKey), iv);
  const encrypted = Buffer.concat([
    cipher.update(JSON.stringify(destination), 'utf8'),
    cipher.final(),
  ]);
  return [
    'v1',
    iv.toString('base64url'),
    cipher.getAuthTag().toString('base64url'),
    encrypted.toString('base64url'),
  ].join('.');
};

export const decryptGroupTreasuryDestination = (
  ciphertext: string,
  configuredKey?: string,
): PayoutDestination => {
  const [version, iv, tag, encrypted] = ciphertext.split('.');
  if (version !== 'v1' || !iv || !tag || !encrypted) {
    throw new GroupTreasuryEncryptionError('GROUP_TREASURY_DESTINATION_INVALID');
  }
  try {
    const decipher = createDecipheriv(
      'aes-256-gcm', encryptionKey(configuredKey), Buffer.from(iv, 'base64url'),
    );
    decipher.setAuthTag(Buffer.from(tag, 'base64url'));
    return JSON.parse(Buffer.concat([
      decipher.update(Buffer.from(encrypted, 'base64url')),
      decipher.final(),
    ]).toString('utf8'));
  } catch {
    throw new GroupTreasuryEncryptionError('GROUP_TREASURY_DESTINATION_INVALID');
  }
};

const destinationFingerprint = (bankCode: string, accountNumber: string) =>
  createHash('sha256').update(`${bankCode}:${accountNumber}`).digest('hex');
const maskedAccount = (accountNumber: string) => `******${accountNumber.slice(-4)}`;
const maskedName = (accountName: string) => {
  const value = accountName.trim();
  return value.length <= 4
    ? `${value.slice(0, 1)}***`
    : `${value.slice(0, 4)}****${value.slice(-2)}`;
};

const DISBURSEMENT_COLUMNS = 'id, budget_id, constitution_id, proposal_id, channel, beneficiary_kind, beneficiary_member_id, beneficiary_user_id, beneficiary_group_id, beneficiary_project_id, external_beneficiary_id, payout_id, amount_minor, currency, purpose, evidence_uri, execute_from, execute_until, state, requested_by, final_checker_id, approver_count, available_minor_at_approval, quorum_bps_applied, approval_bps_applied, threshold_basis, reservation_id, execution_journal_entry_id, reversal_journal_entry_id, approved_at, executed_at, settled_state_at, created_at';

const BUDGET_COLUMNS = 'id, constitution_id, budget_key, display_name, purpose, currency, ceiling_minor, committed_minor, disbursed_minor, state, low_value_band_minor, low_value_quorum_bps, low_value_approval_bps, period_start, period_end, opened_at, closed_at';

const RESERVATION_COLUMNS = 'id, budget_id, disbursement_id, source_account_id, amount_minor, currency, state, available_minor_at_reserve, expires_at, consumed_journal_entry_id, consumed_at, released_at, expired_at, release_reason_code';

// A beneficiary read never discloses the destination: only masks, the provider
// pairing, and the verification lifecycle. The ciphertext and fingerprint stay
// server-side.
const BENEFICIARY_COLUMNS = 'id, group_id, beneficiary_user_id, destination_masked, account_name_masked, provider_name, provider_environment, verification_reference, state, proposed_by, approved_by, approval_reason, approved_at, created_at, updated_at';

const publicDisbursement = (row: any) => row && ({
  id: row.id,
  budgetId: row.budget_id,
  constitutionId: row.constitution_id,
  proposalId: row.proposal_id,
  channel: row.channel,
  beneficiaryKind: row.beneficiary_kind,
  beneficiaryMemberId: row.beneficiary_member_id,
  beneficiaryUserId: row.beneficiary_user_id,
  beneficiaryGroupId: row.beneficiary_group_id,
  beneficiaryProjectId: row.beneficiary_project_id,
  externalBeneficiaryId: row.external_beneficiary_id,
  payoutId: row.payout_id,
  amountMinor: row.amount_minor,
  currency: row.currency,
  purpose: row.purpose,
  evidenceUri: row.evidence_uri,
  executeFrom: row.execute_from,
  executeUntil: row.execute_until,
  state: row.state,
  // Maker and checker are surfaced separately so a reviewer can see the two
  // distinct people behind any executed payment (clause 3).
  requestedBy: row.requested_by,
  finalCheckerId: row.final_checker_id,
  approverCount: row.approver_count,
  // Clause 5: what was true when the decision was taken, kept beside the row so
  // the approval stays explainable after balances move on.
  availableMinorAtApproval: row.available_minor_at_approval,
  quorumBpsApplied: row.quorum_bps_applied,
  approvalBpsApplied: row.approval_bps_applied,
  thresholdBasis: row.threshold_basis,
  reservationId: row.reservation_id,
  executionJournalEntryId: row.execution_journal_entry_id,
  reversalJournalEntryId: row.reversal_journal_entry_id,
  approvedAt: row.approved_at,
  executedAt: row.executed_at,
  settledStateAt: row.settled_state_at,
  createdAt: row.created_at,
});

const publicBeneficiary = (row: any) => row && ({
  id: row.id,
  groupId: row.group_id,
  beneficiaryUserId: row.beneficiary_user_id,
  destinationMasked: row.destination_masked,
  accountNameMasked: row.account_name_masked,
  providerName: row.provider_name,
  providerEnvironment: row.provider_environment,
  verificationReference: row.verification_reference,
  state: row.state,
  proposedBy: row.proposed_by,
  approvedBy: row.approved_by,
  approvalReason: row.approval_reason,
  approvedAt: row.approved_at,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

const publicBudget = (row: any) => row && ({
  id: row.id,
  constitutionId: row.constitution_id,
  budgetKey: row.budget_key,
  displayName: row.display_name,
  purpose: row.purpose,
  currency: row.currency,
  ceilingMinor: row.ceiling_minor,
  committedMinor: row.committed_minor,
  disbursedMinor: row.disbursed_minor,
  // Derived rather than stored, so it cannot drift from the two figures it
  // sits between.
  remainingMinor:
    Number(row.ceiling_minor) - Number(row.committed_minor) - Number(row.disbursed_minor),
  state: row.state,
  lowValueBandMinor: row.low_value_band_minor,
  lowValueQuorumBps: row.low_value_quorum_bps,
  lowValueApprovalBps: row.low_value_approval_bps,
  periodStart: row.period_start,
  periodEnd: row.period_end,
  openedAt: row.opened_at,
  closedAt: row.closed_at,
});

const publicReservation = (row: any) => row && ({
  id: row.id,
  budgetId: row.budget_id,
  disbursementId: row.disbursement_id,
  sourceAccountId: row.source_account_id,
  amountMinor: row.amount_minor,
  currency: row.currency,
  state: row.state,
  availableMinorAtReserve: row.available_minor_at_reserve,
  expiresAt: row.expires_at,
  consumedJournalEntryId: row.consumed_journal_entry_id,
  consumedAt: row.consumed_at,
  releasedAt: row.released_at,
  expiredAt: row.expired_at,
  releaseReasonCode: row.release_reason_code,
});

/**
 * GT-06A treasury operations. Every state change goes through a database
 * function so the disbursement, its reservation, and the journal move in one
 * transaction; this layer validates the caller's request and shapes the
 * response. Availability is read back from the engine rather than cached,
 * because a stale figure is what lets two approvals spend the same money.
 */
export class GroupTreasuryDisbursementService {
  /**
   * Funds available after existing reservations, derived from posted journals
   * rather than a mutable balance column (clause 2).
   */
  async getAvailableMinor(context: GroupTreasuryContext) {
    const { data, error } = await supabase.rpc('group_treasury_available_minor', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
    });
    if (error) throw error;
    return Number(data ?? 0);
  }

  async listBudgets(context: GroupTreasuryContext) {
    const { data, error } = await supabase
      .from('group_treasury_budgets')
      .select(BUDGET_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .order('budget_key', { ascending: true });
    if (error) throw error;
    return (data ?? []).map(publicBudget);
  }

  async activateBudget(
    context: GroupTreasuryContext,
    budgetId: string,
    input: { idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('activate_group_treasury_budget', {
      p_organization_id: context.organizationId,
      p_budget_id: budgetId,
      p_actor_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-budget-activate:${budgetId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { budgetId: data };
  }

  /**
   * Raises a spending request against an approved proposal. The amount is
   * checked against funds available after existing reservations so an obviously
   * unfundable request is refused early, but the binding check is the one the
   * engine performs under lock at approval time (clause 2).
   */
  async requestDisbursement(
    context: GroupTreasuryContext,
    input: {
      budgetId: string;
      proposalId: string;
      beneficiaryKind: string;
      beneficiaryMemberId?: string | null;
      beneficiaryGroupId?: string | null;
      beneficiaryProjectId?: string | null;
      amountMinor: number;
      currency: string;
      purpose: string;
      evidenceUri: string;
      executeFrom: string;
      executeUntil: string;
      idempotencyKey: string;
    },
  ) {
    const request = validateDisbursementRequest({
      channel: 'internal',
      beneficiaryKind: input.beneficiaryKind,
      beneficiaryMemberId: input.beneficiaryMemberId,
      amountMinor: input.amountMinor,
      currency: input.currency,
      purpose: input.purpose,
      evidenceUri: input.evidenceUri,
    });

    assertFundsAvailable({
      availableMinor: await this.getAvailableMinor(context),
      amountMinor: request.amountMinor,
    });

    const { data, error } = await supabase.rpc('request_group_treasury_disbursement', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_budget_id: input.budgetId,
      p_proposal_id: input.proposalId,
      p_beneficiary_kind: request.beneficiaryKind,
      p_beneficiary_member_id: request.beneficiaryMemberId,
      p_beneficiary_group_id: input.beneficiaryGroupId ?? null,
      p_beneficiary_project_id: input.beneficiaryProjectId ?? null,
      p_amount_minor: request.amountMinor,
      p_currency: request.currency,
      p_purpose: request.purpose,
      p_evidence_uri: request.evidenceUri,
      p_execute_from: input.executeFrom,
      p_execute_until: input.executeUntil,
      p_requested_by: context.actorId,
      p_idempotency_key: input.idempotencyKey,
      p_correlation_id: correlationId(
        context, `treasury-request:${input.budgetId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { disbursementId: data };
  }

  /**
   * Countersigns a request and reserves the funds in the same transaction. The
   * separation check is repeated here so an API caller is refused before the
   * engine is reached; the engine enforces it again under lock.
   */
  async approveDisbursement(
    context: GroupTreasuryContext,
    disbursementId: string,
    input: { idempotencyKey: string },
  ) {
    const existing = await this.getDisbursement(context, disbursementId);
    if (existing) {
      assertSeparationOfDuties({
        requestedByUserId: existing.requestedBy,
        checkerUserId: context.actorId,
        beneficiaryUserId: existing.beneficiaryUserId,
      });
    }

    const { data, error } = await supabase.rpc('approve_group_treasury_disbursement', {
      p_organization_id: context.organizationId,
      p_disbursement_id: disbursementId,
      p_final_checker_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-approve:${disbursementId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { reservationId: data };
  }

  /**
   * Posts the payment. Execution revalidates what approval assumed rather than
   * trusting it, because the constitution may have changed and the budget may
   * have been closed in between (clause 5).
   */
  async executeDisbursement(
    context: GroupTreasuryContext,
    disbursementId: string,
    input: { idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('execute_group_treasury_disbursement', {
      p_organization_id: context.organizationId,
      p_disbursement_id: disbursementId,
      p_actor_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-execute:${disbursementId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { journalEntryId: data };
  }

  /**
   * Releases the reservation behind an unexecuted disbursement, returning the
   * funds to available. A reservation is consumed or released exactly once, so a
   * repeat release reports false rather than double-crediting the treasury
   * (clause 7).
   */
  async releaseReservation(
    context: GroupTreasuryContext,
    disbursementId: string,
    input: { reasonCode: string; idempotencyKey: string },
  ) {
    validateReleaseReasonCode(input.reasonCode);
    const { data, error } = await supabase.rpc('release_group_treasury_reservation', {
      p_organization_id: context.organizationId,
      p_disbursement_id: disbursementId,
      p_reason_code: input.reasonCode,
      p_actor_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-release:${disbursementId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { released: data === true };
  }

  /**
   * Reverses a posted payment with an opposing journal. The original entry is
   * never deleted, so the register keeps both the payment and its correction
   * (clause 7).
   */
  async reverseDisbursement(
    context: GroupTreasuryContext,
    disbursementId: string,
    input: { reasonCode: string; idempotencyKey: string },
  ) {
    validateReleaseReasonCode(input.reasonCode);
    const { data, error } = await supabase.rpc('reverse_group_treasury_disbursement', {
      p_organization_id: context.organizationId,
      p_disbursement_id: disbursementId,
      p_reason_code: input.reasonCode,
      p_actor_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-reverse:${disbursementId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { reversalJournalEntryId: data };
  }

  async listDisbursements(
    context: GroupTreasuryContext,
    filters: { state?: string; budgetId?: string } = {},
  ) {
    let query = supabase
      .from('group_treasury_disbursements')
      .select(DISBURSEMENT_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId);
    if (filters.state) query = query.eq('state', filters.state);
    if (filters.budgetId) query = query.eq('budget_id', filters.budgetId);
    const { data, error } = await query.order('created_at', { ascending: false });
    if (error) throw error;
    return (data ?? []).map(publicDisbursement);
  }

  async getDisbursement(context: GroupTreasuryContext, disbursementId: string) {
    const { data, error } = await supabase
      .from('group_treasury_disbursements')
      .select(DISBURSEMENT_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .eq('id', disbursementId)
      .maybeSingle();
    if (error) throw error;
    return publicDisbursement(data);
  }

  async listReservations(context: GroupTreasuryContext, state?: string) {
    let query = supabase
      .from('group_treasury_reservations')
      .select(RESERVATION_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId);
    if (state) query = query.eq('state', state);
    const { data, error } = await query.order('created_at', { ascending: false });
    if (error) throw error;
    return (data ?? []).map(publicReservation);
  }

  // ---------------------------------------------------------------------------
  // GT-06B external provider disbursements.
  //
  // The registry owns destination custody exactly as BS-08 does for booking
  // suppliers: the provider verifies the account, the cleartext is encrypted at
  // rest under the treasury's own key, and a checker who is neither the proposer
  // nor the named beneficiary verifies it before any money can name it.
  // ---------------------------------------------------------------------------

  /**
   * Registers an off-platform destination for a group. The provider verifies the
   * account first, so a registration that reaches the registry is one the bank
   * confirmed; the cleartext is held encrypted and only masks are ever read back.
   * Idempotent on (organization, idempotencyKey).
   */
  async registerBeneficiary(
    context: GroupTreasuryContext,
    input: {
      beneficiaryUserId?: string | null;
      accountNumber: string;
      bankCode: string;
      accountName: string;
      currency: string;
      idempotencyKey: string;
    },
  ) {
    const registration = validateExternalBeneficiary({
      accountNumber: input.accountNumber,
      bankCode: input.bankCode,
      accountName: input.accountName,
      currency: input.currency,
    });
    const adapter = configuredPayoutAdapter();
    await payoutService.assertRoutingEnabled(
      adapter, context.organizationId, context.actorId,
    );
    const verified = await adapter.validateDestination(
      registration.accountNumber, registration.bankCode,
    );
    const destination: PayoutDestination = {
      accountNumber: registration.accountNumber,
      bankCode: verified.bankCode,
      accountName: verified.accountName,
    };
    const fingerprint = destinationFingerprint(
      destination.bankCode, destination.accountNumber,
    );
    const verificationReference = `VRF-${createHash('sha256')
      .update(`${adapter.name}:${adapter.environment}:${fingerprint}`)
      .digest('hex')
      .slice(0, 32)}`;
    // The request hash pins the meaningful content of the registration, so an
    // idempotency-key replay carrying a different destination is refused rather
    // than silently returning the first row.
    const requestHash = createHash('sha256')
      .update(JSON.stringify({
        organizationId: context.organizationId,
        groupId: context.groupId,
        beneficiaryUserId: input.beneficiaryUserId ?? null,
        fingerprint,
        provider: adapter.name,
        environment: adapter.environment,
      }))
      .digest('hex');
    const { data, error } = await supabase.rpc('register_group_treasury_beneficiary', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_beneficiary_user_id: input.beneficiaryUserId ?? null,
      p_destination_ciphertext: encryptGroupTreasuryDestination(destination),
      p_destination_fingerprint: fingerprint,
      p_destination_masked: maskedAccount(destination.accountNumber),
      p_account_name_masked: maskedName(destination.accountName),
      p_provider_name: adapter.name,
      p_provider_environment: adapter.environment,
      p_verification_reference: verificationReference,
      p_idempotency_key: input.idempotencyKey,
      p_request_hash: requestHash,
      p_correlation_id: correlationId(
        context, 'treasury-beneficiary-register', input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return publicBeneficiary(data);
  }

  /**
   * Verifies a pending beneficiary. The checker must differ from the proposer and
   * from the named beneficiary user, and must hold the treasury approve
   * authority — the same separation the migration enforces under lock.
   */
  async approveBeneficiary(
    context: GroupTreasuryContext,
    beneficiaryId: string,
    input: { approvalReason: string; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('approve_group_treasury_beneficiary', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_beneficiary_id: beneficiaryId,
      p_checker_id: context.actorId,
      p_approval_reason: input.approvalReason,
      p_correlation_id: correlationId(
        context, `treasury-beneficiary-approve:${beneficiaryId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return publicBeneficiary(data);
  }

  async rejectBeneficiary(
    context: GroupTreasuryContext,
    beneficiaryId: string,
    input: { idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('reject_group_treasury_beneficiary', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_beneficiary_id: beneficiaryId,
      p_checker_id: context.actorId,
      p_correlation_id: correlationId(
        context, `treasury-beneficiary-reject:${beneficiaryId}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return publicBeneficiary(data);
  }

  async listBeneficiaries(context: GroupTreasuryContext, state?: string) {
    let query = supabase
      .from('group_treasury_beneficiaries')
      .select(BENEFICIARY_COLUMNS)
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId);
    if (state) query = query.eq('state', state);
    const { data, error } = await query.order('created_at', { ascending: false });
    if (error) throw error;
    return (data ?? []).map(publicBeneficiary);
  }

  /**
   * Raises an external spending request against a verified beneficiary. The
   * amount is checked against funds available after existing reservations before
   * it reaches the engine; the binding budget-ceiling check runs under lock in
   * the database function. Once requested, an external disbursement is
   * countersigned through the same approveDisbursement path an internal one uses.
   */
  async requestExternalDisbursement(
    context: GroupTreasuryContext,
    input: {
      budgetId: string;
      proposalId: string;
      externalBeneficiaryId: string;
      amountMinor: number;
      currency: string;
      purpose: string;
      evidenceUri: string;
      executeFrom: string;
      executeUntil: string;
      idempotencyKey: string;
    },
  ) {
    const request = validateDisbursementRequest({
      channel: 'external',
      beneficiaryKind: 'external',
      externalBeneficiaryId: input.externalBeneficiaryId,
      amountMinor: input.amountMinor,
      currency: input.currency,
      purpose: input.purpose,
      evidenceUri: input.evidenceUri,
    });

    assertFundsAvailable({
      availableMinor: await this.getAvailableMinor(context),
      amountMinor: request.amountMinor,
    });

    const { data, error } = await supabase.rpc(
      'request_group_treasury_external_disbursement',
      {
        p_organization_id: context.organizationId,
        p_group_id: context.groupId,
        p_budget_id: input.budgetId,
        p_proposal_id: input.proposalId,
        p_external_beneficiary_id: request.externalBeneficiaryId,
        p_amount_minor: request.amountMinor,
        p_currency: request.currency,
        p_purpose: request.purpose,
        p_evidence_uri: request.evidenceUri,
        p_execute_from: input.executeFrom,
        p_execute_until: input.executeUntil,
        p_requested_by: context.actorId,
        p_idempotency_key: input.idempotencyKey,
        p_correlation_id: correlationId(
          context, `treasury-external-request:${input.budgetId}`, input.idempotencyKey,
        ),
      },
    );
    if (error) throw error;
    return { disbursementId: data };
  }

  /**
   * Moves an approved external disbursement into flight. The engine creates a
   * reserved payout and flips the disbursement to `disbursing` under lock (no
   * journal yet — Option B posts only on confirmed success); this layer then
   * hands the cleartext destination to the provider. A provider that never
   * answers leaves the payout `processing` with the reservation still held, which
   * the sync path later resolves. Idempotent: a repeat while already disbursing
   * re-submits the same reserved payout or returns it untouched.
   */
  async beginExternalDisbursement(
    context: GroupTreasuryContext,
    disbursementId: string,
    input: { idempotencyKey: string },
  ) {
    const adapter = configuredPayoutAdapter();
    await payoutService.assertRoutingEnabled(
      adapter, context.organizationId, context.actorId,
    );

    // Destination custody stays in the registry: fetch the verified beneficiary's
    // ciphertext so the provider submission can carry the cleartext account while
    // the disbursement and payout rows only ever hold a fingerprint and a mask.
    const disbursement = await this.getDisbursement(context, disbursementId);
    if (!disbursement) throw new Error('GROUP_TREASURY_DISBURSEMENT_NOT_FOUND');
    if (!disbursement.externalBeneficiaryId) throw new Error('GROUP_TREASURY_NOT_EXTERNAL');

    const { data: beneficiary, error: beneficiaryError } = await supabase
      .from('group_treasury_beneficiaries')
      .select('id, destination_ciphertext, provider_name, provider_environment, state')
      .eq('organization_id', context.organizationId)
      .eq('group_id', context.groupId)
      .eq('id', disbursement.externalBeneficiaryId)
      .eq('state', 'verified')
      .maybeSingle();
    if (beneficiaryError) throw beneficiaryError;
    if (!beneficiary) throw new Error('GROUP_TREASURY_BENEFICIARY_NOT_VERIFIED');
    if (beneficiary.provider_name !== adapter.name
      || beneficiary.provider_environment !== adapter.environment) {
      throw new Error('GROUP_TREASURY_BENEFICIARY_PROVIDER_MISMATCH');
    }

    const { data: begun, error } = await supabase.rpc(
      'begin_group_treasury_external_disbursement',
      {
        p_organization_id: context.organizationId,
        p_disbursement_id: disbursementId,
        p_actor_id: context.actorId,
        p_provider_name: adapter.name,
        p_provider_environment: adapter.environment,
        p_correlation_id: correlationId(
          context, `treasury-external-begin:${disbursementId}`, input.idempotencyKey,
        ),
      },
    );
    if (error || !begun) throw error ?? new Error('GROUP_TREASURY_BEGIN_FAILED');

    const { data: payout, error: payoutError } = await supabase
      .from('payouts')
      .select('*')
      .eq('id', begun.payout_id)
      .eq('organization_id', context.organizationId)
      .single();
    if (payoutError || !payout) {
      throw payoutError ?? new Error('GROUP_TREASURY_PAYOUT_NOT_FOUND');
    }

    const destination = decryptGroupTreasuryDestination(beneficiary.destination_ciphertext);
    const submission = await payoutService.submitGroupTreasuryPayout({
      payout,
      organizationId: context.organizationId,
      actorId: context.actorId,
      accountNumber: destination.accountNumber,
      bankCode: destination.bankCode,
      accountName: destination.accountName,
    });
    return { disbursementId, payout: submission };
  }

  /**
   * Reconciles an in-flight external payout against the provider, applying a
   * success, failure, or late-success outcome through the shared payout stack.
   * This is how a provider timeout is resolved: the payout sits `processing`
   * until a sync (or an inbound webhook) reads the true state and settles it.
   */
  async syncExternalPayout(context: GroupTreasuryContext, disbursementId: string) {
    const disbursement = await this.getDisbursement(context, disbursementId);
    if (!disbursement) throw new Error('GROUP_TREASURY_DISBURSEMENT_NOT_FOUND');
    if (!disbursement.payoutId) throw new Error('GROUP_TREASURY_PAYOUT_NOT_FOUND');
    const { data: payout, error } = await supabase
      .from('payouts')
      .select('id, source_type')
      .eq('id', disbursement.payoutId)
      .eq('organization_id', context.organizationId)
      .eq('source_type', 'group_treasury')
      .single();
    if (error || !payout) throw error ?? new Error('GROUP_TREASURY_PAYOUT_NOT_FOUND');
    return payoutService.queryAndApply(payout.id);
  }
}

export default new GroupTreasuryDisbursementService();
