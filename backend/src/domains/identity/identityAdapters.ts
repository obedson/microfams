import crypto from 'node:crypto';
import { interswitchService } from '../../services/interswitchService.js';
import {
  IdentityChallenge,
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

export class DeterministicIdentityAdapter implements IdentityVerificationAdapter {
  readonly name = 'deterministic';
  readonly environment = 'deterministic' as const;

  async start(input: StartIdentityChallenge): Promise<IdentityChallenge> {
    return {
      providerReference: 'DET-' + crypto.createHash('sha256').update(input.requestId).digest('hex').slice(0, 24),
      maskedDestination: '0803****123',
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
    if (input.evidenceType !== 'nin') throw new Error('The configured provider does not support BVN verification');
    const response = await interswitchService.getNINFullDetails(input.identifier, input.consentAccepted);
    const info = response?.data;
    const phone = info?.mobile || info?.phone || info?.mobileNo || info?.telephone;
    if (!phone) throw new Error('Identity provider did not return an OTP destination');
    const otp = await interswitchService.sendOTP(phone, input.requestId);
    const providerReference = otp.reference || otp.otpreferenece;
    if (!providerReference) throw new Error('Identity provider did not return a challenge reference');
    return {
      providerReference,
      maskedDestination: String(phone).slice(0, 4) + '****' + String(phone).slice(-3),
      challengeToken: seal({ phone }),
    };
  }

  async confirm(challengeToken: string, otp: string): Promise<boolean> {
    const { phone } = open(challengeToken);
    return interswitchService.validateOTP(otp, phone);
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
