import { randomUUID } from 'node:crypto';
import { supabase } from '../utils/supabase.js';
import { currentCorrelationId } from './correlationContext.js';
import { logger } from './logger.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
interface AuditLog {
  organization_id?: string | null;
  user_id: string | null;
  correlation_id?: string | null;
  action: string;
  resource_type: string;
  resource_id?: string;
  details?: Record<string, unknown>;
  ip_address?: string;
}

export const logAudit = async (log: AuditLog): Promise<boolean> => {
  const resourceId = log.resource_id && UUID.test(log.resource_id) ? log.resource_id : null;
  const resourceKey = log.resource_id && !resourceId ? log.resource_id : null;
  const correlationId = log.correlation_id ?? currentCorrelationId() ?? randomUUID();
  const { resource_id: _resourceId, correlation_id: _correlationId, ...attributes } = log;
  const { error } = await supabase.from('audit_logs').insert({
    ...attributes,
    resource_id: resourceId,
    resource_key: resourceKey,
    correlation_id: correlationId,
    details: log.details ?? {},
    created_at: new Date().toISOString(),
  });
  if (error) {
    logger.error('Audit evidence persistence failed', {
      action: log.action,
      resourceType: log.resource_type,
      organizationId: log.organization_id ?? null,
      correlationId,
      error: error.message,
    });
    return false;
  }
  return true;
};