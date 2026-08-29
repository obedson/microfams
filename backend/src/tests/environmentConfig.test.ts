import {
  ConfigurationValidationError,
  SECRET_INVENTORY,
  validateEnvironment,
} from '../config/environment.js';

const valid = (): NodeJS.ProcessEnv => ({
  NODE_ENV: 'test',
  PORT: '3000',
  SUPABASE_URL: 'http://127.0.0.1:54321',
  SUPABASE_SERVICE_KEY: 'synthetic-service-key',
  JWT_SECRET: 'synthetic-jwt-secret-with-32-characters',
});

describe('backend configuration validation', () => {
  it('returns typed, normalized core configuration', () => {
    const result = validateEnvironment({ ...valid(), PORT: '4100' });
    expect(result).toEqual(expect.objectContaining({ nodeEnv: 'test', port: 4100 }));
    expect(result.supabase.url).toBe('http://127.0.0.1:54321');
  });

  it('fails closed without exposing supplied secret values', () => {
    const secret = 'short-sensitive-value';
    expect.assertions(3);
    try {
      validateEnvironment({ ...valid(), SUPABASE_SERVICE_KEY: '', JWT_SECRET: secret });
    } catch (error) {
      expect(error).toBeInstanceOf(ConfigurationValidationError);
      expect(String(error)).toContain('SUPABASE_SERVICE_KEY');
      expect(String(error)).not.toContain(secret);
    }
  });

  it('requires production refresh, frontend, and non-default signing configuration', () => {
    expect(() => validateEnvironment({
      ...valid(),
      NODE_ENV: 'production',
      JWT_SECRET: 'your-secret-key',
      JWT_REFRESH_SECRET: '',
      FRONTEND_URL: '',
    })).toThrow(/JWT_SECRET.*JWT_REFRESH_SECRET.*FRONTEND_URL/);
  });

  it.each([
    ['NODE_ENV', 'unknown'],
    ['PORT', '70000'],
    ['SUPABASE_URL', 'file:///tmp/database'],
    ['FRONTEND_URL', 'not-a-url'],
  ])('rejects invalid %s values', (name, invalid) => {
    expect(() => validateEnvironment({ ...valid(), [name]: invalid })).toThrow(name);
  });

  it('publishes a unique value-free secret inventory', () => {
    const names = SECRET_INVENTORY.map(item => item.name);
    expect(new Set(names).size).toBe(names.length);
    expect(names).toEqual(expect.arrayContaining(['SUPABASE_SERVICE_KEY', 'JWT_SECRET', 'PAYSTACK_SECRET_KEY']));
    expect(JSON.stringify(SECRET_INVENTORY)).not.toContain('synthetic-jwt-secret');
  });
});
