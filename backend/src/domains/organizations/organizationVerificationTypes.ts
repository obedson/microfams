import { OrganizationType } from '../../types/tenant.js';

export type OrganizationRegistrationType =
  | 'cac_rc'
  | 'cac_bn'
  | 'ngo_registration'
  | 'government_program'
  | 'other';

export type OrganizationVerificationEnvironment = 'deterministic' | 'sandbox' | 'live';
export type OrganizationVerificationOutcome = 'verified' | 'review_required' | 'rejected';

export const validateOrganizationIdempotencyKey = (
  key: string,
  registrationNumber: string,
  maximumLength = 160,
): void => {
  if (key !== key.trim() || key.length < 8 || key.length > maximumLength) {
    throw new Error('Idempotency key must contain between 8 and ' + maximumLength + ' non-whitespace characters');
  }
  const normalizedRegistration = registrationNumber.replace(/[^A-Z0-9]/gi, '').toUpperCase();
  const normalizedKey = key.replace(/[^A-Z0-9]/gi, '').toUpperCase();
  if (normalizedRegistration && normalizedKey.includes(normalizedRegistration)) {
    throw new Error('Idempotency key must be opaque and must not contain registration identifiers');
  }
};

export interface VerifyOrganizationCommand {
  requestId: string;
  organizationId: string;
  organizationName: string;
  organizationType: OrganizationType;
  jurisdiction: string;
  registrationType: OrganizationRegistrationType;
  registrationNumber: string;
  authorityAttested: true;
}

export interface OrganizationVerificationResult {
  providerReference: string;
  outcome: OrganizationVerificationOutcome;
  evidenceHash: string;
  reasonCode?: string;
}

export interface OrganizationVerificationAdapter {
  readonly name: string;
  readonly environment: OrganizationVerificationEnvironment;
  verify(command: VerifyOrganizationCommand): Promise<OrganizationVerificationResult>;
}

export interface StartOrganizationVerificationInput {
  organizationId: string;
  userId: string;
  organizationName: string;
  organizationType: OrganizationType;
  jurisdiction: string;
  registrationType: OrganizationRegistrationType;
  registrationNumber: string;
  attestationVersion: string;
  attestationTextHash: string;
  idempotencyKey: string;
}
