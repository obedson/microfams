import { jest } from '@jest/globals';
import { DeterministicIdentityAdapter } from '../domains/identity/identityAdapters.js';
import { IdentityVerificationService } from '../domains/identity/identityVerificationService.js';
import {
  IdentityChallenge,
  IdentityVerificationAdapter,
  StartIdentityChallenge,
} from '../domains/identity/identityTypes.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({ supabase: { rpc: jest.fn() } }));

const startAdapter = jest.fn(async (_input: StartIdentityChallenge): Promise<IdentityChallenge> => {
  throw new Error('start adapter response not configured');
});
const confirmAdapter = jest.fn(async (_challengeToken: string, _otp: string): Promise<boolean> => false);

const adapter: IdentityVerificationAdapter = {

  name: 'deterministic',
  environment: 'deterministic',
  start: startAdapter,
  confirm: confirmAdapter,
};

const startInput = {
  organizationId: '00000000-0000-4000-8000-000000000101',
  userId: '00000000-0000-4000-8000-000000000102',
  evidenceType: 'nin' as const,
  identifier: '12345678901',
  firstName: 'Ada',
  lastName: 'Farmer',
  consentVersion: 'v1',
  consentTextHash: 'a'.repeat(64),
  idempotencyKey: 'identity-command-1',
};

describe('identity verification', () => {
  beforeEach(() => jest.clearAllMocks());

  it('uses a deterministic adapter without accepting arbitrary OTPs', async () => {
    const deterministic = new DeterministicIdentityAdapter();
    const challenge = await deterministic.start({
      requestId: 'request-1', evidenceType: 'nin', identifier: '12345678901',
      firstName: 'Ada', lastName: 'Farmer', consentAccepted: true,
    });
    expect(challenge.maskedDestination).toBe('0803****123');
    await expect(deterministic.confirm(challenge.challengeToken, '123456')).resolves.toBe(true);
    await expect(deterministic.confirm(challenge.challengeToken, '111111')).resolves.toBe(false);
    await expect(deterministic.confirm(challenge.challengeToken, '12345678')).resolves.toBe(false);
  });

  it('stores only a fingerprint and provider challenge metadata', async () => {
    (supabase.rpc as jest.Mock)
      .mockResolvedValueOnce({ data: {
        id: 'request-1', state: 'created', evidence_type: 'nin',
        provider_name: 'deterministic', provider_environment: 'deterministic',
        maximum_otp_attempts: 5, otp_attempts: 0,
      }, error: null } as never)
      .mockResolvedValueOnce({ data: {
        id: 'request-1', state: 'awaiting_otp', evidence_type: 'nin',
        provider_name: 'deterministic', provider_environment: 'deterministic',
        masked_destination: '0803****123', maximum_otp_attempts: 5, otp_attempts: 0,
      }, error: null } as never);
    startAdapter.mockResolvedValue({
      providerReference: 'provider-1', maskedDestination: '0803****123', challengeToken: 'opaque',
    } as never);

    const result = await new IdentityVerificationService(() => adapter).start(startInput);
    expect(result.state).toBe('awaiting_otp');
    const firstCall = (supabase.rpc as jest.Mock).mock.calls[0];
    expect(firstCall[0]).toBe('start_identity_verification');
    expect(firstCall[1]).not.toEqual(expect.objectContaining({ p_identifier: startInput.identifier }));
    expect(JSON.stringify(firstCall[1])).not.toContain(startInput.identifier);
  });

  it('records failed OTP attempts and never completes invalid challenges', async () => {
    (supabase.rpc as jest.Mock)
      .mockResolvedValueOnce({ data: {
        id: 'request-1', state: 'awaiting_otp', challenge_token: 'opaque',
        provider_name: 'deterministic', provider_environment: 'deterministic',
        provider_reference: 'provider-1',
      }, error: null } as never)
      .mockResolvedValueOnce({ data: { id: 'request-1', otp_attempts: 1 }, error: null } as never);
    confirmAdapter.mockResolvedValue(false);

    await expect(new IdentityVerificationService(() => adapter).confirm({
      organizationId: startInput.organizationId,
      userId: startInput.userId,
      requestId: 'request-1',
      otp: '000000',
    })).rejects.toThrow('Invalid or expired OTP');
    expect(supabase.rpc).toHaveBeenCalledWith('record_identity_otp_failure', { p_request_id: 'request-1' });
    expect(supabase.rpc).not.toHaveBeenCalledWith('complete_identity_verification', expect.anything());
  });

  it('rejects malformed identifiers before contacting a provider', async () => {
    await expect(new IdentityVerificationService(() => adapter).start({
      ...startInput, identifier: '123',
    })).rejects.toThrow('exactly 11 digits');
    expect(adapter.start).not.toHaveBeenCalled();
    expect(supabase.rpc).not.toHaveBeenCalled();
  });
});
