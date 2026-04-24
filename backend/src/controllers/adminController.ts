import { Response } from 'express';
import { AuthRequest } from '../middleware/auth.js';
import { supabase } from '../utils/supabase.js';
import { SecurityService } from '../services/securityService.js';

export const getAuditLogs = async (req: AuthRequest, res: Response) => {
  try {
    const { action, status, limit = 50 } = req.query;
    
    let query = supabase
      .from('audit_logs')
      .select('*, users(name, email)')
      .order('created_at', { ascending: false })
      .limit(Number(limit));

    if (action) query = query.eq('action', action);
    if (status) query = query.eq('status', status);

    const { data, error } = await query;
    if (error) throw error;

    res.json(data);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const getSecurityAlerts = async (req: AuthRequest, res: Response) => {
  try {
    const { data, error } = await supabase
      .from('audit_logs')
      .select('*, users(name, email)')
      .eq('status', 'warning')
      .order('created_at', { ascending: false })
      .limit(20);

    if (error) throw error;
    res.json(data);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const setupMFA = async (req: AuthRequest, res: Response) => {
  try {
    const userId = req.user.id;
    const { data: user } = await supabase
      .from('users')
      .select('email')
      .eq('id', userId)
      .single();

    if (!user) return res.status(404).json({ error: 'User not found' });

    const mfaData = await SecurityService.generateMFASecret(userId, user.email);
    res.json(mfaData);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const verifyMFA = async (req: AuthRequest, res: Response) => {
  try {
    const userId = req.user.id;
    const { token } = req.body;

    const { data: user } = await supabase
      .from('users')
      .select('temp_mfa_secret')
      .eq('id', userId)
      .single();

    if (!user || !user.temp_mfa_secret) {
      return res.status(400).json({ error: 'MFA not initialized' });
    }

    const isValid = SecurityService.verifyTOTP(user.temp_mfa_secret, token);
    
    if (isValid) {
      await supabase
        .from('users')
        .update({ 
          mfa_enabled: true,
          mfa_secret: user.temp_mfa_secret,
          temp_mfa_secret: null
        })
        .eq('id', userId);

      await SecurityService.logAction({
        userId,
        action: 'mfa_enabled',
        resource: 'user_account',
        status: 'success',
        ipAddress: req.ip
      });

      res.json({ success: true });
    } else {
      res.status(400).json({ error: 'Invalid MFA token' });
    }
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};
