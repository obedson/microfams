import crypto from 'crypto';
import {
  configuredPayoutAdapter,
} from '../domains/financial/payoutAdapters.js';
import { payoutService } from '../domains/financial/payoutService.js';
import { PayoutDestination } from '../domains/financial/payoutTypes.js';
import { supabase } from '../utils/supabase.js';

const ERROR_MAPPING: ReadonlyArray<readonly [string, string, number]> = [
  ['BOOKING_PAYOUT_BENEFICIARY_INVALID', 'BOOKING_PAYOUT_BENEFICIARY_INVALID', 400],
  ['BOOKING_PAYOUT_BENEFICIARY_DECISION_INVALID', 'BOOKING_PAYOUT_BENEFICIARY_DECISION_INVALID', 400],
  ['BOOKING_PAYOUT_CHANGE_RULE_DECISION_INVALID', 'BOOKING_PAYOUT_CHANGE_RULE_DECISION_INVALID', 400],
  ['BOOKING_PAYOUT_CHANGE_RULE_INVALID', 'BOOKING_PAYOUT_CHANGE_RULE_INVALID', 400],
  ['BOOKING_SUPPLIER_PAYOUT_INVALID', 'BOOKING_SUPPLIER_PAYOUT_INVALID', 400],
  ['BOOKING_PAYOUT_NOT_AUTHORIZED', 'BOOKING_PAYOUT_NOT_AUTHORIZED', 403],
  ['BOOKING_PAYOUT_BENEFICIARY_MEMBERSHIP_INVALID', 'BOOKING_PAYOUT_BENEFICIARY_MEMBERSHIP_INVALID', 409],
  ['BOOKING_PAYOUT_RESOURCE_NOT_FOUND', 'BOOKING_PAYOUT_RESOURCE_NOT_FOUND', 404],
  ['BOOKING_PAYOUT_BENEFICIARY_NOT_FOUND', 'BOOKING_PAYOUT_BENEFICIARY_NOT_FOUND', 404],
  ['BOOKING_PAYOUT_CHANGE_RULE_NOT_FOUND', 'BOOKING_PAYOUT_CHANGE_RULE_NOT_FOUND', 404],
  ['BOOKING_SUPPLIER_PAYOUT_RELEASE_NOT_FOUND', 'BOOKING_SUPPLIER_PAYOUT_RELEASE_NOT_FOUND', 404],
  ['BOOKING_SUPPLIER_PAYOUT_NOT_FOUND', 'BOOKING_SUPPLIER_PAYOUT_NOT_FOUND', 404],
  ['BOOKING_PAYOUT_BENEFICIARY_NOT_VERIFIED', 'BOOKING_PAYOUT_BENEFICIARY_NOT_VERIFIED', 409],
  ['BOOKING_SUPPLIER_PAYOUT_HOLD_ACTIVE', 'BOOKING_SUPPLIER_PAYOUT_HOLD_ACTIVE', 409],
  ['BOOKING_SUPPLIER_PAYOUT_ALREADY_CREATED', 'BOOKING_SUPPLIER_PAYOUT_ALREADY_CREATED', 409],
  ['BOOKING_SUPPLIER_PAYOUT_CANCELLATION_NOT_ALLOWED', 'BOOKING_SUPPLIER_PAYOUT_CANCELLATION_NOT_ALLOWED', 409],
  ['BOOKING_SUPPLIER_PAYOUT_PROVIDER_MISMATCH', 'BOOKING_SUPPLIER_PAYOUT_PROVIDER_MISMATCH', 409],
  ['BOOKING_PAYOUT_BENEFICIARY_DECIDED', 'BOOKING_PAYOUT_BENEFICIARY_DECIDED', 409],
  ['BOOKING_PAYOUT_CHANGE_RULE_VERSION_CONFLICT', 'BOOKING_PAYOUT_CHANGE_RULE_VERSION_CONFLICT', 409],
  ['BOOKING_PAYOUT_CHANGE_RULE_DECIDED', 'BOOKING_PAYOUT_CHANGE_RULE_DECIDED', 409],
  ['MAKER_CHECKER_REQUIRED', 'MAKER_CHECKER_REQUIRED', 409],
  ['IDEMPOTENCY_REPLAY_CONFLICT', 'IDEMPOTENCY_REPLAY_CONFLICT', 409],
];

export class BookingSupplierPayoutError extends Error {
  constructor(readonly code: string, readonly status: number) {
    super(code);
  }
}

const mapError = (error: { message?: string } | null) => {
  const message = error?.message ?? '';
  const match = ERROR_MAPPING.find(([needle]) => message.includes(needle));
  return match
    ? new BookingSupplierPayoutError(match[1], match[2])
    : new BookingSupplierPayoutError('BOOKING_SUPPLIER_PAYOUT_FAILED', 503);
};

const authorizePayoutResource = async (
  organizationId: string,
  actorId: string,
  requiredPermission: 'booking.payouts.read' | 'booking.payouts.service',
  resourceType: string,
  resourceId: string,
) => {
  const { data, error } = await supabase.rpc(
    'authorize_booking_payout_resource',
    {
      p_organization_id: organizationId,
      p_actor_id: actorId,
      p_required_permission: requiredPermission,
      p_resource_type: resourceType,
      p_resource_id: resourceId,
    },
  );
  if (error || data !== true) throw mapError(error);
};

