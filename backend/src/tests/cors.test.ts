import { configuredCorsOrigins, isCorsOriginAllowed } from '../config/cors.js';

describe('CORS origin policy', () => {
  it('allows non-browser requests and the production frontend', () => {
    expect(isCorsOriginAllowed(undefined)).toBe(true);
    expect(isCorsOriginAllowed('https://microfams.vercel.app')).toBe(true);
  });

  it('allows only the Micro Fams Vercel preview hostname pattern', () => {
    expect(isCorsOriginAllowed('https://microfams-git-agent-investment-refund-0b1c16-obedsons-projects.vercel.app')).toBe(true);
    expect(isCorsOriginAllowed('https://microfams-git-fix-signup-obedsons-projects.vercel.app')).toBe(true);
    expect(isCorsOriginAllowed('https://microfams-git-fix-signup-attacker-projects.vercel.app')).toBe(false);
    expect(isCorsOriginAllowed('https://microfams-git-fix-signup-obedsons-projects.vercel.app.evil.test')).toBe(false);
  });

  it('trims and normalizes configured origins', () => {
    const origins = configuredCorsOrigins(' https://staging.microfams.example/ ,http://localhost:4400 ');

    expect(origins.has('https://staging.microfams.example')).toBe(true);
    expect(origins.has('http://localhost:4400')).toBe(true);
  });

  it('ignores malformed configured origins and rejects malformed request origins', () => {
    const origins = configuredCorsOrigins('not-a-url,ftp://example.com');

    expect(origins.has('not-a-url')).toBe(false);
    expect(isCorsOriginAllowed('not-a-url', origins)).toBe(false);
  });
});
