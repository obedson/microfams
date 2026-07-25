import crypto from 'node:crypto';
import { supabase } from '../../utils/supabase.js';
import { sendEmail } from '../../services/emailService.js';

export class SuspendedRecoveryError extends Error {
  constructor(readonly code: string, readonly status: number) { super(code); }
}

export interface RecoveryDelivery {
  send(input: { destination: string; name: string; token: string; expiresAt: string }): Promise<void>;
}

export interface RecoveryRepository {
  findEligible(email: string): Promise<{ userId: string; email: string; name: string; caseId: string } | null>;
  issue(input: { userId: string; caseId: string; digest: string; expiresAt: string }): Promise<{ tokenId: string }>;
  invalidate(tokenId: string, reasonCode: string): Promise<void>;
  inspect(digest: string): Promise<unknown>;
  fileAppeal(digest: string, grounds: string, idempotencyKey: string, requestHash: string): Promise<unknown>;
}

const rpc = async (name: string, args: Record<string, unknown>) => {
  const { data, error } = await supabase.rpc(name, args);
  if (error || data === null) throw error ?? new Error('Recovery operation failed');
  return data as any;
};

export class SupabaseRecoveryRepository implements RecoveryRepository {
  async findEligible(email: string) {
    const { data: user } = await supabase.from('users').select('id,email,name,is_suspended')
      .eq('email', email).eq('is_suspended', true).maybeSingle();
    if (!user) return null;
    const { data: cases } = await supabase.from('trust_review_cases').select('id')
      .eq('subject_type', 'user').eq('subject_id', user.id).eq('status', 'decided')
      .order('decided_at', { ascending: false }).limit(10);
    for (const item of cases ?? []) {
      const { data: decision } = await supabase.from('trust_review_decisions').select('id')
        .eq('case_id', item.id).eq('outcome', 'suspend_user').maybeSingle();
      if (decision) return { userId: user.id, email: user.email, name: user.name, caseId: item.id };
    }
    return null;
  }
  issue(input: { userId: string; caseId: string; digest: string; expiresAt: string }) {
    return rpc('issue_suspended_account_recovery', { p_user: input.userId, p_case: input.caseId,
      p_token_digest: input.digest, p_channel: 'email', p_expires_at: input.expiresAt });
  }
  async invalidate(tokenId: string, reasonCode: string) {
    await rpc('invalidate_suspended_account_recovery', { p_token: tokenId, p_reason_code: reasonCode });
  }
  inspect(digest: string) { return rpc('inspect_suspended_account_recovery', { p_token_digest: digest }); }
  fileAppeal(digest: string, grounds: string, idempotencyKey: string, requestHash: string) {
    return rpc('file_suspended_account_recovery_appeal', { p_token_digest: digest, p_grounds: grounds,
      p_idempotency_key: idempotencyKey, p_request_hash: requestHash });
  }
}

export class EmailRecoveryDelivery implements RecoveryDelivery {
  async send(input: { destination: string; name: string; token: string; expiresAt: string }) {
    if (!process.env.BREVO_API_KEY) throw new Error('Recovery email provider is not configured');
    const base = process.env.FRONTEND_URL || 'http://localhost:3001';
    const url = `${base}/trust/recovery?token=${encodeURIComponent(input.token)}`;
    await sendEmail({ to: input.destination, subject: 'Review your Micro Fams account suspension', html:
      `<p>Hello ${escapeHtml(input.name)},</p><p>Use this single-purpose link to review and appeal your account suspension.</p><p><a href="${url}">Review suspension</a></p><p>The link expires at ${escapeHtml(input.expiresAt)} and cannot be used to sign in.</p>`, throwOnFailure: true });
  }
}

const escapeHtml = (value: string) => value.replace(/[&<>'"]/g, (c) => ({ '&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;' }[c]!));
const digest = (token: string) => crypto.createHash('sha256').update(token).digest('hex');
const normalizeEmail = (email: string) => email.trim().toLowerCase();
const validateToken = (token: string) => {
  const value = token.trim();
  if (!/^[A-Za-z0-9_-]{40,100}$/.test(value)) throw new SuspendedRecoveryError('INVALID_RECOVERY_TOKEN', 400);
  return value;
};

export class SuspendedAccountRecoveryService {
  constructor(private readonly repository: RecoveryRepository, private readonly delivery: RecoveryDelivery) {}
  async request(email: string): Promise<void> {
    try {
      const eligible = await this.repository.findEligible(normalizeEmail(email));
      if (!eligible) return;
      const token = crypto.randomBytes(32).toString('base64url');
      const expiresAt = new Date(Date.now() + 15 * 60_000).toISOString();
      const issued = await this.repository.issue({ userId: eligible.userId, caseId: eligible.caseId,
        digest: digest(token), expiresAt });
      try { await this.delivery.send({ destination: eligible.email, name: eligible.name, token, expiresAt }); }
      catch { await this.repository.invalidate(issued.tokenId, 'DELIVERY_FAILED'); }
    } catch { /* Enumeration-resistant public response. */ }
  }
  async inspect(token: string) {
    try { return await this.repository.inspect(digest(validateToken(token))); }
    catch (error) { if (error instanceof SuspendedRecoveryError) throw error; throw new SuspendedRecoveryError('INVALID_OR_EXPIRED_RECOVERY_TOKEN', 404); }
  }
  async fileAppeal(token: string, grounds: string, idempotencyKey: string) {
    const cleanGrounds = grounds.trim();
    if (cleanGrounds.length < 10 || cleanGrounds.length > 4000) throw new SuspendedRecoveryError('INVALID_APPEAL_GROUNDS', 400);
    if (idempotencyKey.trim().length < 8 || idempotencyKey.length > 160) throw new SuspendedRecoveryError('IDEMPOTENCY_KEY_REQUIRED', 400);
    const requestHash = crypto.createHash('sha256').update(JSON.stringify({ grounds: cleanGrounds })).digest('hex');
    try { return await this.repository.fileAppeal(digest(validateToken(token)), cleanGrounds, idempotencyKey.trim(), requestHash); }
    catch (error) { if (error instanceof SuspendedRecoveryError) throw error; throw new SuspendedRecoveryError('INVALID_OR_EXPIRED_RECOVERY_TOKEN', 404); }
  }
}

export const suspendedAccountRecoveryService = new SuspendedAccountRecoveryService(
  new SupabaseRecoveryRepository(), new EmailRecoveryDelivery());