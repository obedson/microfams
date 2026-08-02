import { createHash } from 'crypto';

export type InvitationState = 'pending' | 'accepted' | 'revoked' | 'expired';
export const invitationTokenDigest = (token: string) => {
  if (!/^[A-Za-z0-9_-]{32,256}$/.test(token)) throw new Error('GROUP_INVITATION_TOKEN_INVALID');
  return createHash('sha256').update(token).digest('hex');
};
export const invitationCorrelationId = (scope: string) => {
  const h = createHash('sha256').update(scope).digest('hex');
  return `${h.slice(0,8)}-${h.slice(8,12)}-4${h.slice(13,16)}-a${h.slice(17,20)}-${h.slice(20,32)}`;
};
export const canUseInvitation = (state: InvitationState, expiresAt: Date, now: Date) =>
  state === 'pending' && expiresAt.getTime() > now.getTime();
