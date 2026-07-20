import { Router, Response } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant, TenantRequest } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { supabase } from '../utils/supabase.js';
import crypto from 'crypto';
import { expectedPaymentAmountInMinorUnits } from '../services/marketplaceOrderPolicy.js';
import { logger } from '../utils/logger.js';
import { paymentService } from '../domains/financial/paymentService.js';

const router = Router();

export const initializeMarketplaceOrderPayment = async (req: TenantRequest, res: Response) => {
  const orderId = req.params.orderId || req.body.order_id;
  const userId = req.user?.id;
  const organizationId = req.tenant?.id;

  if (!orderId || !userId || !organizationId) {
    return res.status(400).json({ success: false, error: 'Order and tenant context are required' });
  }

  try {
    const { data: order, error } = await supabase
      .from('orders')
      .select('id, buyer_id, organization_id, supplier_organization_id, product_id, total_amount, status, payment_status')
      .eq('id', orderId)
      .eq('buyer_id', userId)
      .eq('organization_id', organizationId)
      .single();

    if (error || !order) return res.status(404).json({ success: false, error: 'Order not found' });
    if (order.payment_status === 'paid') return res.status(409).json({ success: false, error: 'Order already paid' });
    if (order.status === 'cancelled' || order.status === 'delivered') {
      return res.status(409).json({ success: false, error: `Payment cannot be initialized for a ${order.status} order` });
    }

    const reference = `ORDER-${order.id.slice(0, 8)}-${Date.now()}`;
    const { error: intentError } = await supabase
      .from('orders')
      .update({ payment_reference: reference, payment_status: 'pending', updated_at: new Date().toISOString() })
      .eq('id', order.id)
      .eq('buyer_id', userId)
      .eq('organization_id', organizationId);

    if (intentError) throw new Error('Could not persist marketplace payment intent');

    const payment = await paymentService.createAndInitialize({
      organizationId,
      sourceType: 'marketplace_order',
      sourceId: order.id,
      payerId: userId,
      actorId: userId,
      correlationId: crypto.randomUUID(),
      internalReference: reference,
      idempotencyKey: String(req.headers['idempotency-key'] || `order:${order.id}:${reference}`),
      amountMinor: expectedPaymentAmountInMinorUnits(order.total_amount),
      customerEmail: req.user!.email,
      callbackUrl: `${process.env.FRONTEND_URL || 'http://localhost:3000'}/payment/callback`,
      metadata: { type: 'marketplace_order', order_id: order.id },
    });

    logger.info('Marketplace payment initialized', { order_id: order.id, organization_id: organizationId, reference });
    return res.json({
      success: true,
      authorization_url: payment.authorizationUrl,
      access_code: payment.accessCode,
      reference: payment.internalReference,
      state: payment.state,
    });
  } catch (error) {
    logger.error('Marketplace payment initialization error', {
      order_id: orderId,
      organization_id: organizationId,
      error: error instanceof Error ? error.message : String(error),
    });
    return res.status(502).json({ success: false, error: 'Failed to initialize marketplace payment' });
  }
};

router.post(
  '/orders/:orderId/pay',
  authenticateToken,
  resolveTenant,
  requireFeature('financial.payments.accept_new'),
  initializeMarketplaceOrderPayment,
);

router.get('/orders/:orderId/status', authenticateToken, resolveTenant, async (req: TenantRequest, res: Response) => {
  try {
    const { data: order, error } = await supabase
      .from('orders')
      .select('id, status, payment_status, total_amount, payment_reference, paid_at, created_at')
      .eq('id', req.params.orderId)
      .eq('buyer_id', req.user?.id)
      .eq('organization_id', req.tenant!.id)
      .single();

    if (error || !order) return res.status(404).json({ success: false, error: 'Order not found' });
    return res.json({ success: true, data: order });
  } catch (error) {
    logger.error('Failed to fetch marketplace order status', {
      order_id: req.params.orderId,
      organization_id: req.tenant?.id,
      error: error instanceof Error ? error.message : String(error),
    });
    return res.status(500).json({ success: false, error: 'Failed to fetch order status' });
  }
});

export default router;
