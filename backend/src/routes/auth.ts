import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { register, login, forgotPassword, resetPassword } from '../controllers/authController.js';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';
import { supabase } from '../utils/supabase.js';
import { generateToken } from '../utils/jwt.js';
import profileRoutes from './profile.js';

const router = Router();

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5,
  skipSuccessfulRequests: true,
  message: { success: false, error: 'Too many attempts, please try again later' }
});

router.use('/profile', profileRoutes);

router.post('/register', authLimiter, register);
router.post('/login', authLimiter, login);
router.post('/forgot-password', authLimiter, forgotPassword);
router.post('/reset-password', authLimiter, resetPassword);

router.post('/refresh-token', async (req, res) => {
  try {
    const { refreshToken } = req.body;
    if (!refreshToken) return res.status(400).json({ success: false, error: 'Token required' });

    const { data: dbToken, error } = await supabase
      .from('refresh_tokens')
      .select('*, users(id, email, role)')
      .eq('token', refreshToken)
      .single();

    if (error || !dbToken) {
      return res.status(401).json({ success: false, error: 'Invalid refresh token' });
    }

    if (dbToken.revoked || new Date(dbToken.expires_at) < new Date()) {
      return res.status(401).json({ success: false, error: 'Token expired or revoked' });
    }

    const token = generateToken({ 
      id: dbToken.users.id, 
      email: dbToken.users.email, 
      role: dbToken.users.role 
    });

    return res.json({ success: true, data: { token } });
  } catch (err) {
    return res.status(500).json({ success: false, error: 'Refresh failed' });
  }
});

// Get current user
router.get('/me', authenticateToken, async (req: AuthRequest, res) => {
  try {
    const { data, error } = await supabase
      .from('users')
      .select('id, email, name, role, phone, created_at, referral_code, paid_referrals_count')
      .eq('id', req.user?.id)
      .single();

    if (error) throw error;

    // Lazily generate a referral code for older accounts created before the feature
    if (!data.referral_code) {
      const code = Math.random().toString(36).substring(2, 10).toUpperCase();
      await supabase.from('users').update({ referral_code: code }).eq('id', data.id);
      data.referral_code = code;
    }

    // Compute actual platform subscribers referred dynamically
    const { count: platformPaidCount } = await supabase
      .from('users')
      .select('*', { count: 'exact', head: true })
      .eq('referred_by', data.id)
      .eq('is_platform_subscriber', true);
      
    data.paid_referrals_count = platformPaidCount || 0;

    res.json(data);
  } catch (error) {
    res.status(401).json({ error: 'Unauthorized' });
  }
});

// Get referral stats
router.get('/referral-stats', authenticateToken, async (req: AuthRequest, res) => {
  try {
    const { data: referrals, error } = await supabase
      .from('users')
      .select('id, name, email, created_at, is_platform_subscriber')
      .eq('referred_by', req.user?.id);

    if (error) throw error;

    const referralsWithStatus = referrals.map(ref => ({
      ...ref,
      has_paid: ref.is_platform_subscriber || false
    }));

    res.json({
      total: referrals.length,
      referrals: referralsWithStatus
    });
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch referral stats' });
  }
});

export default router;
