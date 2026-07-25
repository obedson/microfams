import { NextFunction, Response } from 'express';
import { createRequirePlatformAdministrator } from '../middleware/platformAdministrator.js';
import { AuthRequest } from '../middleware/auth.js';

const response = () => {
  const res = { status: jest.fn(), json: jest.fn() } as unknown as Response;
  (res.status as jest.Mock).mockReturnValue(res);
  return res;
};

describe('platform administrator middleware', () => {
  it('allows an active explicit platform administrator', async () => {
    const service = { isAuthorized: jest.fn().mockResolvedValue(true) };
    const next = jest.fn() as NextFunction;

    await createRequirePlatformAdministrator(service)(
      { user: { id: 'admin-1', role: 'farmer' } } as AuthRequest,
      response(),
      next,
    );

    expect(next).toHaveBeenCalledTimes(1);
  });

  it('rejects a legacy admin role without an assignment', async () => {
    const service = { isAuthorized: jest.fn().mockResolvedValue(false) };
    const res = response();

    await createRequirePlatformAdministrator(service)(
      { user: { id: 'legacy-admin', role: 'admin' } } as AuthRequest,
      res,
      jest.fn(),
    );

    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'PLATFORM_ADMINISTRATOR_REQUIRED',
    }));
  });

  it('fails closed when assignment state is unavailable', async () => {
    const service = { isAuthorized: jest.fn().mockRejectedValue(new Error('offline')) };
    const res = response();

    await createRequirePlatformAdministrator(service)(
      { user: { id: 'admin-1' } } as AuthRequest,
      res,
      jest.fn(),
    );

    expect(res.status).toHaveBeenCalledWith(503);
  });
});
