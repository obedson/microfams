import { supabase } from '../utils/supabase.js';

interface AuditLog {
  user_id: string | null;
  action: string;
  resource_type: string;
  resource_id?: string;
  details?: any;
  ip_address?: string;
}

export const logAudit = async (log: AuditLog) => {
  try {
    await supabase.from('audit_logs').insert({
      ...log,
      created_at: new Date().toISOString()
    });
  } catch (error) {
    console.error('Audit log failed:', error);
  }
};
