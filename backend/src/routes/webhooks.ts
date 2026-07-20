import { Router, Request, Response } from 'express';
import { walletController } from '../controllers/walletController.js';
import { paymentService } from '../domains/financial/paymentService.js';
import { logger } from '../utils/logger.js';

const router = Router();

router.post('/paystack', async (req: Request, res: Response) => {
  const rawBody = Buffer.isBuffer(req.body) ? req.body : Buffer.from(JSON.stringify(req.body));
  try {
    const signature = req.headers['x-paystack-signature'];
    if (typeof signature !== 'string') return res.status(400).json({ error: 'Invalid signature' });
    const receipt = await paymentService.ingestWebhook(rawBody, signature);
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
