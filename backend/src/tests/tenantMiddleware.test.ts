import { NextFunction, Response } from 'express';
import { createResolveTenant, requireTenantPermission, requireTenantRole, TenantRequest } from '../middleware/tenant.js';
import { TenantContext } from '../types/tenant.js';

const ORGANIZATION_ID = '11111111-1111-4111-8111-111111111111';
const tenant: TenantContext = {
  id: ORGANIZATION_ID, name: 'Cooperative', slug: 'cooperative', type: 'cooperative', jurisdiction: 'NG',
  defaultCurrency: 'NGN', timezone: 'Africa/Lagos', status: 'active', membershipId: 'member-1',
  userId: 'user-1', role: 'admin', permissions: ['farms.read'],
};

const response = () => {
  const res = { status: jest.fn(), json: jest.fn() } as unknown as Response;
  (res.status as jest.Mock).mockReturnValue(res);
  return res;
};

describe('tenant middleware', () => {
  it('uses the requested organization only after service verification', async () => {
    const service = { resolve: jest.fn().mockResolvedValue(tenant) };
    const req = { user: { id: 'user-1' }, headers: { 'x-organization-id': ORGANIZATION_ID } } as unknown as TenantRequest;
    const next = jest.fn() as NextFunction;

    await createResolveTenant(service)(req, response(), next);

    expect(service.resolve).toHaveBeenCalledWith('user-1', ORGANIZATION_ID);
    expect(req.tenant).toEqual(tenant);
    expect(next).toHaveBeenCalledTimes(1);
  });

  it('enforces organization roles independently of global user roles', () => {
    const req = { tenant } as TenantRequest;
    const res = response();
    const next = jest.fn() as NextFunction;

    requireTenantRole(['owner'])(req, res, next);

    expect(res.status).toHaveBeenCalledWith(403);
    expect(next).not.toHaveBeenCalled();
  });

  it('rejects malformed organization selectors before repository access', async () => {
    const service = { resolve: jest.fn() };
    const req = { user: { id: 'user-1' }, headers: { 'x-organization-id': 'not-a-uuid' } } as unknown as TenantRequest;
    const res = response();

    await createResolveTenant(service)(req, res, jest.fn());

    expect(res.status).toHaveBeenCalledWith(400);
    expect(service.resolve).not.toHaveBeenCalled();
  });

  it('enforces explicit organization permissions', () => {
    const req = { tenant } as TenantRequest;
    const next = jest.fn() as NextFunction;

    requireTenantPermission('farms.read')(req, response(), next);

    expect(next).toHaveBeenCalledTimes(1);
  });
});
