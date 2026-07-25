import { Request, Response } from 'express';
import { UserModel } from '../models/User.js';
import { WalletService } from '../services/walletService.js';
import { generateToken, generateRefreshToken } from '../utils/jwt.js';
import { supabase } from '../utils/supabase.js';
import Joi from 'joi';

const walletService = new WalletService();
const registerSchema = Joi.object({
  email: Joi.string().email().required(),
  password: Joi.string().min(6).required(),
  name: Joi.string().min(2).required(),
  role: Joi.string().valid('farmer', 'owner').required(),
  phone: Joi.string().optional().allow('').pattern(/^[0-9+\-\s()]{10,}$/),
  referral_code: Joi.string().optional().allow('').trim(),
});

const loginSchema = Joi.object({
  email: Joi.string().email().required(),
  password: Joi.string().required(),
});

export const register = async (req: Request, res: Response) => {
  try {
    const { error, value } = registerSchema.validate(req.body);
    if (error) {
      return res.status(400).json({ success: false, error: error.details[0].message });
    }

    const existingUser = await UserModel.findByEmail(value.email);
    if (existingUser) {
      return res.status(400).json({ success: false, error: 'Email already registered' });
    }

    const user = await UserModel.create({
      ...value,
      referredBy: value.referral_code
    });
    
    // Provision wallet
    try {
      await walletService.provisionUserWallet(user.id);
    } catch (walletError) {
      console.error(`Wallet provisioning failed for user ${user.id}:`, walletError);
    }

    const token = generateToken({ id: user.id, email: user.email, role: user.role });
    const refreshToken = generateRefreshToken();

    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + 7);
    await supabase.from('refresh_tokens').insert({
        user_id: user.id,
        token: refreshToken,
        expires_at: expiresAt.toISOString()
    });

    const { password, ...userWithoutPassword } = user as any;
    res.status(201).json({
      success: true,
      data: { user: userWithoutPassword, token, refreshToken },
    });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Registration failed' });
  }
};

export const login = async (req: Request, res: Response) => {
  try {
    const { error, value } = loginSchema.validate(req.body);
    if (error) {
      return res.status(400).json({ success: false, error: error.details[0].message });
    }

    const user = await UserModel.findByEmail(value.email);
    if (!user) {
      return res.status(401).json({ success: false, error: 'Invalid credentials' });
    }

    const isValidPassword = await UserModel.verifyPassword(value.password, (user as any).password);
    if (!isValidPassword) {
      return res.status(401).json({ success: false, error: 'Invalid credentials' });
    }

    if ((user as any).is_suspended) {
      return res.status(403).json({ success: false, error: 'ACCOUNT_SUSPENDED' });
    }

    const token = generateToken({ id: user.id, email: user.email, role: user.role });
    const refreshToken = generateRefreshToken();

    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + 7);
    await supabase.from('refresh_tokens').insert({
        user_id: user.id,
        token: refreshToken,
        expires_at: expiresAt.toISOString()
    });

    const { password, ...userWithoutPassword } = user as any;

    // Lazily generate referral code if missing
    if (!userWithoutPassword.referral_code) {
      const code = Math.random().toString(36).substring(2, 10).toUpperCase();
      await supabase.from('users').update({ referral_code: code }).eq('id', user.id);
      userWithoutPassword.referral_code = code;
    }

    res.json({
      success: true,
      data: { user: userWithoutPassword, token, refreshToken },
    });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Login failed' });
  }
};
export const forgotPassword = async (req: Request, res: Response) => {
  try {
    const { error, value } = Joi.object({
      email: Joi.string().email().required(),
    }).validate(req.body);

    if (error) {
      return res.status(400).json({ success: false, error: error.details[0].message });
    }

    const user = await UserModel.findByEmail(value.email);
    if (!user) {
      // Don't reveal if email exists
      return res.json({ success: true, message: 'If email exists, reset link sent' });
    }

    const resetToken = require('crypto').randomBytes(32).toString('hex');
    const expires = new Date(Date.now() + 3600000); // 1 hour

    await UserModel.updateResetToken(value.email, resetToken, expires);
    
    const { sendPasswordResetEmail } = await import('../services/emailService');
    await sendPasswordResetEmail(value.email, resetToken);

    res.json({ success: true, message: 'If email exists, reset link sent' });
  } catch (error) {
    console.error('Forgot password error:', error);
    res.status(500).json({ success: false, error: 'Failed to process request' });
  }
};

export const resetPassword = async (req: Request, res: Response) => {
  try {
    const { error, value } = Joi.object({
      token: Joi.string().required(),
      password: Joi.string().min(6).required(),
    }).validate(req.body);

    if (error) {
      return res.status(400).json({ success: false, error: error.details[0].message });
    }

    const user = await UserModel.findByResetToken(value.token);
    if (!user) {
      return res.status(400).json({ success: false, error: 'Invalid or expired token' });
    }

    await UserModel.updatePassword(user.id, value.password);

    res.json({ success: true, message: 'Password reset successfully' });
  } catch (error) {
    res.status(500).json({ success: false, error: 'Failed to reset password' });
  }
};
