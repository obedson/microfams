import { Request, Response } from 'express';
import crypto from 'node:crypto';
import { identityVerificationService } from '../domains/identity/identityVerificationService.js';
import { TenantRequest } from '../middleware/tenant.js';
import { ninService } from '../services/ninService.js';
import { supabase } from '../utils/supabase.js';
import { verifyPaystackPayment } from '../utils/paystack.js';
import Joi from 'joi';

interface AuthRequest extends Request {
  user?: {
    id: string;
    email: string;
    role: string;
  };
}
const IDENTITY_CONSENT_VERSION = 'identity-verification-v1';
const IDENTITY_CONSENT_TEXT = 'I consent to Micro Fams verifying my identity against authorized records.';
const consentTextHash = crypto.createHash('sha256').update(IDENTITY_CONSENT_TEXT).digest('hex');


class ProfileController {
  /**
   * Requirement 2: Get User Profile
   */
  async getProfile(req: AuthRequest, res: Response) {
    try {
      const { data: user, error } = await supabase
        .from('users')
        .select(`
          id, name, email, role, phone, 
          nin_number, nin_verified, nin_full_name, nin_date_of_birth, 
          nin_gender, nin_address, nin_phone, 
          profile_picture_url, is_platform_subscriber, 
          subscription_paid_at, referral_code, created_at
        `)
        .eq('id', req.user!.id)
        .single();

      if (error) throw error;

      if (user.nin_number) {
        user.nin_number = `*******${user.nin_number.slice(-4)}`;
      }

      res.json(user);
    } catch (error: any) {
      res.status(500).json({ error: error.message });
    }
  }

  /**
   * Step 1: Initiate NIN Verification
   * Requirement: prompt4.md
   */
  async verifyNIN(req: TenantRequest, res: Response) {
    const schema = Joi.object({
      nin: Joi.string().length(11).required(),
      consent: Joi.boolean().valid(true).required() // Strict validation for consent
    });

    const { error, value } = schema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    try {
      
      const { data: user, error: userError } = await supabase.from('users').select('name').eq('id', req.user!.id).single();
      
      if (userError || !user) {
        throw new Error('User record not found in database');
      }

      const nameParts = user.name.trim().split(/\s+/);
      const firstName = nameParts[0];
      const lastName = nameParts[nameParts.length - 1];
      
      if (!req.tenant) throw new Error('Tenant context is required');
      const header = req.headers['idempotency-key'];
      const idempotencyKey = typeof header === 'string' && header.length >= 8
        ? header
        : 'identity-' + crypto.randomUUID();
      const result = await identityVerificationService.start({
        organizationId: req.tenant.id,
        userId: req.user!.id,
        evidenceType: 'nin',
        identifier: value.nin,
        firstName,
        lastName,
        consentVersion: IDENTITY_CONSENT_VERSION,
        consentTextHash,
        idempotencyKey,
      });
      res.json(result);
    } catch (error: any) {
      res.status(422).json({ error: error.message });
    }
  }

  /**
   * Step 2: Confirm Phone and Send OTP
   */
  async sendOTP(req: TenantRequest, res: Response) {
    const schema = Joi.object({
      requestRef: Joi.string().required(),
      fullPhone: Joi.string().required()
    });

    const { error, value } = schema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    try {
      res.json({ success: true, message: 'OTP was sent to the verified identity destination' });
    } catch (error: any) {
      res.status(422).json({ error: error.message });
    }
  }

  /**
   * Step 3: Verify OTP and Complete Profile
   */
  async confirmOTP(req: TenantRequest, res: Response) {
    const schema = Joi.object({
      requestRef: Joi.string().required(),
      otp: Joi.string().required()
    });

    const { error, value } = schema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    try {
      if (!req.tenant) throw new Error('Tenant context is required');
      const result = await identityVerificationService.confirm({
        organizationId: req.tenant.id,
        userId: req.user!.id,
        requestId: value.requestRef,
        otp: value.otp,
      });
      res.json(result);
    } catch (error: any) {
      res.status(422).json({ error: error.message });
    }
  }

  /**
   * Requirement 9.1, 9.2, 9.3: Upload Profile Picture
   */
  async uploadProfilePicture(req: AuthRequest, res: Response) {
    if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

    try {
      const url = await ninService.uploadProfilePicture(req.user!.id, req.file.buffer, req.file.mimetype);
      res.json({ profile_picture_url: url });
    } catch (error: any) {
      res.status(400).json({ error: error.message });
    }
  }

  /**
   * Requirement 4.3, 4.4: Platform Subscription
   */
  async subscribe(req: AuthRequest, res: Response) {
    const schema = Joi.object({
      payment_reference: Joi.string().required()
    });

    const { error, value } = schema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    try {
      const { data: existingSub } = await supabase.from('users').select('id').eq('subscription_reference', value.payment_reference).maybeSingle();
      if (existingSub) return res.status(400).json({ error: 'This payment reference has already been used' });

      const verification = await verifyPaystackPayment(value.payment_reference);
      if (!verification.valid) return res.status(400).json({ error: verification.message || 'Payment verification failed' });

      await supabase.from('users').update({
        is_platform_subscriber: true,
        subscription_paid_at: new Date().toISOString(),
        subscription_reference: value.payment_reference,
        updated_at: new Date().toISOString()
      }).eq('id', req.user!.id);

      res.json({ success: true, message: 'Successfully subscribed to platform' });
    } catch (error: any) {
      res.status(500).json({ error: error.message });
    }
  }
}

export const profileController = new ProfileController();
