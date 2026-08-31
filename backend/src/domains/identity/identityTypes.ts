export type IdentityEvidenceType = 'nin' | 'bvn';
export type IdentityProviderEnvironment = 'deterministic' | 'sandbox' | 'live';

export class IdentityProviderUnavailableError extends Error {
  readonly code = 'IDENTITY_PROVIDER_UNAVAILABLE';

  constructor() {
    super('Identity provider is temporarily unavailable');
    this.name = 'IdentityProviderUnavailableError';
  }
}

export interface StartIdentityChallenge {
  requestId: string;
  evidenceType: IdentityEvidenceType;
  identifier: string;
  registeredPhone: string;
  firstName: string;
  lastName: string;
  consentAccepted: true;
}

export interface IdentityChallenge {
  providerReference: string;
  maskedDestination: string;
  challengeToken: string;
}

export interface IdentityVerificationAdapter {
  readonly name: string;
  readonly environment: IdentityProviderEnvironment;
  start(input: StartIdentityChallenge): Promise<IdentityChallenge>;
  confirm(challengeToken: string, otp: string): Promise<boolean>;
}

export interface StartIdentityVerificationInput {
  organizationId: string;
  userId: string;
  evidenceType: IdentityEvidenceType;
  identifier: string;
  registeredPhone: string;
  firstName: string;
  lastName: string;
  consentVersion: string;
  consentTextHash: string;
  idempotencyKey: string;
}

export interface ConfirmIdentityVerificationInput {
  organizationId: string;
  userId: string;
  requestId: string;
  otp: string;
}
