import dotenv from 'dotenv';

dotenv.config();

export type RuntimeEnvironment = 'development' | 'test' | 'staging' | 'production';
export type SecretRequirement = 'always' | 'production' | 'provider-dependent';

export interface SecretInventoryItem {
  name: string;
  requirement: SecretRequirement;
  purpose: string;
}

export const SECRET_INVENTORY: readonly SecretInventoryItem[] = Object.freeze([
  { name: 'SUPABASE_SERVICE_KEY', requirement: 'always', purpose: 'Tenant database service access' },
  { name: 'JWT_SECRET', requirement: 'always', purpose: 'Access-token and signed-preview integrity' },
  { name: 'JWT_REFRESH_SECRET', requirement: 'production', purpose: 'Refresh-token integrity' },
  { name: 'PAYSTACK_SECRET_KEY', requirement: 'provider-dependent', purpose: 'Paystack API and webhook verification' },
  { name: 'INTERSWITCH_CLIENT_SECRET', requirement: 'provider-dependent', purpose: 'Interswitch API authentication' },
  { name: 'INTERSWITCH_WEBHOOK_SECRET', requirement: 'provider-dependent', purpose: 'Interswitch webhook verification' },
  { name: 'AWS_ACCESS_KEY_ID', requirement: 'provider-dependent', purpose: 'Object-storage access identity' },
  { name: 'AWS_SECRET_ACCESS_KEY', requirement: 'provider-dependent', purpose: 'Object-storage access secret' },
  { name: 'BREVO_API_KEY', requirement: 'provider-dependent', purpose: 'Transactional email delivery' },
  { name: 'IDENTITY_FINGERPRINT_KEY', requirement: 'provider-dependent', purpose: 'Non-reversible identity evidence fingerprinting' },
  { name: 'IDENTITY_DATA_ENCRYPTION_KEY', requirement: 'provider-dependent', purpose: 'Identity evidence encryption' },
  { name: 'ORGANIZATION_REGISTRATION_FINGERPRINT_KEY', requirement: 'provider-dependent', purpose: 'Non-reversible organization registration fingerprinting' },
  { name: 'ONEPIPE_API_KEY', requirement: 'provider-dependent', purpose: 'OnePipe API authentication' },
  { name: 'ONEPIPE_SECRET', requirement: 'provider-dependent', purpose: 'OnePipe request signing' },
  { name: 'LOAN_DISBURSEMENT_DESTINATION_ENCRYPTION_KEY', requirement: 'provider-dependent', purpose: 'Loan destination encryption' },
  { name: 'BOOKING_PAYOUT_DESTINATION_ENCRYPTION_KEY', requirement: 'provider-dependent', purpose: 'Booking payout destination encryption' },
  { name: 'GROUP_TREASURY_DESTINATION_ENCRYPTION_KEY', requirement: 'provider-dependent', purpose: 'Treasury destination encryption' },
]);

export interface BackendConfiguration {
  nodeEnv: RuntimeEnvironment;
  port: number;
  supabase: { url: string; serviceKey: string };
  jwt: { secret: string; refreshSecret?: string };
  frontendUrl?: string;
}

export class ConfigurationValidationError extends Error {
  constructor(readonly issues: readonly string[]) {
    super('Invalid backend configuration: ' + issues.join('; '));
    this.name = 'ConfigurationValidationError';
  }
}

const value = (source: NodeJS.ProcessEnv, name: string): string | undefined => {
  const candidate = source[name]?.trim();
  return candidate ? candidate : undefined;
};

const httpUrl = (candidate: string | undefined): boolean => {
  if (!candidate) return false;
  try {
    return ['http:', 'https:'].includes(new URL(candidate).protocol);
  } catch {
    return false;
  }
};

export const validateEnvironment = (source: NodeJS.ProcessEnv = process.env): BackendConfiguration => {
  const issues: string[] = [];
  const nodeEnv = value(source, 'NODE_ENV') ?? 'development';
  const allowed = ['development', 'test', 'staging', 'production'] as const;
  if (!allowed.includes(nodeEnv as RuntimeEnvironment)) issues.push('NODE_ENV must be development, test, staging, or production');

  const portValue = value(source, 'PORT') ?? '3000';
  const port = Number(portValue);
  if (!Number.isInteger(port) || port < 1 || port > 65535) issues.push('PORT must be an integer from 1 to 65535');

  const supabaseUrl = value(source, 'SUPABASE_URL');
  const supabaseServiceKey = value(source, 'SUPABASE_SERVICE_KEY');
  const jwtSecret = value(source, 'JWT_SECRET');
  const refreshSecret = value(source, 'JWT_REFRESH_SECRET');
  const frontendUrl = value(source, 'FRONTEND_URL');

  if (!httpUrl(supabaseUrl)) issues.push('SUPABASE_URL must be an HTTP(S) URL');
  if (!supabaseServiceKey) issues.push('SUPABASE_SERVICE_KEY is required');
  if (!jwtSecret || jwtSecret.length < 32 || ['your-secret-key', 'fallback-secret'].includes(jwtSecret)) {
    issues.push('JWT_SECRET must be a non-default value of at least 32 characters');
  }
  if (nodeEnv === 'production' && (!refreshSecret || refreshSecret.length < 32)) {
    issues.push('JWT_REFRESH_SECRET must contain at least 32 characters in production');
  }
  if (frontendUrl && !httpUrl(frontendUrl)) issues.push('FRONTEND_URL must be an HTTP(S) URL');
  if (nodeEnv === 'production' && !frontendUrl) issues.push('FRONTEND_URL is required in production');

  if (issues.length) throw new ConfigurationValidationError(issues);
  return Object.freeze({
    nodeEnv: nodeEnv as RuntimeEnvironment,
    port,
    supabase: Object.freeze({ url: supabaseUrl!, serviceKey: supabaseServiceKey! }),
    jwt: Object.freeze({ secret: jwtSecret!, refreshSecret }),
    frontendUrl,
  });
};

export const backendConfiguration = validateEnvironment();