const encryptionKey = (configured = process.env.BOOKING_PAYOUT_DESTINATION_ENCRYPTION_KEY) => {
  if (!configured) {
    throw new BookingSupplierPayoutError(
      'BOOKING_PAYOUT_ENCRYPTION_NOT_CONFIGURED',
      503,
    );
  }
  const key = Buffer.from(configured, 'base64');
  if (key.length !== 32) {
    throw new BookingSupplierPayoutError(
      'BOOKING_PAYOUT_ENCRYPTION_NOT_CONFIGURED',
      503,
    );
  }
  return key;
};

export const encryptBookingPayoutDestination = (
  destination: PayoutDestination,
  configuredKey?: string,
) => {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv(
    'aes-256-gcm',
    encryptionKey(configuredKey),
    iv,
  );
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

export const decryptBookingPayoutDestination = (
  ciphertext: string,
  configuredKey?: string,
): PayoutDestination => {
  const [version, iv, tag, encrypted] = ciphertext.split('.');
  if (version !== 'v1' || !iv || !tag || !encrypted) {
    throw new BookingSupplierPayoutError(
      'BOOKING_PAYOUT_DESTINATION_INVALID',
      503,
    );
  }
  try {
    const decipher = crypto.createDecipheriv(
      'aes-256-gcm',
      encryptionKey(configuredKey),
      Buffer.from(iv, 'base64url'),
    );
    decipher.setAuthTag(Buffer.from(tag, 'base64url'));
    return JSON.parse(Buffer.concat([
      decipher.update(Buffer.from(encrypted, 'base64url')),
      decipher.final(),
    ]).toString('utf8'));
  } catch {
    throw new BookingSupplierPayoutError(
      'BOOKING_PAYOUT_DESTINATION_INVALID',
      503,
    );
  }
};

const fingerprint = (bankCode: string, accountNumber: string) =>
  crypto.createHash('sha256')
    .update(`${bankCode}:${accountNumber}`)
    .digest('hex');
const maskedAccount = (accountNumber: string) =>
  `******${accountNumber.slice(-4)}`;
const maskedName = (accountName: string) => {
  const value = accountName.trim();
  return value.length <= 4
    ? `${value.slice(0, 1)}***`
    : `${value.slice(0, 4)}****${value.slice(-2)}`;
};

export const bookingSupplierPayoutService = {
  async registerBeneficiary(input: {
    organizationId: string;
    actorId: string;
    beneficiaryUserId: string | null;
    accountNumber: string;
    bankCode: string;
    idempotencyKey: string;
  }) {
    await authorizePayoutResource(
      input.organizationId, input.actorId, 'booking.payouts.service',
      'organization', input.organizationId);
    const adapter = configuredPayoutAdapter();
    await payoutService.assertRoutingEnabled(
      adapter,
      input.organizationId,
      input.actorId,
    );
    const verified = await adapter.validateDestination(
      input.accountNumber,
      input.bankCode,
    );
    const destination: PayoutDestination = {
      accountNumber: input.accountNumber,
      bankCode: verified.bankCode,
      accountName: verified.accountName,
    };
    const destinationFingerprint = fingerprint(
      destination.bankCode,
      destination.accountNumber,
    );
    const verificationReference = `VRF-${crypto.createHash('sha256')
      .update(`${adapter.name}:${adapter.environment}:${destinationFingerprint}`)
      .digest('hex')
      .slice(0, 32)}`;
    const { data, error } = await supabase.rpc(
      'register_booking_payout_beneficiary',
      {
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_beneficiary_user_id: input.beneficiaryUserId,
        p_destination_ciphertext: encryptBookingPayoutDestination(destination),
        p_destination_fingerprint: destinationFingerprint,
        p_destination_masked: maskedAccount(destination.accountNumber),
        p_account_name_masked: maskedName(destination.accountName),
        p_provider_name: adapter.name,
        p_provider_environment: adapter.environment,
        p_verification_reference: verificationReference,
        p_idempotency_key: input.idempotencyKey,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },

  async decideBeneficiary(input: {
    beneficiaryId: string;
    organizationId: string;
    actorId: string;
    approve: boolean;
    reason: string;
    idempotencyKey: string;
  }) {
    await authorizePayoutResource(
      input.organizationId, input.actorId, 'booking.payouts.service',
      'booking_payout_beneficiary', input.beneficiaryId);
    const { data, error } = await supabase.rpc(
      'decide_booking_payout_beneficiary',
      {
        p_beneficiary_id: input.beneficiaryId,
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_approve: input.approve,
        p_reason: input.reason,
        p_idempotency_key: input.idempotencyKey,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },

  async listBeneficiaries(
    organizationId: string,
    actorId: string,
  ) {
    await authorizePayoutResource(
      organizationId, actorId, 'booking.payouts.read',
      'organization', organizationId);
    const { data, error } = await supabase.rpc(
      'read_booking_payout_beneficiaries',
      {
        p_organization_id: organizationId,
        p_actor_id: actorId,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },

  async proposeChangeRule(input: {
    organizationId: string;
    actorId: string;
    version: number;
    changeWindowHours: number;
    effectiveFrom: string;
    changeReason: string;
    idempotencyKey: string;
  }) {
    await authorizePayoutResource(
      input.organizationId, input.actorId, 'booking.payouts.service',
      'organization', input.organizationId);
    const { data, error } = await supabase.rpc(
      'propose_booking_payout_change_rule',
      {
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_version: input.version,
        p_change_window_hours: input.changeWindowHours,
        p_effective_from: input.effectiveFrom,
        p_change_reason: input.changeReason,
        p_idempotency_key: input.idempotencyKey,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },

  async decideChangeRule(input: {
    ruleId: string;
    organizationId: string;
    actorId: string;
    approve: boolean;
    reason: string;
    idempotencyKey: string;
  }) {
    await authorizePayoutResource(
      input.organizationId, input.actorId, 'booking.payouts.service',
      'booking_payout_change_rule', input.ruleId);
    const { data, error } = await supabase.rpc(
      'decide_booking_payout_change_rule',
      {
        p_rule_id: input.ruleId,
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_approve: input.approve,
        p_reason: input.reason,
        p_idempotency_key: input.idempotencyKey,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },

  async createAndSubmit(input: {
    settlementReleaseId: string;
    organizationId: string;
    actorId: string;
    beneficiaryId: string;
    idempotencyKey: string;
    correlationId: string;
  }) {
    await authorizePayoutResource(
      input.organizationId, input.actorId, 'booking.payouts.service',
      'booking_settlement_release', input.settlementReleaseId);
    const adapter = configuredPayoutAdapter();
    await payoutService.assertRoutingEnabled(
      adapter,
      input.organizationId,
      input.actorId,
    );
    const { data: beneficiary, error: beneficiaryError } = await supabase
      .from('booking_payout_beneficiaries')
      .select('*')
      .eq('id', input.beneficiaryId)
      .eq('organization_id', input.organizationId)
      .eq('state', 'verified')
      .single();
    if (beneficiaryError || !beneficiary) {
      throw new BookingSupplierPayoutError(
        'BOOKING_PAYOUT_BENEFICIARY_NOT_VERIFIED',
        409,
      );
    }
    if (beneficiary.provider_name !== adapter.name
      || beneficiary.provider_environment !== adapter.environment
    ) {
      throw new BookingSupplierPayoutError(
        'BOOKING_PAYOUT_PROVIDER_MISMATCH',
        409,
      );
    }
    const { data: created, error } = await supabase.rpc(
      'create_booking_supplier_payout',
      {
        p_settlement_release_id: input.settlementReleaseId,
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_beneficiary_id: input.beneficiaryId,
        p_provider_name: adapter.name,
        p_provider_environment: adapter.environment,
        p_idempotency_key: input.idempotencyKey,
        p_correlation_id: input.correlationId,
      },
    );
    if (error || !created) throw mapError(error);
    const { data: payout, error: payoutError } = await supabase
      .from('payouts')
      .select('*')
      .eq('id', created.payout_id)
      .eq('organization_id', input.organizationId)
      .single();
    if (payoutError || !payout) throw mapError(payoutError);
    return payoutService.submitBookingPayout({
      payout,
      organizationId: input.organizationId,
      actorId: input.actorId,
      ...decryptBookingPayoutDestination(
        beneficiary.destination_ciphertext,
      ),
    });
  },

  async read(payoutId: string, organizationId: string, actorId: string) {
    const { data, error } = await supabase.rpc(
      'read_booking_supplier_payout',
      {
        p_payout_id: payoutId,
        p_organization_id: organizationId,
        p_actor_id: actorId,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },

  async sync(payoutId: string, organizationId: string, actorId: string) {
    await authorizePayoutResource(
      organizationId, actorId, 'booking.payouts.service',
      'booking_supplier_payout', payoutId);
    const { data: payout, error } = await supabase
      .from('payouts')
      .select('id, organization_id, source_type')
      .eq('id', payoutId)
      .eq('organization_id', organizationId)
      .eq('source_type', 'booking_settlement')
      .single();
    if (error || !payout) {
      throw new BookingSupplierPayoutError(
        'BOOKING_SUPPLIER_PAYOUT_NOT_FOUND',
        404,
      );
    }
    return payoutService.queryAndApply(payout.id);
  },

  async cancel(input: {
    payoutId: string;
    organizationId: string;
    actorId: string;
    reason: string;
    idempotencyKey: string;
  }) {
    await authorizePayoutResource(
      input.organizationId, input.actorId, 'booking.payouts.service',
      'booking_supplier_payout', input.payoutId);
    const { data, error } = await supabase.rpc(
      'cancel_booking_supplier_payout',
      {
        p_payout_id: input.payoutId,
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_reason: input.reason,
        p_idempotency_key: input.idempotencyKey,
      },
    );
    if (error || !data) throw mapError(error);
    return data;
  },
};
