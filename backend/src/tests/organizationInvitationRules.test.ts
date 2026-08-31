import {
  organizationInvitationCorrelationId,
  organizationInvitationTokenDigest,
} from '../domains/organizations/organizationInvitationRules.js';

describe('organization invitation rules', () => {
  it('hashes invitation tokens without retaining the raw value', () => {
    const token = 'x'.repeat(43);
    const digest = organizationInvitationTokenDigest(token);

    expect(digest).toMatch(/^[0-9a-f]{64}$/);
    expect(digest).not.toContain(token);
    expect(organizationInvitationTokenDigest(token)).toBe(digest);
  });

  it('rejects malformed invitation tokens', () => {
    expect(() => organizationInvitationTokenDigest('short')).toThrow(
      'ORGANIZATION_INVITATION_TOKEN_INVALID',
    );
  });

  it('derives stable command correlation identifiers', () => {
    const scope = 'org-1:organization-invitation:request-1';
    expect(organizationInvitationCorrelationId(scope)).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(organizationInvitationCorrelationId(scope)).toBe(
      organizationInvitationCorrelationId(scope),
    );
  });
});
