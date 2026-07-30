import crypto from 'crypto';
import { NextFunction, Response } from 'express';
import { TenantRequest } from './tenant.js';
import { supabase } from '../utils/supabase.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const requireBookingPermission = (
  requiredPermission: string,
  operation: string,
  resourceType: string,
  resourceParameter?: string,
) => async (req: TenantRequest, res: Response, next: NextFunction) => {
  if (!req.user?.id || !req.tenant?.id) {
    return res.status(401).json({
      success: false,
      error: 'AUTHENTICATION_REQUIRED',
    });
  }

  const suppliedCorrelation = req.headers['x-correlation-id'];
  const correlationId = typeof suppliedCorrelation === 'string'
    && UUID.test(suppliedCorrelation)
    ? suppliedCorrelation
    : crypto.randomUUID();
  req.headers['x-correlation-id'] = correlationId;
  const resourceId = resourceParameter
    ? String(req.params[resourceParameter] ?? '')
    : '';
  const idempotencyHeader = req.headers['idempotency-key'];
  const idempotencyKey = typeof idempotencyHeader === 'string'
    ? idempotencyHeader
    : '';

  let data: any;
  let error: any;
  try {
    ({ data, error } = await supabase.rpc(
      'evaluate_booking_authorization',
      {
        p_organization_id: req.tenant.id,
        p_actor_id: req.user.id,
        p_required_permission: requiredPermission,
        p_operation: operation,
        p_resource_type: resourceType,
        p_resource_id: resourceId,
        p_correlation_id: correlationId,
        p_idempotency_key: idempotencyKey,
      },
    ));
  } catch {
    return res.status(503).json({
      success: false,
      error: 'BOOKING_AUTHORIZATION_UNAVAILABLE',
      correlation_id: correlationId,
    });
  }
  if (error || !data) {
    return res.status(503).json({
      success: false,
      error: 'BOOKING_AUTHORIZATION_UNAVAILABLE',
      correlation_id: correlationId,
    });
  }
  if (!data.allowed) {
    return res.status(403).json({
      success: false,
      error: 'BOOKING_PERMISSION_DENIED',
      correlation_id: correlationId,
    });
  }
  return next();
};
