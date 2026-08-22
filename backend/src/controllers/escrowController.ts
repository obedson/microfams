import { Response } from 'express';
import { AuthRequest } from '../middleware/auth.js';
import { TenantRequest } from '../middleware/tenant.js';
import { escrowContractService } from '../domains/financial/escrowContractService.js';

const actor = (req: AuthRequest) => req.user?.id;
const command = (req: TenantRequest, res: Response) => ({
  p_organization: req.tenant!.id,
  p_actor: actor(req),
  p_payer: req.body.payerId,
  p_beneficiary: req.body.beneficiaryId,
  p_currency: req.body.currency,
  p_amount_minor: req.body.amountMinor,
  p_purpose: req.body.purpose,
  p_milestones: req.body.milestones ?? [],
  p_release_rules: req.body.releaseRules ?? {},
  p_authorized_arbiters: req.body.authorizedArbiters ?? [],
  p_dispute_window_ends_at: req.body.disputeWindowEndsAt,
  p_expires_at: req.body.expiresAt,
  p_idempotency_key: req.headers['idempotency-key'],
});

export const escrowController = {
  async create(req: TenantRequest, res: Response) {
    try { return res.status(201).json(await escrowContractService.create(command(req, res))); }
    catch (error) { return res.status(400).json({ success: false, error: error instanceof Error ? error.message : 'ESCROW_COMMAND_FAILED' }); }
  },
  async activate(req: TenantRequest, res: Response) {
    try { return res.json(await escrowContractService.activate({ p_organization: req.tenant!.id, p_actor: actor(req), p_contract: req.params.contractId, p_idempotency_key: req.headers['idempotency-key'] })); }
    catch (error) { return res.status(400).json({ success: false, error: error instanceof Error ? error.message : 'ESCROW_COMMAND_FAILED' }); }
  },
};
