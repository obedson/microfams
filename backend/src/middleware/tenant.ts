import { NextFunction, Response } from 'express';
import { AuthRequest } from './auth.js';
import { SupabaseTenantRepository } from '../repositories/tenantRepository.js';
import { TenantResolutionError, TenantService } from '../services/tenantService.js';
import { OrganizationRole, TenantContext } from '../types/tenant.js';

export interface TenantRequest extends AuthRequest {
  tenant?: TenantContext;
}

const tenantService = new TenantService(new SupabaseTenantRepository());
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const createResolveTenant = (service: Pick<TenantService, 'resolve'>) => async (
  req: TenantRequest,
  res: Response,
  next: NextFunction,
) => {
  const userId = req.user?.id;
  if (!userId) return res.status(401).json({ success: false, error: 'AUTHENTICATION_REQUIRED' });

  const header = req.headers['x-organization-id'];
  if (Array.isArray(header)) {
    return res.status(400).json({ success: false, error: 'INVALID_TENANT_SELECTION' });
  }
  if (header && !UUID_PATTERN.test(header)) {
    return res.status(400).json({ success: false, error: 'INVALID_TENANT_SELECTION' });
  }

  try {
    req.tenant = await service.resolve(userId, header);
    next();
  } catch (error) {
    if (error instanceof TenantResolutionError) {
      return res.status(error.status).json({ success: false, error: error.code, message: error.message });
    }
    return res.status(503).json({ success: false, error: 'TENANT_SERVICE_UNAVAILABLE' });
  }
};

export const resolveTenant = createResolveTenant(tenantService);

export const requireTenantRole = (roles: readonly OrganizationRole[]) => (
  req: TenantRequest,
  res: Response,
  next: NextFunction,
) => {
  if (!req.tenant) return res.status(500).json({ success: false, error: 'TENANT_CONTEXT_REQUIRED' });
  if (!roles.includes(req.tenant.role)) {
    return res.status(403).json({ success: false, error: 'TENANT_ROLE_REQUIRED' });
  }
  next();
};

export const requireTenantPermission = (permission: string) => (
  req: TenantRequest,
  res: Response,
  next: NextFunction,
) => {
  if (!req.tenant) return res.status(500).json({ success: false, error: 'TENANT_CONTEXT_REQUIRED' });
  if (!req.tenant.permissions.includes(permission)) {
    return res.status(403).json({ success: false, error: 'TENANT_PERMISSION_REQUIRED' });
  }
  next();
};
