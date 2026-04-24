import { Request, Response } from 'express';
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
  async verifyNIN(req: AuthRequest, res: Response) {
    const schema = Joi.object({
      nin: Joi.string().length(11).required(),
      consent: Joi.boolean().valid(true).required() // Strict validation for consent
    });

    const { error, value } = schema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    try {
      console.log(`Initiating NIN verification for user ${req.user!.id}, NIN: ${value.nin.slice(0,3)}*******`);
      
      const { data: user, error: userError } = await supabase.from('users').select('name').eq('id', req.user!.id).single();
      
      if (userError || !user) {
        console.error('User fetch error in verifyNIN:', userError);
        throw new Error('User record not found in database');
      }

      const nameParts = user.name.trim().split(/\s+/);
      const firstName = nameParts[0];
      const lastName = nameParts[nameParts.length - 1];
      
      const result = await ninService.initiateVerification(value.nin, firstName, lastName, value.consent);
      console.log('NIN initiation result:', result);
      res.json(result);
    } catch (error: any) {
      console.error('NIN Service Error:', error.message);
      res.status(422).json({ error: error.message });
    }
  }

  /**
   * Step 2: Confirm Phone and Send OTP
   */
  async sendOTP(req: AuthRequest, res: Response) {
    const schema = Joi.object({
      requestRef: Joi.string().required(),
      fullPhone: Joi.string().required()
    });

    const { error, value } = schema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    try {
      const result = await ninService.sendVerificationOTP(value.requestRef, value.fullPhone);
      res.json(result);
    } catch (error: any) {
      res.status(422).json({ error: error.message });
    }
  }

  /**
   * Step 3: Verify OTP and Complete Profile
   */
  async confirmOTP(req: AuthRequest, res: Response) {
    const schema = Joi.object({
      requestRef: Joi.string().required(),
      otp: Joi.string().required()
    });

    const { error, value } = schema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    try {
      const result = await ninService.verifyOTPAndComplete(req.user!.id, value.requestRef, value.otp);
      res.json(result);
    } catch (error: any) {
      console.error('Confirm OTP Error:', error.message);
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
