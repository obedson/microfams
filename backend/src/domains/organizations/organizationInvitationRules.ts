import { createHash } from 'node:crypto';

export const organizationInvitationTokenDigest = (token: string) => {
  if (!/^[A-Za-z0-9_-]{32,256}$/.test(token)) {
    throw new Error('ORGANIZATION_INVITATION_TOKEN_INVALID');
  }
  return createHash('sha256').update(token).digest('hex');
};

export const organizationInvitationCorrelationId = (scope: string) => {
  const digest = createHash('sha256').update(scope).digest('hex');
  return [
    digest.slice(0, 8), digest.slice(8, 12), `4${digest.slice(13, 16)}`,
    `a${digest.slice(17, 20)}`, digest.slice(20, 32),
  ].join('-');
};
