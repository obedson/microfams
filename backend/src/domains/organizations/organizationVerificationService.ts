import crypto from 'node:crypto';
import { supabase } from '../../utils/supabase.js';
import { configuredOrganizationVerificationAdapter } from './organizationVerificationAdapters.js';
import {
  OrganizationRegistrationType,
  OrganizationVerificationAdapter,
  StartOrganizationVerificationInput,
} from './organizationVerificationTypes.js';

const registrationPattern = /^[A-Z0-9][A-Z0-9\/-]{3,63}$/;
const sha256 = (value: string): string => crypto.createHash('sha256').update(value).digest('hex');

const registrationAllowed = (organizationType: string, registrationType: OrganizationRegistrationType): boolean => {
  if (organizationType === 'government_program') return registrationType === 'government_program';
  if (organizationType === 'ngo') return registrationType === 'ngo_registration' || registrationType === 'cac_rc' || registrationType === 'other';
  return registrationType === 'cac_rc' || registrationType === 'cac_bn' || registrationType === 'other';
};

const fingerprint = (jurisdiction: string, registrationType: string, registrationNumber: string): string => {
  const configured = process.env.ORGANIZATION_REGISTRATION_FINGERPRINT_KEY;
  if (!configured && process.env.NODE_ENV === 'production') {
    throw new Error('Organization registration fingerprinting is not configured');
  }
  return crypto.createHmac('sha256', configured ?? 'development-only-organization-registration-key')
    .update(jurisdiction + ':' + registrationType + ':' + registrationNumber)
    .digest('hex');
};

const publicRequest = (request: any) => ({
  id: request.id,
  organizationId: request.organization_id,
  registrationType: request.registration_type,
  maskedRegistration: request.masked_registration,
  state: request.state,
  provider: request.provider_name,
  providerEnvironment: request.provider_environment,
  reasonCode: request.reason_code,
  submittedAt: request.created_at,
  decidedAt: request.decided_at,
  updatedAt: request.updated_at,
});

export class OrganizationVerificationService {
  constructor(private readonly adapterFactory: () => OrganizationVerificationAdapter = configuredOrganizationVerificationAdapter) {}

  async start(input: StartOrganizationVerificationInput) {
    const normalizedNumber = input.registrationNumber.trim().toUpperCase();
    if (!registrationPattern.test(normalizedNumber)) throw new Error('Registration number format is invalid');
    if (!registrationAllowed(input.organizationType, input.registrationType)) {
      throw new Error('Registration evidence type does not match the organization type');
    }
    if (!/^[A-Fa-f0-9]{64}$/.test(input.attestationTextHash)) throw new Error('Attestation text hash is invalid');
    if (!input.attestationVersion.trim()) throw new Error('Attestation version is required');
    if (input.idempotencyKey.length < 8) throw new Error('Idempotency key is too short');

    const adapter = this.adapterFactory();
    const registrationFingerprint = fingerprint(input.jurisdiction, input.registrationType, normalizedNumber);
    const requestHash = sha256(JSON.stringify({
      organizationId: input.organizationId,
      userId: input.userId,
      registrationType: input.registrationType,
      registrationFingerprint,
      attestationVersion: input.attestationVersion,
      attestationTextHash: input.attestationTextHash.toLowerCase(),
      provider: adapter.name,
      environment: adapter.environment,
    }));
    const maskedRegistration = normalizedNumber.length <= 6
      ? '*'.repeat(Math.max(0, normalizedNumber.length - 2)) + normalizedNumber.slice(-2)
      : normalizedNumber.slice(0, 2) + '*'.repeat(normalizedNumber.length - 6) + normalizedNumber.slice(-4);

    const { data: request, error } = await supabase.rpc('start_organization_verification', {
      p_organization_id: input.organizationId,
      p_user_id: input.userId,
      p_registration_type: input.registrationType,
      p_registration_fingerprint: registrationFingerprint,
      p_masked_registration: maskedRegistration,
      p_attestation_version: input.attestationVersion,
      p_attestation_text_hash: input.attestationTextHash.toLowerCase(),
      p_provider_name: adapter.name,
      p_provider_environment: adapter.environment,
      p_idempotency_key: input.idempotencyKey,
      p_request_hash: requestHash,
    });
    if (error || !request) throw error ?? new Error('Organization verification could not be created');
    if (request.state !== 'created') return publicRequest(request);

    try {
      const result = await adapter.verify({
        requestId: request.id,
        organizationId: input.organizationId,
        organizationName: input.organizationName,
        organizationType: input.organizationType,
        jurisdiction: input.jurisdiction,
        registrationType: input.registrationType,
        registrationNumber: normalizedNumber,
        authorityAttested: true,
      });
      const outcome = input.registrationType === 'other' ? 'review_required' : result.outcome;
      const reasonCode = input.registrationType === 'other'
        ? 'ALTERNATIVE_EVIDENCE_REQUIRES_REVIEW' : result.reasonCode;
      const { data: completed, error: completeError } = await supabase.rpc('complete_organization_verification', {
        p_request_id: request.id,
        p_provider_reference: result.providerReference,
        p_outcome: outcome,
        p_evidence_hash: result.evidenceHash,
        p_reason_code: reasonCode ?? null,
      });
      if (completeError || !completed) throw completeError ?? new Error('Organization verification result could not be recorded');
      return publicRequest(completed);
    } catch (providerError) {
      await supabase.rpc('fail_organization_verification', {
        p_request_id: request.id,
        p_reason_code: 'PROVIDER_VERIFICATION_FAILED',
      });
      throw providerError;
    }
  }

  async getCurrent(organizationId: string, userId: string) {
    const { data, error } = await supabase.rpc('get_organization_verification_status', {
      p_organization_id: organizationId,
      p_user_id: userId,
    });
    if (error) throw error;
    return data ? publicRequest(data) : null;
  }
}

export const organizationVerificationService = new OrganizationVerificationService();
