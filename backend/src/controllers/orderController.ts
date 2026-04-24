import { Request, Response } from 'express';
import { supabase } from '../utils/supabase.js';
import { AuthenticatedRequest } from '../types/index.js';
import { logger } from '../utils/logger.js';

export const createOrder = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { product_id, quantity, delivery_address, phone } = req.body;
    
    // Validate required fields
    if (!product_id || !quantity) {
      return res.status(400).json({ success: false, error: 'Product ID and quantity are required' });
    }
    
    // Get product details
    const { data: product, error: productError } = await supabase
      .from('marketplace_products')
      .select('price, stock_quantity')
      .eq('id', product_id)
      .single();

    if (productError) {
      logger.error('Product fetch failed', { product_id, error: productError.message });
      return res.status(404).json({ success: false, error: 'Product not found' });
    }

    if (!product) {
      return res.status(404).json({ success: false, error: 'Product not found' });
    }

    if (quantity > product.stock_quantity) {
      return res.status(400).json({ success: false, error: 'Insufficient stock' });
    }

    const total_amount = product.price * quantity;
    
    const orderData = {
      buyer_id: req.user?.id,
      product_id,
      quantity,
      unit_price: product.price,
      total_amount,
      delivery_address: delivery_address || 'Not provided',
      phone: phone || 'Not provided'
    };

    const { data, error } = await supabase
      .from('orders')
      .insert(orderData)
      .select()
      .single();

    if (error) {
      logger.error('Order creation failed', { product_id, buyer_id: req.user?.id, error: error.message });
      return res.status(500).json({ success: false, error: 'Failed to create order' });
    }

    // Update stock
    const { error: updateError } = await supabase
      .from('marketplace_products')
      .update({ stock_quantity: product.stock_quantity - quantity })
      .eq('id', product_id);

    if (updateError) {
      logger.error('Stock update failed', { product_id, error: updateError.message });
    }

    logger.info('Order created', { order_id: data.id, product_id, buyer_id: req.user?.id });

    // Return order with payment info
    res.status(201).json({ 
      success: true,
      order: data,
      message: 'Order created. Please proceed to payment.'
    });
  } catch (error: any) {
    logger.error('Create order error', { error: error?.message, buyer_id: req.user?.id });
    res.status(500).json({ success: false, error: 'Failed to create order' });
  }
};

export const getMyOrders = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { data, error } = await supabase
      .from('orders')
      .select('*, marketplace_products(name, category, supplier_id, users(name, phone, email))')
      .eq('buyer_id', req.user?.id)
      .order('created_at', { ascending: false });

    if (error) throw error;
    res.json({ success: true, data });
  } catch (error) {
    logger.error('Get orders failed', { 
      buyer_id: req.user?.id,
      error: error instanceof Error ? error.message : 'Unknown error'
    });
    res.status(500).json({ success: false, error: 'Failed to fetch orders' });
  }
};

export const getMySales = async (req: AuthenticatedRequest, res: Response) => {
  try {
    // First get user's products
    const { data: userProducts, error: productsError } = await supabase
      .from('marketplace_products')
      .select('id')
      .eq('supplier_id', req.user?.id);

    if (productsError) {
      logger.error('Failed to fetch user products', { 
        supplier_id: req.user?.id,
        error: productsError.message 
      });
      return res.status(500).json({ success: false, error: 'Failed to fetch sales' });
    }

    if (!userProducts || userProducts.length === 0) {
      return res.json({ success: true, data: [] });
    }

    const productIds = userProducts.map(p => p.id);

    // Then get orders for those products
    const { data, error } = await supabase
      .from('orders')
      .select('*, marketplace_products(name, category)')
      .in('product_id', productIds)
      .order('created_at', { ascending: false });

    if (error) {
      logger.error('Get sales failed', { 
        supplier_id: req.user?.id,
        error: error.message 
      });
      return res.status(500).json({ success: false, error: 'Failed to fetch sales' });
    }
    
    res.json({ success: true, data: data || [] });
  } catch (error) {
    logger.error('Get sales error', { 
      supplier_id: req.user?.id,
      error: error instanceof Error ? error.message : String(error)
    });
    res.status(500).json({ success: false, error: 'Failed to fetch sales' });
  }
};

export const updateOrderStatus = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;
    const { status } = req.body;
    
    const { data, error } = await supabase
      .from('orders')
      .update({ status })
      .eq('id', id)
      .select('*, marketplace_products!inner(supplier_id)')
      .single();

    if (error) {
      logger.error('Order status update failed', { order_id: id, error: error.message });
      throw error;
    }

    // Check if user is the supplier
    if (data.marketplace_products.supplier_id !== req.user?.id) {
      logger.warn('Unauthorized order status update attempt', { 
        order_id: id,
        user_id: req.user?.id,
        supplier_id: data.marketplace_products.supplier_id
      });
      return res.status(403).json({ success: false, error: 'Not authorized' });
    }

    logger.info('Order status updated', { order_id: id, status, supplier_id: req.user?.id });

    res.json({ success: true, data });
  } catch (error: any) {
    logger.error('Update order status error', { order_id: req.params.id, error: error?.message });
    res.status(500).json({ success: false, error: 'Failed to update order status' });
  }
};
