import { Router } from 'express';
import { initializePayment, verifyPayment } from '../controllers/paymentController.js';
import { authenticateToken } from '../middleware/auth.js';
import { paymentLimiter } from '../middleware/rateLimiter.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { resolveTenant } from '../middleware/tenant.js';

const router = Router();

router.post('/initialize', authenticateToken, resolveTenant, requireFeature('financial.payments.accept_new'), paymentLimiter, initializePayment);
router.get('/verify/:reference', requireFeature('financial.payments.service_existing'), verifyPayment);

export default router;

// Initialize payment for marketplace orders
import axios from 'axios';
import { Response } from 'express';
import { AuthRequest } from '../middleware/auth.js';

const PAYSTACK_SECRET_KEY = process.env.PAYSTACK_SECRET_KEY;
const PAYSTACK_BASE_URL = 'https://api.paystack.co';

router.post('/initialize-order', authenticateToken, resolveTenant, requireFeature('financial.payments.accept_new'), async (req: AuthRequest, res: Response) => {
  try {
    const { amount, email, orders } = req.body;

    if (!PAYSTACK_SECRET_KEY) {
      return res.status(500).json({ success: false, error: 'Payment service not configured' });
    }

    const paymentData = {
      email: email || req.user?.email,
      amount: Math.round(amount * 100),
      reference: `order_${Date.now()}`,
      callback_url: `${process.env.FRONTEND_URL || 'http://localhost:3000'}/payment/callback`,
      metadata: {
        user_id: req.user?.id,
        order_ids: orders.map((o: any) => o.id),
      }
    };

    const response = await axios.post(
      `${PAYSTACK_BASE_URL}/transaction/initialize`,
      paymentData,
      {
        headers: {
          Authorization: `Bearer ${PAYSTACK_SECRET_KEY}`,
          'Content-Type': 'application/json'
        }
      }
    );

    res.json({
      success: true,
      data: {
        authorization_url: response.data.data.authorization_url,
        access_code: response.data.data.access_code,
        reference: response.data.data.reference
      }
    });
  } catch (error: any) {
    console.error('Paystack error:', error.response?.data || error.message);
    res.status(500).json({ success: false, error: 'Failed to initialize payment' });
  }
});

router.post('/initialize-group', authenticateToken, resolveTenant, requireFeature('financial.payments.accept_new'), async (req: AuthRequest, res: Response) => {
  try {
    const { member_id, amount } = req.body;

    const reference = `GRP_${member_id}_${Date.now()}`;

    res.json({ reference });
  } catch (error: any) {
    res.status(500).json({ error: 'Failed to initialize payment' });
  }
});
