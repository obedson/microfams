import { SavingsProviderCertificationController } from '../controllers/savingsProviderCertificationController.js';
import {
  SavingsProviderCertificationService,
  SavingsProviderConfigurationError,
} from '../domains/financial/savingsProviderCertificationService.js';
import { createRequireSavingsProviderReady } from '../middleware/requireSavingsProviderReady.js';

const organizationId = '00000000-0000-4000-8000-000000000101';
const actorId = '00000000-0000-4000-8000-000000000102';
const certificationId = '00000000-0000-4000-8000-000000000103';
const hash = 'a'.repeat(64);

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const service = () => ({
  create: jest.fn(), recordScenario: jest.fn(), submit: jest.fn(), decide: jest.fn(),
  list: jest.fn(), readiness: jest.fn(),
}) as unknown as jest.Mocked<SavingsProviderCertificationService>;

const completeBody = {
  providerCode: 'licensed.savings', providerLegalName: 'Licensed Savings Provider Limited',
  environment: 'sandbox', jurisdiction: 'NG', currency: 'NGN', version: 1,
  configurationFingerprint: hash, providerContractReference: 'evidence/provider-contract',
  credentialsValidationReference: 'evidence/credentials-check',
  webhookCertificationReference: 'evidence/webhook-check',
  settlementAccountReference: 'evidence/settlement-account',
  complianceNotesReference: 'evidence/compliance-notes', threatModelReference: 'evidence/threat-model',
  dataProtectionReviewReference: 'evidence/privacy-review', supportRunbookReference: 'evidence/runbook',
  reconciliationSignoffReference: 'evidence/reconciliation', limitsDisclosuresReference: 'evidence/disclosures',
  operationalOwnerId: actorId, validUntil: '2027-08-11T12:00:00.000Z',
  idempotencyKey: 'savings-certification-create-api-1',
};

describe('savings provider certification API', () => {
  it('binds certification evidence to the authenticated tenant and actor', async () => {
    const domain = service();
    domain.create.mockResolvedValue({ id: certificationId } as never);
    const controller = new SavingsProviderCertificationController(domain);
    const res = response();
    await controller.create({ tenant: { id: organizationId }, user: { id: actorId }, body: completeBody } as any, res);

    expect(domain.create).toHaveBeenCalledWith({ ...completeBody, organizationId, actorId });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects a raw credential in place of a configuration fingerprint', async () => {
    const domain = service();
    const controller = new SavingsProviderCertificationController(domain);
    const res = response();
    await controller.create({
      tenant: { id: organizationId }, user: { id: actorId },
      body: { ...completeBody, configurationFingerprint: 'raw-provider-credential-value' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.create).not.toHaveBeenCalled();
  });

  it('binds readiness to the tenant without accepting a tenant from the query', async () => {
    const domain = service();
    domain.readiness.mockResolvedValue({ ready: false, missing: ['live_activation'] } as never);
    const controller = new SavingsProviderCertificationController(domain);
    const res = response();
    const query = {
      providerCode: 'licensed.savings', environment: 'live', jurisdiction: 'NG',
      currency: 'NGN', configurationFingerprint: hash, organizationId: 'attacker-controlled',
    };
    await controller.readiness({ tenant: { id: organizationId }, user: { id: actorId }, query } as any, res);
    expect(domain.readiness).toHaveBeenCalledWith({
      providerCode: 'licensed.savings', environment: 'live', jurisdiction: 'NG', currency: 'NGN',
      configurationFingerprint: hash, organizationId, actorId,
    });
  });

  it('redacts storage errors during certification decisions', async () => {
    const domain = service();
    domain.decide.mockRejectedValue(new Error('database provider secret detail') as never);
    const controller = new SavingsProviderCertificationController(domain);
    const res = response();
    await controller.decide({
      tenant: { id: organizationId }, user: { id: actorId }, params: { certificationId },
      body: { approve: true, reason: 'Independent evidence review passed.', idempotencyKey: 'decision-api-1' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      message: expect.not.stringContaining('secret'),
    }));
  });
});

describe('savings acquisition readiness middleware', () => {
  it('continues only after the backend provider gate passes', async () => {
    const guard = { assertNewExposureReady: jest.fn().mockResolvedValue(undefined) };
    const middleware = createRequireSavingsProviderReady(guard as any);
    const next = jest.fn();
    await middleware({ tenant: { id: organizationId }, user: { id: actorId } } as any, response(), next);
    expect(guard.assertNewExposureReady).toHaveBeenCalledWith(organizationId, actorId);
    expect(next).toHaveBeenCalled();
  });

  it('fails closed with stable non-secret diagnostics', async () => {
    const error = new SavingsProviderConfigurationError(
      'not ready', 'SAVINGS_PROVIDER_NOT_READY', ['live_activation'],
    );
    const guard = { assertNewExposureReady: jest.fn().mockRejectedValue(error) };
    const middleware = createRequireSavingsProviderReady(guard as any);
    const res = response();
    const next = jest.fn();
    await middleware({ tenant: { id: organizationId }, user: { id: actorId } } as any, res, next);
    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'SAVINGS_PROVIDER_NOT_READY', missing: ['live_activation'],
    }));
    expect(next).not.toHaveBeenCalled();
  });
});
