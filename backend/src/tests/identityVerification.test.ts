import { jest } from '@jest/globals';
import axios from 'axios';
import { DeterministicIdentityAdapter, InterswitchIdentityAdapter } from '../domains/identity/identityAdapters.js';
import { interswitchService } from '../services/interswitchService.js';
import { IdentityVerificationService } from '../domains/identity/identityVerificationService.js';
import {
  IdentityChallenge,
  IdentityProviderUnavailableError,
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
  registeredPhone: '08031234123',
  firstName: 'Ada',
  lastName: 'Farmer',
  consentVersion: 'v1',
  consentTextHash: 'a'.repeat(64),
  idempotencyKey: 'identity-command-1',
};

describe('identity verification', () => {
  beforeEach(() => {
    jest.restoreAllMocks();
    jest.clearAllMocks();
  });

  it('uses a deterministic adapter without accepting arbitrary OTPs', async () => {
    const deterministic = new DeterministicIdentityAdapter();
    const challenge = await deterministic.start({
      requestId: 'request-1', evidenceType: 'nin', identifier: '12345678901', registeredPhone: '08031234123',
      firstName: 'Ada', lastName: 'Farmer', consentAccepted: true,
    });
    expect(challenge.maskedDestination).toBe('0803****123');
    await expect(deterministic.confirm(challenge.challengeToken, '123456')).resolves.toBe(true);
    await expect(deterministic.confirm(challenge.challengeToken, '111111')).resolves.toBe(false);
    await expect(deterministic.confirm(challenge.challengeToken, '12345678')).resolves.toBe(false);
  });

  it('rejects a provider phone that differs from the registered account phone', async () => {
    const providerLookup = jest.spyOn(interswitchService, 'getNINFullDetails').mockResolvedValue({
      data: { mobile: '08049999222' },
    } as never);
    const sendOtp = jest.spyOn(interswitchService, 'sendOTP');

    await expect(new InterswitchIdentityAdapter().start({
      requestId: 'request-provider-phone',
      evidenceType: 'nin',
      identifier: startInput.identifier,
      registeredPhone: startInput.registeredPhone,
      firstName: startInput.firstName,
      lastName: startInput.lastName,
      consentAccepted: true,
    })).rejects.toThrow('does not match the registered account phone');
    expect(providerLookup).toHaveBeenCalled();
    expect(sendOtp).not.toHaveBeenCalled();
  });

  it('routes BVN verification without retaining the provider profile', async () => {
    process.env.IDENTITY_DATA_ENCRYPTION_KEY = Buffer.alloc(32, 7).toString('base64');
    const providerLookup = jest.spyOn(interswitchService, 'getBVNFullDetails').mockResolvedValue({
      data: {
        mobile: startInput.registeredPhone,
        firstName: 'Sensitive',
        dateOfBirth: '1988-04-04',
        idNumber: startInput.identifier,
      },
    } as never);
    const ninLookup = jest.spyOn(interswitchService, 'getNINFullDetails');
    jest.spyOn(interswitchService, 'sendOTP').mockResolvedValue({
      reference: 'provider-bvn-reference',
    } as never);

    const challenge = await new InterswitchIdentityAdapter().start({
      requestId: 'request-bvn',
      evidenceType: 'bvn',
      identifier: startInput.identifier,
      registeredPhone: startInput.registeredPhone,
      firstName: startInput.firstName,
      lastName: startInput.lastName,
      consentAccepted: true,
    });

    expect(providerLookup).toHaveBeenCalledWith(startInput.identifier);
    expect(ninLookup).not.toHaveBeenCalled();
    expect(challenge).toEqual(expect.objectContaining({
      providerReference: 'provider-bvn-reference',
      maskedDestination: '0803****123',
    }));
    expect(JSON.stringify(challenge)).not.toContain(startInput.identifier);
    expect(JSON.stringify(challenge)).not.toContain('1988-04-04');
    delete process.env.IDENTITY_DATA_ENCRYPTION_KEY;
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

  it('derives the same platform fingerprint across organizations without exposing the identifier', async () => {
    const rpc = supabase.rpc as jest.Mock;
    rpc.mockResolvedValue({ data: {
      id: 'existing', state: 'failed', evidence_type: 'nin', provider_name: 'deterministic',
      provider_environment: 'deterministic', maximum_otp_attempts: 5, otp_attempts: 0,
    }, error: null } as never);

    const service = new IdentityVerificationService(() => adapter);
    await service.start(startInput);
    await service.start({ ...startInput, organizationId: '00000000-0000-4000-8000-000000000202' });

    const firstFacts = rpc.mock.calls[0][1] as any;
    const secondFacts = rpc.mock.calls[1][1] as any;
    expect(firstFacts.p_identity_fingerprint).toBe(secondFacts.p_identity_fingerprint);
    expect(JSON.stringify(firstFacts)).not.toContain(startInput.identifier);
    expect(JSON.stringify(secondFacts)).not.toContain(startInput.identifier);
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

  it('rejects an invalid registered phone before creating evidence', async () => {
    await expect(new IdentityVerificationService(() => adapter).start({
      ...startInput, registeredPhone: '123',
    })).rejects.toThrow('valid registered phone');
    expect(adapter.start).not.toHaveBeenCalled();
    expect(supabase.rpc).not.toHaveBeenCalled();
  });

  it('maps provider transport failures to a provider-neutral error', async () => {
    jest.spyOn(interswitchService, 'getNINFullDetails')
      .mockRejectedValue(new Error('upstream host and token detail'));

    const result = new InterswitchIdentityAdapter().start({
      requestId: 'request-provider-outage',
      evidenceType: 'nin',
      identifier: startInput.identifier,
      registeredPhone: startInput.registeredPhone,
      firstName: startInput.firstName,
      lastName: startInput.lastName,
      consentAccepted: true,
    });
    await expect(result).rejects.toBeInstanceOf(IdentityProviderUnavailableError);
    await expect(result).rejects.not.toThrow('upstream host and token detail');
  });

  it('distinguishes an authoritative invalid OTP from provider unavailability', async () => {
    jest.spyOn(interswitchService, 'getAccessToken').mockResolvedValue('provider-token');
    const providerRequest = jest.spyOn(axios, 'post');

    providerRequest.mockResolvedValueOnce({ data: { status: 'FAILED', responseCode: '01' } } as never);
    await expect(interswitchService.validateOTP('000000', startInput.registeredPhone))
      .resolves.toBe(false);

    const providerLog = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    providerRequest.mockRejectedValueOnce(new Error('upstream host and token detail'));
    await expect(interswitchService.validateOTP('123456', startInput.registeredPhone))
      .rejects.toThrow('OTP validation is temporarily unavailable');
    expect(providerLog).toHaveBeenCalledWith('Interswitch OTP validation request failed');
    expect(JSON.stringify(providerLog.mock.calls)).not.toContain('upstream host and token detail');
  });

  it('maps OTP validation outages to the provider-neutral unavailable error', async () => {
    process.env.IDENTITY_DATA_ENCRYPTION_KEY = Buffer.alloc(32, 7).toString('base64');
    jest.spyOn(interswitchService, 'getNINFullDetails').mockResolvedValue({
      data: { mobile: startInput.registeredPhone },
    } as never);
    jest.spyOn(interswitchService, 'sendOTP').mockResolvedValue({ reference: 'provider-otp-reference' } as never);
    const validateOtp = jest.spyOn(interswitchService, 'validateOTP')
      .mockRejectedValue(new Error('OTP validation is temporarily unavailable'));
    const adapter = new InterswitchIdentityAdapter();
    const challenge = await adapter.start({
      requestId: 'request-confirm-outage',
      evidenceType: 'nin',
      identifier: startInput.identifier,
      registeredPhone: startInput.registeredPhone,
      firstName: startInput.firstName,
      lastName: startInput.lastName,
      consentAccepted: true,
    });

    await expect(adapter.confirm(challenge.challengeToken, '123456'))
      .rejects.toBeInstanceOf(IdentityProviderUnavailableError);
    expect(validateOtp).toHaveBeenCalledWith('123456', startInput.registeredPhone);
    delete process.env.IDENTITY_DATA_ENCRYPTION_KEY;
  });

  it('marks provider-start outages terminal and returns a sanitized retry instruction', async () => {
    (supabase.rpc as jest.Mock)
      .mockResolvedValueOnce({ data: {
        id: 'request-start-outage', state: 'created', evidence_type: 'nin',
        provider_name: 'deterministic', provider_environment: 'deterministic',
        maximum_otp_attempts: 5, otp_attempts: 0,
      }, error: null } as never)
      .mockResolvedValueOnce({ data: { id: 'request-start-outage' }, error: null } as never);
    startAdapter.mockRejectedValue(new IdentityProviderUnavailableError());

    await expect(new IdentityVerificationService(() => adapter).start(startInput))
      .rejects.toThrow('start a new verification request');
    expect(supabase.rpc).toHaveBeenCalledWith('fail_identity_verification', {
      p_request_id: 'request-start-outage',
      p_reason_code: 'PROVIDER_START_UNAVAILABLE',
    });
  });

  it('audits a provider outage and completes a later confirmation retry', async () => {
    const active = {
      id: 'request-retry', state: 'awaiting_otp', challenge_token: 'opaque',
      provider_name: 'deterministic', provider_environment: 'deterministic',
      evidence_type: 'nin', maximum_otp_attempts: 5, otp_attempts: 0,
    };
    (supabase.rpc as jest.Mock)
      .mockResolvedValueOnce({ data: active, error: null } as never)
      .mockResolvedValueOnce({ data: active, error: null } as never)
      .mockResolvedValueOnce({ data: active, error: null } as never)
      .mockResolvedValueOnce({ data: { ...active, state: 'validated' }, error: null } as never);
    confirmAdapter
      .mockRejectedValueOnce(new IdentityProviderUnavailableError())
      .mockResolvedValueOnce(true);
    const service = new IdentityVerificationService(() => adapter);
    const command = {
      organizationId: startInput.organizationId,
      userId: startInput.userId,
      requestId: 'request-retry',
      otp: '123456',
    };

    await expect(service.confirm(command))
      .rejects.toThrow('retry confirmation before the challenge expires');
    await expect(service.confirm(command)).resolves.toEqual(
      expect.objectContaining({ id: 'request-retry', state: 'validated' }),
    );
    expect(supabase.rpc).toHaveBeenCalledWith('record_identity_provider_deferred', {
      p_request_id: 'request-retry',
    });
    expect(supabase.rpc).not.toHaveBeenCalledWith(
      'record_identity_otp_failure', expect.anything(),
    );
  });
});
