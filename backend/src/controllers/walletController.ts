import { Request, Response } from 'express';
import { walletService } from '../services/walletService.js';
import { AuthRequest } from '../middleware/auth.js';
import { supabase } from '../utils/supabase.js';
import Joi from 'joi';

const p2pSchema = Joi.object({
  recipientEmail: Joi.string().email().required(),
  amount: Joi.number().min(100).required()
});

const withdrawSchema = Joi.object({
  accountNumber: Joi.string().required(),
  bankCode: Joi.string().required(),
  amount: Joi.number().min(1000).required()
});

const confirmWithdrawSchema = Joi.object({
  previewToken: Joi.string().required()
});

const groupWithdrawSchema = Joi.object({
  amount: Joi.number().min(1).required(),
  targetUserId: Joi.string().guid({ version: 'uuidv4' }).required()
});

class WalletController {
  async getWallet(req: AuthRequest, res: Response) {
    const page = parseInt(req.query.page as string) || 1;
    const limit = parseInt(req.query.limit as string) || 10;
    const result = await walletService.getWalletWithHistory(req.user!.id, page, limit);
    res.json(result);
  }

  async lookupRecipient(req: AuthRequest, res: Response) {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: 'Email is required' });

    const { data: recipient, error } = await supabase
      .from('users')
      .select('id, name, nin_verified')
      .eq('email', email)
      .single();

    if (error || !recipient) {
      return res.status(404).json({ error: 'User with this email not found' });
    }

    if (recipient.id === req.user!.id) {
      return res.status(400).json({ error: 'You cannot send money to yourself' });
    }

    res.json({
      name: recipient.name,
      nin_verified: recipient.nin_verified
    });
  }

  async initiateP2P(req: AuthRequest, res: Response) {
    const { error, value } = p2pSchema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    const { data: recipient } = await supabase
      .from('users')
      .select('id')
      .eq('email', value.recipientEmail)
      .single();

    if (!recipient) {
      return res.status(404).json({ error: 'User with this email not found' });
    }

    if (recipient.id === req.user!.id) {
      return res.status(400).json({ error: 'You cannot send money to yourself' });
    }

    // Wrap the service call to handle caught errors safely
    try {
      const result = await walletService.initiateP2PTransfer(
        req.user!.id,
        recipient.id,
        value.amount,
        req.ip || '0.0.0.0'
      );
      res.json(result);
    } catch (svcError: any) {
      res.status(400).json({ error: svcError.message });
    }
  }

  async previewWithdrawal(req: AuthRequest, res: Response) {
    const { error, value } = withdrawSchema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    const result = await walletService.previewWithdrawal(
      req.user!.id,
      value.accountNumber,
      value.bankCode,
      value.amount
    );
    res.json(result);
  }

  async confirmWithdrawal(req: AuthRequest, res: Response) {
    const { error, value } = confirmWithdrawSchema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    const result = await walletService.confirmWithdrawal(
      req.user!.id,
      value.previewToken,
      req.ip || '0.0.0.0'
    );
    res.status(202).json(result);
  }

  async getTransaction(req: AuthRequest, res: Response) {
    const result = await walletService.getTransaction(req.user!.id, req.params.id);
    res.json(result);
  }

  async syncWithdrawal(req: AuthRequest, res: Response) {
    const result = await walletService.syncWithdrawalStatus(req.user!.id, req.params.requestId);
    res.json(result);
  }

  async getWithdrawalStatus(req: AuthRequest, res: Response) {
    const { data, error } = await supabase
      .from('withdrawal_requests')
      .select('*')
      .eq('id', req.params.id)
      .eq('user_id', req.user!.id)
      .single();

    if (error) return res.status(404).json({ error: 'Withdrawal not found' });
    res.json(data);
  }

  async getGroupWallet(req: AuthRequest, res: Response) {
    const result = await walletService.getGroupWallet(req.params.id, req.user!.id);
    res.json(result);
  }

  async initiateGroupWithdrawal(req: AuthRequest, res: Response) {
    const { error, value } = groupWithdrawSchema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    const result = await walletService.initiateGroupWithdrawal(
      req.params.id,
      req.user!.id,
      value.amount,
      value.targetUserId,
      req.ip || '0.0.0.0'
    );
    res.status(201).json(result);
  }

  async getGroupWithdrawalRequest(req: AuthRequest, res: Response) {
    const result = await walletService.getGroupWithdrawalRequest(req.params.requestId);
    res.json(result);
  }

  async castApprovalVote(req: AuthRequest, res: Response) {
    const result = await walletService.castApprovalVote(
      req.params.requestId,
      req.user!.id,
      req.ip || '0.0.0.0'
    );
    res.json(result);
  }

  async interswitchWebhook(req: Request, res: Response) {
    const signature = req.headers['x-interswitch-signature'] as string;
    if (!signature) return res.status(400).json({ error: 'Missing signature' });

    try {
      await walletService.handleInterswitchWebhook(req.body, signature);
      res.sendStatus(200);
    } catch (error: any) {
      console.error('Interswitch Webhook Error:', error.message);
      res.status(400).json({ error: error.message });
    }
  }
}

export const walletController = new WalletController();
