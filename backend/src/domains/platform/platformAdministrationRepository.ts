import { supabase } from '../../utils/supabase.js';
import {
  PlatformAdministrationRepository,
  PlatformAdministrator,
} from './platformAdministrationTypes.js';

const mapAdministrator = (row: any): PlatformAdministrator => ({
  id: row.id,
  userId: row.user_id,
  status: row.status,
  grantedAt: row.granted_at,
  expiresAt: row.expires_at ?? null,
  user: row.user ? {
    id: row.user.id,
    email: row.user.email,
    name: row.user.name,
    isSuspended: Boolean(row.user.is_suspended),
  } : undefined,
});

const rpc = async (name: string, parameters: Record<string, unknown>): Promise<unknown> => {
  const { data, error } = await supabase.rpc(name, parameters);
  if (error || data === null) throw error ?? new Error('Platform administration command failed');
  return data;
};

export class SupabasePlatformAdministrationRepository implements PlatformAdministrationRepository {
  async isActiveAdministrator(userId: string): Promise<boolean> {
    const { data, error } = await supabase.rpc('is_active_platform_administrator', {
      p_user_id: userId,
    });
    if (error) throw error;
    return data === true;
  }

  async listActiveAdministrators(): Promise<PlatformAdministrator[]> {
    const { data, error } = await supabase
      .from('platform_administrator_assignments')
      .select('id, user_id, status, granted_at, expires_at, user:users!inner(id, email, name, is_suspended)')
      .eq('status', 'active')
      .or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`)
      .eq('user.is_suspended', false)
      .order('granted_at', { ascending: true });
    if (error) throw error;
    return (data ?? []).map(mapAdministrator);
  }

  grant(actorId: string, userId: string, reasonCode: string, expiresAt?: string) {
    return rpc('grant_platform_administrator', {
      p_actor_id: actorId,
      p_user_id: userId,
      p_reason_code: reasonCode,
      p_expires_at: expiresAt ?? null,
    });
  }

  revoke(actorId: string, userId: string, reasonCode: string) {
    return rpc('revoke_platform_administrator', {
      p_actor_id: actorId,
      p_user_id: userId,
      p_reason_code: reasonCode,
    });
  }

  suspend(actorId: string, userId: string, reasonCode: string, reasonNote?: string) {
    return rpc('suspend_platform_user', {
      p_actor_id: actorId,
      p_user_id: userId,
      p_reason_code: reasonCode,
      p_reason_note: reasonNote ?? null,
    });
  }

  resume(actorId: string, userId: string, reasonCode: string) {
    return rpc('resume_platform_user', {
      p_actor_id: actorId,
      p_user_id: userId,
      p_reason_code: reasonCode,
    });
  }
}
