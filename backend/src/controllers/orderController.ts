import { Response } from 'express';
import { supabase } from '../utils/supabase.js';
import { TenantRequest } from '../middleware/tenant.js';
import { logger } from '../utils/logger.js';
import { isMarketplaceOrderStatus, normalizeOrderQuantity } from '../services/marketplaceOrderPolicy.js';

const marketplaceErrorStatus = (message: string): number => {
  if (message.includes('not found')) return 404;
  if (message.includes('stock') || message.includes('minimum order')) return 409;
  if (message.includes('membership') || message.includes('organization')) return 403;
  if (message.includes('transition')) return 409;
  return 400;
};

export const createOrder = async (req: TenantRequest, res: Response) => {
  const userId = req.user?.id;
  const organizationId = req.tenant?.id;
  const { product_id, delivery_address, phone } = req.body;
  const quantity = normalizeOrderQuantity(req.body.quantity);

  if (!userId || !organizationId) {
    return res.status(401).json({ success: false, error: 'Authentication and tenant context are required' });
  }
  if (!product_id || quantity === null) {
    return res.status(400).json({ success: false, error: 'Product ID and a positive whole-number quantity are required' });
  }

  try {
    const { data, error } = await supabase.rpc('create_marketplace_order_atomic', {
      p_buyer_id: userId,
      p_organization_id: organizationId,
      p_product_id: product_id,
      p_quantity: quantity,
      p_delivery_address: delivery_address || 'Not provided',
      p_phone: phone || 'Not provided',
    });

    if (error) {
      logger.warn('Marketplace order rejected', { product_id, buyer_id: userId, organization_id: organizationId, error: error.message });
      return res.status(marketplaceErrorStatus(error.message)).json({ success: false, error: error.message });
    }

    logger.info('Marketplace order created', { order_id: data?.id, product_id, buyer_id: userId, organization_id: organizationId });
    return res.status(201).json({ success: true, order: data, message: 'Order created. Please proceed to payment.' });
  } catch (error) {
    logger.error('Create order error', { error: error instanceof Error ? error.message : String(error), buyer_id: userId });
    return res.status(500).json({ success: false, error: 'Failed to create order' });
  }
};

export const getMyOrders = async (req: TenantRequest, res: Response) => {
  try {
    const { data, error } = await supabase
      .from('orders')
      .select('*, marketplace_products(name, category, supplier_id, users(name, phone, email))')
      .eq('buyer_id', req.user?.id)
      .eq('organization_id', req.tenant!.id)
      .order('created_at', { ascending: false });

    if (error) throw error;
    res.json({ success: true, data });
  } catch (error) {
    logger.error('Get orders failed', {
      buyer_id: req.user?.id,
      organization_id: req.tenant?.id,
      error: error instanceof Error ? error.message : 'Unknown error',
    });
    res.status(500).json({ success: false, error: 'Failed to fetch orders' });
  }
};

export const getMySales = async (req: TenantRequest, res: Response) => {
  try {
    const { data, error } = await supabase
      .from('orders')
      .select('*, marketplace_products(name, category)')
      .eq('supplier_organization_id', req.tenant!.id)
      .order('created_at', { ascending: false });

    if (error) throw error;
    res.json({ success: true, data: data || [] });
  } catch (error) {
    logger.error('Get sales error', {
      organization_id: req.tenant?.id,
      error: error instanceof Error ? error.message : String(error),
    });
    res.status(500).json({ success: false, error: 'Failed to fetch sales' });
  }
};

export const updateOrderStatus = async (req: TenantRequest, res: Response) => {
  const { id } = req.params;
  const { status } = req.body;
  if (!isMarketplaceOrderStatus(status)) {
    return res.status(400).json({ success: false, error: 'Invalid marketplace order status' });
  }

  try {
    const { data, error } = await supabase.rpc('update_marketplace_order_status', {
      p_order_id: id,
      p_supplier_organization_id: req.tenant!.id,
      p_actor_id: req.user!.id,
      p_new_status: status,
    });

    if (error) {
      logger.warn('Marketplace order status rejected', { order_id: id, status, organization_id: req.tenant?.id, error: error.message });
      return res.status(marketplaceErrorStatus(error.message)).json({ success: false, error: error.message });
    }

    logger.info('Marketplace order status updated', { order_id: id, status, organization_id: req.tenant?.id });
    return res.json({ success: true, data });
  } catch (error) {
    logger.error('Update order status error', { order_id: id, error: error instanceof Error ? error.message : String(error) });
    return res.status(500).json({ success: false, error: 'Failed to update order status' });
  }
};
