import {
  SavingsProviderActivationGuard,
  SavingsProviderCertificationGateway,
  SavingsProviderCertificationService,
  SavingsProviderConfigurationError,
} from '../domains/financial/savingsProviderCertificationService.js';

const organizationId = '00000000-0000-4000-8000-000000000101';
const actorId = '00000000-0000-4000-8000-000000000102';
const certificationId = '00000000-0000-4000-8000-000000000103';
const hash = 'a'.repeat(64);
const now = new Date('2026-08-11T12:00:00.000Z');

const gateway = (): jest.Mocked<SavingsProviderCertificationGateway> => ({
  create: jest.fn(), recordScenario: jest.fn(), submit: jest.fn(), decide: jest.fn(),
  list: jest.fn(), readReadiness: jest.fn(),
});

const createCommand = {
  organizationId, actorId, providerCode: 'licensed.savings',
  providerLegalName: 'Licensed Savings Provider Limited', environment: 'sandbox' as const,
  jurisdiction: 'NG', currency: 'NGN', version: 1, configurationFingerprint: hash,
  providerContractReference: 'evidence/provider-contract',
  credentialsValidationReference: 'evidence/credential-validation',
  webhookCertificationReference: 'evidence/webhook-certification',
  settlementAccountReference: 'evidence/settlement-account',
  complianceNotesReference: 'evidence/compliance-notes',
  threatModelReference: 'evidence/threat-model',
  dataProtectionReviewReference: 'evidence/data-protection-review',
  supportRunbookReference: 'evidence/support-runbook',
  reconciliationSignoffReference: 'evidence/reconciliation-signoff',
  limitsDisclosuresReference: 'evidence/limits-disclosures',
  operationalOwnerId: actorId, validUntil: '2027-08-11T12:00:00.000Z',
  idempotencyKey: 'savings-certification-create-1',
};

describe('SavingsProviderCertificationService', () => {
  it('forwards a complete evidence set without accepting credential values', async () => {
    const storage = gateway();
    storage.create.mockResolvedValue({ id: certificationId });
    const service = new SavingsProviderCertificationService(storage, () => now);

    await expect(service.create(createCommand)).resolves.toEqual({ id: certificationId });
    expect(storage.create).toHaveBeenCalledWith(createCommand);
  });

  it('rejects malformed fingerprints and expired evidence before storage access', () => {
    const storage = gateway();
    const service = new SavingsProviderCertificationService(storage, () => now);

    expect(() => service.create({ ...createCommand, configurationFingerprint: 'secret-key' }))
      .toThrow('lowercase SHA-256');
    expect(() => service.create({ ...createCommand, validUntil: '2026-08-11T11:00:00.000Z' }))
      .toThrow('future');
    expect(storage.create).not.toHaveBeenCalled();
  });

  it('validates immutable scenario evidence and zero-variance semantics', async () => {
    const storage = gateway();
    storage.recordScenario.mockResolvedValue({ id: 'scenario-1' });
    const service = new SavingsProviderCertificationService(storage, () => now);
    const command = {
      organizationId, actorId, certificationId, scenarioCode: 'reconciliation_zero_variance' as const,
      attemptNumber: 1, result: 'passed' as const, unexplainedVarianceMinor: 0,
      evidenceReference: 'evidence/reconciliation-run', evidenceSha256: hash,
      startedAt: '2026-08-11T10:00:00.000Z', completedAt: '2026-08-11T10:05:00.000Z',
      idempotencyKey: 'savings-certification-scenario-1',
    };

    await expect(service.recordScenario(command)).resolves.toEqual({ id: 'scenario-1' });
    expect(() => service.recordScenario({
      ...command, scenarioCode: 'withdrawal_success', unexplainedVarianceMinor: 1,
    })).toThrow('Only reconciliation');
  });
});

