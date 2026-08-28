import { Router, Request, Response } from 'express';
import { walletController } from '../controllers/walletController.js';
import { paymentService } from '../domains/financial/paymentService.js';
import { investmentRefundSubmissionService } from '../domains/financial/investmentRefundSubmissionService.js';
import { requireRawWebhookEnvelope } from '../services/webhookSecurityService.js';
import { logger } from '../utils/logger.js';

// Webhook-security findings require exact provider bytes, never reconstructed JSON.
const router = Router();

router.post('/paystack/investment-refunds', async (req: Request, res: Response) => {
  try {
    const envelope = requireRawWebhookEnvelope(req.body, req.headers['x-paystack-signature']);
    const receipt = await investmentRefundSubmissionService.ingestCallback(envelope.rawBody, envelope.signature);
    return res.status(202).json({ status: 'accepted', event_id: receipt.eventId,
      refund_state: receipt.state, duplicate: receipt.duplicate });
  } catch (error) {
    logger.error('Investment refund callback receipt failed', {
      error: error instanceof Error ? error.message : String(error),
    });
    return res.status(400).json({ error: 'Investment refund callback could not be accepted' });
  }
});

router.post('/paystack', async (req: Request, res: Response) => {
  try {
    const envelope = requireRawWebhookEnvelope(req.body, req.headers['x-paystack-signature']);
    const receipt = await paymentService.ingestWebhook(envelope.rawBody, envelope.signature);
    return res.status(202).json({ status: 'accepted', event_id: receipt.eventId, duplicate: receipt.duplicate });
  } catch (error) {
    logger.error('Paystack webhook receipt failed', { error: error instanceof Error ? error.message : String(error) });
    return res.status(400).json({ error: 'Webhook event could not be accepted' });
  }
});

router.post('/interswitch/payout', walletController.payoutWebhook.bind(walletController));

router.post('/interswitch', async (req: Request, res: Response) => {
  try {
    await walletController.interswitchWebhook(req, res);
  } catch (error) {
    logger.error('Interswitch webhook processing failed', { error });
    res.sendStatus(500);
  }
});

router.get('/payment/callback', (req: Request, res: Response) => {
  const { reference, trxref } = req.query;
  const frontendUrl = process.env.FRONTEND_URL || 'http://localhost:3000';
  res.redirect(`${frontendUrl}/payment/callback?reference=${encodeURIComponent(String(reference || trxref || ''))}`);
});

export default router;
