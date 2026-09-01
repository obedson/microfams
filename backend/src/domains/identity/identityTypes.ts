export type IdentityEvidenceType = 'nin' | 'bvn';
export type IdentityProviderEnvironment = 'deterministic' | 'sandbox' | 'live';

const identityNumberInKeyPattern = /[0-9]{11}/;

export const validateIdentityIdempotencyKey = (key: string, identifier: string, maximumLength = 160): void => {
  if (key !== key.trim() || key.length < 8 || key.length > maximumLength) {
    throw new Error(`Idempotency key must contain between 8 and ${maximumLength} non-whitespace characters`);
  }
  if (identityNumberInKeyPattern.test(key) || key.replace(/[^0-9]/g, '').includes(identifier)) {
    throw new Error('Idempotency key must be opaque and must not contain identity numbers');
  }
};

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
