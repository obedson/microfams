import { normalizeEnvValue, resolveApiUrl } from './env.config';

describe('frontend environment configuration', () => {
  it('removes deployment whitespace from API URLs', () => {
    expect(resolveApiUrl(' https://micro-farmle.onrender.com/api ')).toBe('https://micro-farmle.onrender.com/api');
  });

  it('uses the local API fallback when configuration is empty', () => {
    expect(resolveApiUrl('   ')).toBe('http://localhost:3000/api');
  });

  it('normalizes optional environment values', () => {
    expect(normalizeEnvValue(' value ')).toBe('value');
    expect(normalizeEnvValue(undefined)).toBe('');
  });
});
