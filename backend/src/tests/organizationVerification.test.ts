import { jest } from '@jest/globals';
import { DeterministicOrganizationVerificationAdapter } from '../domains/organizations/organizationVerificationAdapters.js';
import { OrganizationVerificationService } from '../domains/organizations/organizationVerificationService.js';
import {
  OrganizationVerificationAdapter,
  OrganizationVerificationResult,
  VerifyOrganizationCommand,
} from '../domains/organizations/organizationVerificationTypes.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({ supabase: { rpc: jest.fn() } }));

const verifyAdapter = jest.fn(async (_command: VerifyOrganizationCommand): Promise<OrganizationVerificationResult> => ({
  providerReference: 'provider-org-1',
  outcome: 'verified',
  evidenceHash: 'e'.repeat(64),
}));

const adapter: OrganizationVerificationAdapter = {
  name: 'deterministic',
  environment: 'deterministic',
  verify: verifyAdapter,
};

const input = {
  organizationId: '00000000-0000-4000-8000-000000000101',
  userId: '00000000-0000-4000-8000-000000000101',
  organizationName: 'Ada Farms',
  organizationType: 'farm_business' as const,
  jurisdiction: 'NG',
  registrationType: 'cac_rc' as const,
  registrationNumber: 'RC/1234567',
  attestationVersion: 'organization-verification-v1',
  attestationTextHash: 'a'.repeat(64),
  idempotencyKey: 'organization-verification-1',
};

describe('organization verification', () => {
  beforeEach(() => jest.clearAllMocks());

  it('provides deterministic, non-provider test evidence', async () => {
    const deterministic = new DeterministicOrganizationVerificationAdapter();
    const result = await deterministic.verify({
      requestId: 'request-1',
      organizationId: input.organizationId,
      organizationName: input.organizationName,
      organizationType: input.organizationType,
      jurisdiction: input.jurisdiction,
      registrationType: input.registrationType,
      registrationNumber: input.registrationNumber,
      authorityAttested: true,
    });
    expect(result.outcome).toBe('verified');
    expect(result.providerReference).toMatch(/^DET-ORG-/);
    expect(result.evidenceHash).toMatch(/^[a-f0-9]{64}$/);
    expect(JSON.stringify(result)).not.toContain(input.registrationNumber);
    const alternative = await deterministic.verify({
      requestId: 'request-2',
      organizationId: input.organizationId,
      organizationName: input.organizationName,
      organizationType: input.organizationType,
      jurisdiction: input.jurisdiction,
      registrationType: 'other',
      registrationNumber: 'ALT/1234',
      authorityAttested: true,
    });
    expect(alternative.outcome).toBe('review_required');
  });

  it('persists only a fingerprint, mask, and normalized provider evidence', async () => {
    (supabase.rpc as jest.Mock)
      .mockResolvedValueOnce({ data: {
        id: 'request-1',
        organization_id: input.organizationId,
        registration_type: 'cac_rc',
        masked_registration: 'RC/****4567',
        state: 'created',
        provider_name: 'deterministic',
        provider_environment: 'deterministic',
      }, error: null } as never)
      .mockResolvedValueOnce({ data: {
        id: 'request-1',
        organization_id: input.organizationId,
        registration_type: 'cac_rc',
        masked_registration: 'RC/****4567',
        state: 'verified',
        provider_name: 'deterministic',
        provider_environment: 'deterministic',
      }, error: null } as never);

    const result = await new OrganizationVerificationService(() => adapter).start(input);

    const startCall = (supabase.rpc as jest.Mock).mock.calls[0];
    expect(startCall[0]).toBe('start_organization_verification');
    expect(JSON.stringify(startCall[1])).not.toContain(input.registrationNumber);
    expect(startCall[1]).toEqual(expect.objectContaining({
      p_registration_fingerprint: expect.stringMatching(/^[a-f0-9]{64}$/),
      p_masked_registration: expect.stringContaining('*'),
    }));
    expect(verifyAdapter).toHaveBeenCalledWith(expect.objectContaining({
      registrationNumber: input.registrationNumber,
      authorityAttested: true,
    }));
    expect(JSON.stringify(result)).not.toContain(input.registrationNumber);
  });

  it('rejects incompatible evidence before storage or provider access', async () => {
    await expect(new OrganizationVerificationService(() => adapter).start({
      ...input,
      organizationType: 'government_program',
      registrationType: 'cac_rc',
    })).rejects.toThrow('does not match');
    expect(supabase.rpc).not.toHaveBeenCalled();
    expect(verifyAdapter).not.toHaveBeenCalled();
  });

  it('records a provider failure without creating verified evidence', async () => {
    (supabase.rpc as jest.Mock)
      .mockResolvedValueOnce({ data: {
        id: 'request-1',
        organization_id: input.organizationId,
        registration_type: 'cac_rc',
        masked_registration: 'RC/****4567',
        state: 'created',
        provider_name: 'deterministic',
        provider_environment: 'deterministic',
      }, error: null } as never)
      .mockResolvedValueOnce({ data: null, error: null } as never);
    verifyAdapter.mockRejectedValueOnce(new Error('provider unavailable'));

    await expect(new OrganizationVerificationService(() => adapter).start(input))
      .rejects.toThrow('provider unavailable');
    expect(supabase.rpc).toHaveBeenCalledWith('fail_organization_verification', {
      p_request_id: 'request-1',
      p_reason_code: 'PROVIDER_VERIFICATION_FAILED',
    });
    expect(supabase.rpc).not.toHaveBeenCalledWith(
      'complete_organization_verification',
      expect.anything(),
    );
  });
});
