import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { BookingRefundOrchestrationService } from '../services/bookingRefundOrchestrationService.js';

const idempotencyKey = (request: TenantRequest): string =>
  String(request.headers['idempotency-key'] ?? '');

export const proposeBookingRefund = async (req: TenantRequest, res: Response) => {
  const key = idempotencyKey(req);
  const amountMinor = Number(req.body.amount_minor);
  const reason = String(req.body.reason ?? '');
  if (key.length < 8) return res.status(400).json({ success: false, error: 'Idempotency-Key header is required' });
  if (!Number.isSafeInteger(amountMinor) || amountMinor <= 0) {
    return res.status(400).json({ success: false, error: 'Refund amount must be positive integer minor units' });
  }
  if (reason.trim().length < 2 || reason.trim().length > 500) {
    return res.status(400).json({ success: false, error: 'Refund reason must contain 2 to 500 characters' });
  }
  try {
    const data = await BookingRefundOrchestrationService.proposeManualRefund({
      cancellationId: req.params.cancellationId,
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      amountMinor,
      reason,
      idempotencyKey: key,
    });
    return res.status(202).json({ success: true, data });
  } catch (error: any) {
    const forbidden = String(error?.message).includes('not authorized');
    return res.status(forbidden ? 403 : 409).json({ success: false, error: error?.message ?? 'Refund proposal failed' });
  }
};

export const decideBookingRefund = async (req: TenantRequest, res: Response) => {
  const key = idempotencyKey(req);
  const reason = String(req.body.reason ?? '');
  if (key.length < 8) return res.status(400).json({ success: false, error: 'Idempotency-Key header is required' });
  if (typeof req.body.approve !== 'boolean') {
    return res.status(400).json({ success: false, error: 'approve must be boolean' });
  }
  if (reason.trim().length < 2 || reason.trim().length > 500) {
    return res.status(400).json({ success: false, error: 'Decision reason must contain 2 to 500 characters' });
  }
  try {
    const data = await BookingRefundOrchestrationService.decideManualRefund({
      approvalId: req.params.approvalId,
      organizationId: req.tenant!.id,
      actorId: req.user!.id,
      approve: req.body.approve,
      reason,
      idempotencyKey: key,
    });
    return res.status(req.body.approve ? 202 : 200).json({ success: true, data });
  } catch (error: any) {
    const message = String(error?.message ?? 'Refund decision failed');
    const forbidden = message.includes('not authorized') || message.includes('Maker cannot');
    return res.status(forbidden ? 403 : 409).json({ success: false, error: message });
  }
};
