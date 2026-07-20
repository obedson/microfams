import crypto from 'node:crypto';
import { supabase } from '../../utils/supabase.js';
import { configuredIdentityAdapter } from './identityAdapters.js';
import {
  ConfirmIdentityVerificationInput,
  IdentityVerificationAdapter,
  StartIdentityVerificationInput,
} from './identityTypes.js';

const identifierPattern = /^[0-9]{11}$/;
const sha256 = (value: string): string => crypto.createHash('sha256').update(value).digest('hex');

const fingerprint = (organizationId: string, evidenceType: string, identifier: string): string => {
  const configured = process.env.IDENTITY_FINGERPRINT_KEY;
  if (!configured && process.env.NODE_ENV === 'production') {
    throw new Error('Identity fingerprinting is not configured');
  }
  return crypto.createHmac('sha256', configured ?? 'development-only-identity-fingerprint-key')
    .update(organizationId + ':' + evidenceType + ':' + identifier)
    .digest('hex');
};

const publicRequest = (request: any) => ({
  id: request.id,
  evidenceType: request.evidence_type,
  state: request.state,
  provider: request.provider_name,
  providerEnvironment: request.provider_environment,
  maskedDestination: request.masked_destination,
  attemptsRemaining: Math.max(0, Number(request.maximum_otp_attempts) - Number(request.otp_attempts)),
  expiresAt: request.expires_at,
  createdAt: request.created_at,
  updatedAt: request.updated_at,
});

export class IdentityVerificationService {
  constructor(private readonly adapterFactory: () => IdentityVerificationAdapter = configuredIdentityAdapter) {}

  async start(input: StartIdentityVerificationInput) {
    if (!identifierPattern.test(input.identifier)) throw new Error('Identity number must contain exactly 11 digits');
    if (!/^[a-f0-9]{64}$/.test(input.consentTextHash)) throw new Error('Consent text hash is invalid');
    if (input.consentVersion.trim().length < 1) throw new Error('Consent version is required');
    if (input.idempotencyKey.length < 8) throw new Error('Idempotency key is too short');

    const adapter = this.adapterFactory();
    const identityFingerprint = fingerprint(input.organizationId, input.evidenceType, input.identifier);
    const requestHash = sha256(JSON.stringify({
      organizationId: input.organizationId,
      userId: input.userId,
      evidenceType: input.evidenceType,
      identityFingerprint,
      consentVersion: input.consentVersion,
      consentTextHash: input.consentTextHash,
      provider: adapter.name,
      environment: adapter.environment,
    }));
    const { data: request, error } = await supabase.rpc('start_identity_verification', {
      p_organization_id: input.organizationId,
      p_user_id: input.userId,
      p_evidence_type: input.evidenceType,
      p_identity_fingerprint: identityFingerprint,
      p_idempotency_key: input.idempotencyKey,
      p_request_hash: requestHash,
      p_consent_version: input.consentVersion,
      p_consent_text_hash: input.consentTextHash,
      p_provider_name: adapter.name,
      p_provider_environment: adapter.environment,
    });
    if (error || !request) throw error ?? new Error('Identity verification could not be created');
    if (request.state !== 'created') return publicRequest(request);

    try {
      const challenge = await adapter.start({
        requestId: request.id,
        evidenceType: input.evidenceType,
        identifier: input.identifier,
        firstName: input.firstName,
        lastName: input.lastName,
        consentAccepted: true,
      });
      const { data: awaitingOtp, error: updateError } = await supabase.rpc('mark_identity_challenge_sent', {
        p_request_id: request.id,
        p_provider_reference: challenge.providerReference,
        p_masked_destination: challenge.maskedDestination,
        p_challenge_token: challenge.challengeToken,
      });
      if (updateError || !awaitingOtp) throw updateError ?? new Error('Identity challenge state could not be recorded');
      return publicRequest(awaitingOtp);
    } catch (providerError) {
      await supabase.rpc('fail_identity_verification', {
        p_request_id: request.id,
        p_reason_code: 'PROVIDER_START_FAILED',
      });
      throw providerError;
    }
  }

  async confirm(input: ConfirmIdentityVerificationInput) {
    if (!/^[0-9]{4,8}$/.test(input.otp)) throw new Error('OTP format is invalid');
    const { data: request, error } = await supabase.rpc('get_identity_verification_for_confirmation', {
      p_request_id: input.requestId,
      p_organization_id: input.organizationId,
      p_user_id: input.userId,
    });
    if (error || !request) throw error ?? new Error('Identity verification request was not found');
    const adapter = this.adapterFactory();
    if (adapter.name !== request.provider_name || adapter.environment !== request.provider_environment) {
      throw new Error('Configured identity adapter does not match the verification request');
    }
    const valid = await adapter.confirm(request.challenge_token, input.otp);
    if (!valid) {
      const { error: attemptError } = await supabase.rpc('record_identity_otp_failure', {
        p_request_id: request.id,
      });
      if (attemptError) throw attemptError;
      throw new Error('Invalid or expired OTP');
    }
    const { data: completed, error: completeError } = await supabase.rpc('complete_identity_verification', {
      p_request_id: request.id,
    });
    if (completeError || !completed) throw completeError ?? new Error('Identity verification could not be completed');
    return publicRequest(completed);
  }
}

export const identityVerificationService = new IdentityVerificationService();
