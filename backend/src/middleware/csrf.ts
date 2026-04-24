import { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';

const tokens = new Map<string, number>();

export const generateCsrfToken = (req: Request, res: Response, next: NextFunction) => {
  const token = crypto.randomBytes(32).toString('hex');
  tokens.set(token, Date.now() + 3600000); // 1 hour expiry
  res.cookie('csrf-token', token, { httpOnly: true, sameSite: 'strict' });
  next();
};

export const verifyCsrfToken = (req: Request, res: Response, next: NextFunction) => {
  if (req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS') {
    return next();
  }

  const token = req.headers['x-csrf-token'] as string;
  const cookieToken = req.cookies['csrf-token'];

  if (!token || !cookieToken || token !== cookieToken) {
    return res.status(403).json({ error: 'Invalid CSRF token' });
  }

  const timestamp = tokens.get(token);
  if (!timestamp || Date.now() > timestamp) {
    tokens.delete(token);
    return res.status(403).json({ error: 'CSRF token expired' });
  }

  next();
};
