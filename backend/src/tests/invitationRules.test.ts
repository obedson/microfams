import { canUseInvitation, invitationCorrelationId, invitationTokenDigest } from '../domains/groups/invitationRules.js';
describe('group invitation rules',()=>{
  it('hashes tokens without retaining the raw value',()=>{const token='a'.repeat(40);const value=invitationTokenDigest(token);expect(value).toMatch(/^[0-9a-f]{64}$/);expect(value).not.toContain(token);});
  it('derives stable command correlations',()=>{expect(invitationCorrelationId('scope:key')).toBe(invitationCorrelationId('scope:key'));expect(invitationCorrelationId('scope:key')).not.toBe(invitationCorrelationId('scope:other'));});
  it('allows only unexpired pending invitations',()=>{const now=new Date('2026-08-02T10:00:00Z');expect(canUseInvitation('pending',new Date('2026-08-02T11:00:00Z'),now)).toBe(true);expect(canUseInvitation('revoked',new Date('2026-08-02T11:00:00Z'),now)).toBe(false);expect(canUseInvitation('pending',now,now)).toBe(false);});
});
