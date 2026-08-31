import crypto from 'node:crypto';
import { interswitchService } from '../../services/interswitchService.js';
import {
  IdentityChallenge,
  IdentityProviderUnavailableError,
  IdentityVerificationAdapter,
  StartIdentityChallenge,
} from './identityTypes.js';

const encryptionKey = (): Buffer => {
  const configured = process.env.IDENTITY_DATA_ENCRYPTION_KEY;
  if (!configured) throw new Error('Identity provider-state encryption is not configured');
  const key = Buffer.from(configured, 'base64');
  if (key.length !== 32) throw new Error('IDENTITY_DATA_ENCRYPTION_KEY must decode to 32 bytes');
  return key;
};

const seal = (value: object): string => {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', encryptionKey(), iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64');
};

const open = (token: string): { phone: string } => {
  const payload = Buffer.from(token, 'base64');
  if (payload.length < 29) throw new Error('Identity challenge is invalid');
  const decipher = crypto.createDecipheriv('aes-256-gcm', encryptionKey(), payload.subarray(0, 12));
  decipher.setAuthTag(payload.subarray(12, 28));
  return JSON.parse(Buffer.concat([decipher.update(payload.subarray(28)), decipher.final()]).toString('utf8'));
};

const normalizedPhone = (value: string): string => value.replace(/\D/g, '');
const comparablePhone = (value: string): string => normalizedPhone(value).slice(-10);
const maskedPhone = (value: string): string => {
  const digits = normalizedPhone(value);
  if (digits.length < 10) throw new Error('A valid registered phone is required for identity verification');
  return digits.slice(0, 4) + '****' + digits.slice(-3);
};

export class DeterministicIdentityAdapter implements IdentityVerificationAdapter {
  readonly name = 'deterministic';
  readonly environment = 'deterministic' as const;

  async start(input: StartIdentityChallenge): Promise<IdentityChallenge> {
    return {
      providerReference: 'DET-' + crypto.createHash('sha256').update(input.requestId).digest('hex').slice(0, 24),
      maskedDestination: maskedPhone(input.registeredPhone),
      challengeToken: crypto.createHash('sha256').update(input.requestId + ':' + input.evidenceType).digest('hex'),
    };
  }

  async confirm(_challengeToken: string, otp: string): Promise<boolean> {
    const expected = process.env.DETERMINISTIC_IDENTITY_OTP ?? '123456';
    if (otp.length !== expected.length) return false;
    return crypto.timingSafeEqual(
      Buffer.from(otp),
      Buffer.from(expected),
    );
  }
}

export class InterswitchIdentityAdapter implements IdentityVerificationAdapter {
  readonly name = 'interswitch';
  readonly environment = (process.env.IDENTITY_PROVIDER_ENVIRONMENT === 'live' ? 'live' : 'sandbox') as 'live' | 'sandbox';

  async start(input: StartIdentityChallenge): Promise<IdentityChallenge> {
    let response;
    try {
      response = input.evidenceType === 'bvn'
        ? await interswitchService.getBVNFullDetails(input.identifier)
        : await interswitchService.getNINFullDetails(input.identifier, input.consentAccepted);
    } catch {
      throw new IdentityProviderUnavailableError();
    }
    const info = response?.data;
    const providerPhone = info?.mobile || info?.phone || info?.mobileNo || info?.telephone;
    if (!providerPhone) throw new Error('Identity provider did not return a registered phone');
    if (comparablePhone(String(providerPhone)) !== comparablePhone(input.registeredPhone)) {
      throw new Error('Identity provider phone does not match the registered account phone');
    }
    let otp;
    try {
      otp = await interswitchService.sendOTP(input.registeredPhone, input.requestId);
    } catch {
      throw new IdentityProviderUnavailableError();
    }
    const providerReference = otp.reference || otp.otpreferenece;
    if (!providerReference) throw new Error('Identity provider did not return a challenge reference');
    return {
      providerReference,
      maskedDestination: maskedPhone(input.registeredPhone),
      challengeToken: seal({ phone: input.registeredPhone }),
    };
  }

  async confirm(challengeToken: string, otp: string): Promise<boolean> {
    const { phone } = open(challengeToken);
    try {
      return await interswitchService.validateOTP(otp, phone);
    } catch {
      throw new IdentityProviderUnavailableError();
    }
  }
}

export const configuredIdentityAdapter = (): IdentityVerificationAdapter => {
  const provider = process.env.IDENTITY_PROVIDER;
  if (provider === 'interswitch') return new InterswitchIdentityAdapter();
  if (provider === 'deterministic' || process.env.NODE_ENV !== 'production') {
    return new DeterministicIdentityAdapter();
  }
  throw new Error('A live identity verification provider has not been configured');
};
