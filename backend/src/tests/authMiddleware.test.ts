import { NextFunction, Response } from 'express';
import { createAuthenticateToken, AuthRequest } from '../middleware/auth.js';

const response = () => {
  const res = { status: jest.fn(), json: jest.fn() } as unknown as Response;
  (res.status as jest.Mock).mockReturnValue(res);
  return res;
};

const request = (): AuthRequest => ({
  headers: { authorization: 'Bearer valid-token' },
} as AuthRequest);

describe('active account authentication', () => {
  it('allows an active account', async () => {
    const load = jest.fn().mockResolvedValue({ exists: true, suspended: false });
    const next = jest.fn() as NextFunction;
    const req = request();

    await createAuthenticateToken(load, () => ({ id: 'user-1', role: 'admin' }))(
      req,
      response(),
      next,
    );

    expect(req.user).toEqual({ id: 'user-1', role: 'admin' });
    expect(next).toHaveBeenCalledTimes(1);
  });

  it('blocks a suspended account even with a valid access token', async () => {
    const load = jest.fn().mockResolvedValue({ exists: true, suspended: true });
    const res = response();

    await createAuthenticateToken(load, () => ({ id: 'user-1' }))(
      request(),
      res,
      jest.fn(),
    );

    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json).toHaveBeenCalledWith({
      success: false,
      error: 'ACCOUNT_SUSPENDED',
    });
  });

  it('rejects tokens for deleted accounts', async () => {
    const load = jest.fn().mockResolvedValue({ exists: false, suspended: false });
    const res = response();

    await createAuthenticateToken(load, () => ({ id: 'user-1' }))(
      request(),
      res,
      jest.fn(),
    );

    expect(res.status).toHaveBeenCalledWith(401);
  });

  it('fails closed when account status is unavailable', async () => {
    const load = jest.fn().mockRejectedValue(new Error('offline'));
    const res = response();

    await createAuthenticateToken(load, () => ({ id: 'user-1' }))(
      request(),
      res,
      jest.fn(),
    );

    expect(res.status).toHaveBeenCalledWith(503);
  });

  it('rejects malformed token claims before account lookup', async () => {
    const load = jest.fn();
    const res = response();

    await createAuthenticateToken(load, () => ({ role: 'admin' }))(
      request(),
      res,
      jest.fn(),
    );

    expect(res.status).toHaveBeenCalledWith(401);
    expect(load).not.toHaveBeenCalled();
  });
});
