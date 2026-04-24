import { Router } from 'express';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';
import { supabase } from '../utils/supabase.js';
import axios from 'axios';
import { logger } from '../utils/logger.js';

const router = Router();

// Initialize payment for marketplace order
router.post('/orders/:orderId/pay', authenticateToken, async (req: AuthRequest, res) => {
  try {
    const { orderId } = req.params;

    // Get order details
    const { data: order, error } = await supabase
      .from('orders')
      .select('*, marketplace_products(name)')
      .eq('id', orderId)
      .eq('buyer_id', req.user?.id)
      .single();

    if (error || !order) {
      logger.error('Order not found', { orderId, buyer_id: req.user?.id });
      return res.status(404).json({ success: false, error: 'Order not found' });
    }

    if (order.status === 'paid') {
      return res.status(400).json({ success: false, error: 'Order already paid' });
    }

    // Initialize Paystack payment
    const paystackResponse = await axios.post(
      'https://api.paystack.co/transaction/initialize',
      {
        email: req.user?.email,
        amount: Math.round(order.total_amount * 100), // Convert to kobo
        reference: `order_${orderId}_${Date.now()}`,
        metadata: {
          order_id: orderId,
          buyer_id: req.user?.id,
          product_id: order.product_id,
          type: 'marketplace_order'
        },
        callback_url: `${process.env.FRONTEND_URL}/payment/callback`
      },
      {
        headers: {
          Authorization: `Bearer ${process.env.PAYSTACK_SECRET_KEY}`,
          'Content-Type': 'application/json'
        }
      }
    );

    logger.info('Payment initialized', { 
      orderId, 
      reference: paystackResponse.data.data.reference 
    });

    res.json({
      success: true,
      authorization_url: paystackResponse.data.data.authorization_url,
      reference: paystackResponse.data.data.reference
    });
  } catch (error: any) {
    logger.error('Payment initialization error', { 
      orderId: req.params.orderId,
      error: error.message 
    });
    res.status(500).json({ success: false, error: 'Failed to initialize payment' });
  }
});

// Get order status
router.get('/orders/:orderId/status', authenticateToken, async (req: AuthRequest, res) => {
  try {
    const { orderId } = req.params;

    const { data: order, error } = await supabase
      .from('orders')
      .select('id, status, total_amount, created_at')
      .eq('id', orderId)
      .eq('buyer_id', req.user?.id)
      .single();

    if (error || !order) {
      return res.status(404).json({ success: false, error: 'Order not found' });
    }

    res.json({ success: true, data: order });
  } catch (error: any) {
    logger.error('Failed to fetch order status', { 
      orderId: req.params.orderId,
      error: error.message 
    });
    res.status(500).json({ success: false, error: 'Failed to fetch order status' });
  }
});

export default router;
