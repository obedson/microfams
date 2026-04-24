import { Router, Request, Response } from 'express';
import { supabase } from '../utils/supabase.js';
import { authenticateToken, AuthRequest } from '../middleware/auth.js';

const router = Router();

// Get all marketplace products
router.get('/', async (req: Request, res: Response) => {
  try {
    const { data, error } = await supabase
      .from('marketplace_products')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) throw error;

    res.json({ success: true, data });
  } catch (error: any) {
    res.status(500).json({ success: false, error: error.message });
  }
});

// Get single product
router.get('/:id', async (req: Request, res: Response) => {
  try {
    const { data, error } = await supabase
      .from('marketplace_products')
      .select('*')
      .eq('id', req.params.id)
      .single();

    if (error) throw error;

    res.json({ success: true, data });
  } catch (error: any) {
    res.status(404).json({ success: false, error: 'Product not found' });
  }
});

// Create product (authenticated)
router.post('/', authenticateToken, async (req: AuthRequest, res: Response) => {
  try {
    const { name, description, price, category, stock, image_url } = req.body;

    const { data, error } = await supabase
      .from('marketplace_products')
      .insert([{
        name,
        description,
        price,
        category,
        stock,
        image_url,
        seller_id: req.user?.id,
      }])
      .select()
      .single();

    if (error) throw error;

    res.status(201).json({ success: true, data });
  } catch (error: any) {
    res.status(500).json({ success: false, error: error.message });
  }
});

export default router;
