import { OrganizationType } from '../../types/tenant.js';

export type OrganizationRegistrationType =
  | 'cac_rc'
  | 'cac_bn'
  | 'ngo_registration'
  | 'government_program'
  | 'other';

export type OrganizationVerificationEnvironment = 'deterministic' | 'sandbox' | 'live';
export type OrganizationVerificationOutcome = 'verified' | 'review_required' | 'rejected';

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
