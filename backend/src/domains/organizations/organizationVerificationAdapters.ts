import crypto from 'node:crypto';
import {
  OrganizationVerificationAdapter,
  OrganizationVerificationOutcome,
  OrganizationVerificationResult,
  VerifyOrganizationCommand,
} from './organizationVerificationTypes.js';

const allowedOutcomes = new Set<OrganizationVerificationOutcome>(['verified', 'review_required', 'rejected']);

export class DeterministicOrganizationVerificationAdapter implements OrganizationVerificationAdapter {
  readonly name = 'deterministic';
  readonly environment = 'deterministic' as const;

  async verify(command: VerifyOrganizationCommand): Promise<OrganizationVerificationResult> {
    const configured = process.env.DETERMINISTIC_ORGANIZATION_VERIFICATION_OUTCOME as OrganizationVerificationOutcome | undefined;
    const requestedOutcome = configured && allowedOutcomes.has(configured) ? configured : 'verified';
    const outcome = command.registrationType === 'other' ? 'review_required' : requestedOutcome;
    const evidence = JSON.stringify({
      requestId: command.requestId,
      organizationId: command.organizationId,
      organizationType: command.organizationType,
      jurisdiction: command.jurisdiction,
      registrationType: command.registrationType,
      outcome,
    });
    return {
      providerReference: 'DET-ORG-' + crypto.createHash('sha256').update(command.requestId).digest('hex').slice(0, 24),
      outcome,
      evidenceHash: crypto.createHash('sha256').update(evidence).digest('hex'),
      reasonCode: outcome === 'verified' ? undefined : 'DETERMINISTIC_' + outcome.toUpperCase(),
    };
  }
}

export const configuredOrganizationVerificationAdapter = (): OrganizationVerificationAdapter => {
  const provider = process.env.ORGANIZATION_VERIFICATION_PROVIDER;
  if (provider === 'deterministic' && process.env.NODE_ENV !== 'production') {
    return new DeterministicOrganizationVerificationAdapter();
  }
  if (!provider && process.env.NODE_ENV !== 'production') {
    return new DeterministicOrganizationVerificationAdapter();
  }
  throw new Error('An approved organization verification provider has not been configured');
};
