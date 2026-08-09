import { SecurityService } from '../services/securityService.js';

describe('SecurityService TOTP', () => {
  // RFC 6238 SHA-1 test secret: ASCII "12345678901234567890".
  const rfcSecret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

  it('verifies the RFC 6238 value reduced to six digits', () => {
    expect(SecurityService.verifyTOTP(rfcSecret, '287082', 59_000, 0)).toBe(true);
  });

  it('accepts only the configured adjacent time window', () => {
    expect(SecurityService.verifyTOTP(rfcSecret, '287082', 89_000, 1)).toBe(true);
    expect(SecurityService.verifyTOTP(rfcSecret, '287082', 119_000, 1)).toBe(false);
  });

  it('rejects malformed tokens and secrets without a test bypass', () => {
    expect(SecurityService.verifyTOTP(rfcSecret, '123456', 59_000, 0)).toBe(false);
    expect(SecurityService.verifyTOTP(rfcSecret, '28708', 59_000, 0)).toBe(false);
    expect(SecurityService.verifyTOTP('not-base32', '287082', 59_000, 0)).toBe(false);
  });
});
