import { Request, Response, NextFunction } from 'express';
import { supabase } from '../utils/supabase.js';
import { verifyToken } from '../utils/jwt.js';

export interface AuthRequest extends Request {
  user?: any;
}

interface AccountAccessState {
  exists: boolean;
  suspended: boolean;
}

type AccountAccessLoader = (userId: string) => Promise<AccountAccessState>;
type TokenVerifier = (token: string) => any;

const loadAccountAccess: AccountAccessLoader = async (userId) => {
  const { data, error } = await supabase
    .from('users')
    .select('id, is_suspended')
    .eq('id', userId)
    .maybeSingle();

  if (error) throw error;
  return {
    exists: Boolean(data),
    suspended: Boolean(data?.is_suspended),
  };
};

export const createAuthenticateToken = (
  accountAccess: AccountAccessLoader,
  tokenVerifier: TokenVerifier = verifyToken,
) => async (req: AuthRequest, res: Response, next: NextFunction) => {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];

  if (!token) {
    return res.status(401).json({ success: false, error: 'Access token required' });
  }

  let decoded: any;
  try {
    decoded = tokenVerifier(token);
  } catch {
    return res.status(401).json({ success: false, error: 'Invalid or expired token' });
  }

  if (!decoded?.id) {
    return res.status(401).json({ success: false, error: 'Invalid or expired token' });
  }

  try {
    const account = await accountAccess(decoded.id);
    if (!account.exists) {
      return res.status(401).json({ success: false, error: 'ACCOUNT_NOT_FOUND' });
    }
    if (account.suspended) {
      return res.status(403).json({ success: false, error: 'ACCOUNT_SUSPENDED' });
    }
  } catch {
    return res.status(503).json({ success: false, error: 'ACCOUNT_STATUS_UNAVAILABLE' });
  }

  req.user = decoded;
  next();
};

export const authenticateToken = createAuthenticateToken(loadAccountAccess);

export const requireRole = (roles: string[]) => {
  return (req: AuthRequest, res: Response, next: NextFunction) => {
    if (!req.user || !roles.includes(req.user.role)) {
      return res.status(403).json({ success: false, error: 'Insufficient permissions' });
    }
    next();
  };
};