describe('SavingsProviderActivationGuard', () => {
  it('allows deterministic test workflows but forbids deterministic production custody', async () => {
    const certification = { readiness: jest.fn() };
    const development = new SavingsProviderActivationGuard(certification as any, () => ({
      NODE_ENV: 'test', SAVINGS_PROVIDER_MODE: 'deterministic',
    }));
    await expect(development.assertNewExposureReady(organizationId, actorId)).resolves.toBeUndefined();
    expect(certification.readiness).not.toHaveBeenCalled();

    const production = new SavingsProviderActivationGuard(certification as any, () => ({
      NODE_ENV: 'production', SAVINGS_PROVIDER_MODE: 'deterministic',
    }));
    await expect(production.assertNewExposureReady(organizationId, actorId))
      .rejects.toMatchObject({ code: 'DETERMINISTIC_SAVINGS_PROVIDER_FORBIDDEN' });
  });

  it('fails closed when provider adapter configuration or certification is incomplete', async () => {
    const certification = { readiness: jest.fn().mockResolvedValue({
      ready: false, missing: ['certified_provider_configuration'],
    }) };
    const missingAdapter = new SavingsProviderActivationGuard(certification as any, () => ({
      NODE_ENV: 'staging', SAVINGS_PROVIDER_MODE: 'sandbox', SAVINGS_PROVIDER_CODE: 'licensed.savings',
      SAVINGS_PROVIDER_CONFIGURATION_FINGERPRINT: hash,
    }));
    await expect(missingAdapter.assertNewExposureReady(organizationId, actorId))
      .rejects.toMatchObject({ code: 'SAVINGS_PROVIDER_CONFIGURATION_INCOMPLETE', missing: ['provider_adapter'] });

    const uncertified = new SavingsProviderActivationGuard(certification as any, () => ({
      NODE_ENV: 'staging', SAVINGS_PROVIDER_MODE: 'sandbox', SAVINGS_PROVIDER_CODE: 'licensed.savings',
      SAVINGS_PROVIDER_ADAPTER_CODE: 'licensed.savings', SAVINGS_PROVIDER_CONFIGURATION_FINGERPRINT: hash,
      SAVINGS_PROVIDER_JURISDICTION: 'NG', SAVINGS_PROVIDER_CURRENCY: 'NGN',
    }));
    await expect(uncertified.assertNewExposureReady(organizationId, actorId))
      .rejects.toEqual(expect.objectContaining({
        code: 'SAVINGS_PROVIDER_NOT_READY', missing: ['certified_provider_configuration'],
      }));
  });

  it('allows a certified configuration and sends no credentials to readiness storage', async () => {
    const certification = { readiness: jest.fn().mockResolvedValue({ ready: true, missing: [] }) };
    const guard = new SavingsProviderActivationGuard(certification as any, () => ({
      NODE_ENV: 'production', SAVINGS_PROVIDER_MODE: 'live', SAVINGS_PROVIDER_CODE: 'licensed.savings',
      SAVINGS_PROVIDER_ADAPTER_CODE: 'licensed.savings', SAVINGS_PROVIDER_CONFIGURATION_FINGERPRINT: hash,
      SAVINGS_PROVIDER_JURISDICTION: 'NG', SAVINGS_PROVIDER_CURRENCY: 'NGN',
    }));
    await expect(guard.assertNewExposureReady(organizationId, actorId)).resolves.toBeUndefined();
    expect(certification.readiness).toHaveBeenCalledWith({
      organizationId, actorId, providerCode: 'licensed.savings', environment: 'live',
      jurisdiction: 'NG', currency: 'NGN', configurationFingerprint: hash,
    });
  });
});

test('SavingsProviderConfigurationError carries stable non-secret diagnostics', () => {
  const error = new SavingsProviderConfigurationError('Not ready', 'SAVINGS_PROVIDER_NOT_READY', ['certification']);
  expect(error).toMatchObject({ name: 'SavingsProviderConfigurationError', missing: ['certification'] });
});
