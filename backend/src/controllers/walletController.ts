import { Request, Response } from 'express';
import { walletService } from '../services/walletService.js';
import { AuthRequest } from '../middleware/auth.js';
import { supabase } from '../utils/supabase.js';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';

const p2pSchema = Joi.object({
  recipientEmail: Joi.string().email().required(),
  amountMinor: Joi.number().integer().min(10000).max(Number.MAX_SAFE_INTEGER).required(),
  currency: Joi.string().valid('NGN').required(),
  idempotencyKey: Joi.string().guid({ version: 'uuidv4' }).required()
});

const withdrawSchema = Joi.object({
  accountNumber: Joi.string().required(),
  bankCode: Joi.string().required(),
  amountMinor: Joi.number().integer().min(100000).max(Number.MAX_SAFE_INTEGER).required(),
  currency: Joi.string().valid('NGN').required(),
  idempotencyKey: Joi.string().guid({ version: 'uuidv4' }).required()
});

const confirmWithdrawSchema = Joi.object({
  previewToken: Joi.string().required()
});

const groupWithdrawSchema = Joi.object({
  amountMinor: Joi.number().integer().min(1).max(Number.MAX_SAFE_INTEGER).required(),
  currency: Joi.string().valid('NGN').required(),
  idempotencyKey: Joi.string().guid({ version: 'uuidv4' }).required(),
  targetUserId: Joi.string().guid({ version: 'uuidv4' }).required()
});

class WalletController {
  async getWallet(req: TenantRequest, res: Response) {
    const page = parseInt(req.query.page as string) || 1;
    const limit = parseInt(req.query.limit as string) || 10;
    const result = await walletService.getWalletWithHistory(req.user!.id, page, limit, req.tenant!.id);
    res.json(result);
  }

  async lookupRecipient(req: TenantRequest, res: Response) {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: 'Email is required' });

    const { data: membership, error } = await supabase
      .from('organization_memberships')
      .select('user:users!inner(id, name, nin_verified, email)')
      .eq('organization_id', req.tenant!.id)
      .eq('status', 'active')
      .eq('users.email', email)
      .maybeSingle();
    const recipient = membership?.user as any;

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

  async initiateP2P(req: TenantRequest, res: Response) {
    const { error, value } = p2pSchema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    const { data: membership } = await supabase
      .from('organization_memberships')
      .select('user:users!inner(id, email)')
      .eq('organization_id', req.tenant!.id)
      .eq('status', 'active')
      .eq('users.email', value.recipientEmail)
      .maybeSingle();
    const recipient = membership?.user as any;

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
        value.amountMinor,
        value.idempotencyKey,
        req.ip || '0.0.0.0',
        req.tenant!.id
      );
      res.json(result);
    } catch (svcError: any) {
      res.status(400).json({ error: svcError.message });
    }
  }

  async previewWithdrawal(req: TenantRequest, res: Response) {
    const { error, value } = withdrawSchema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    const result = await walletService.previewWithdrawal(
      req.user!.id,
      value.accountNumber,
      value.bankCode,
      value.amountMinor,
      value.idempotencyKey,
      req.tenant!.id
    );
    res.json(result);
  }

  async confirmWithdrawal(req: TenantRequest, res: Response) {
    const { error, value } = confirmWithdrawSchema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    const result = await walletService.confirmWithdrawal(
      req.user!.id,
      value.previewToken,
      req.ip || '0.0.0.0',
      req.tenant!.id
    );
    res.status(202).json(result);
  }

  async getTransaction(req: TenantRequest, res: Response) {
    const result = await walletService.getTransaction(req.user!.id, req.params.id, req.tenant!.id);
    res.json(result);
  }

  async syncWithdrawal(req: TenantRequest, res: Response) {
    const result = await walletService.syncWithdrawalStatus(req.user!.id, req.params.requestId, req.tenant!.id);
    res.json(result);
  }

  async getWithdrawalStatus(req: TenantRequest, res: Response) {
    try {
      const result = await walletService.getWithdrawalStatus(req.user!.id, req.params.id, req.tenant!.id);
      res.json(result);
    } catch {
      res.status(404).json({ error: 'Withdrawal not found' });
    }
  }

  async getGroupWallet(req: TenantRequest, res: Response) {
    const result = await walletService.getGroupWallet(req.params.id, req.user!.id, req.tenant!.id);
    res.json(result);
  }

  async initiateGroupWithdrawal(req: TenantRequest, res: Response) {
    const { error, value } = groupWithdrawSchema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    const result = await walletService.initiateGroupWithdrawal(
      req.params.id,
      req.user!.id,
      value.amountMinor,
      value.idempotencyKey,
      value.targetUserId,
      req.ip || '0.0.0.0',
      req.tenant!.id
    );
    res.status(201).json(result);
  }

  async getGroupWithdrawalRequest(req: TenantRequest, res: Response) {
    const result = await walletService.getGroupWithdrawalRequest(req.params.requestId, req.tenant!.id);
    res.json(result);
  }

  async castApprovalVote(req: TenantRequest, res: Response) {
    const result = await walletService.castApprovalVote(
      req.params.requestId,
      req.user!.id,
      req.ip || '0.0.0.0',
      req.tenant!.id
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
