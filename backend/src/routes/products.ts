import { Router, Response } from 'express';
import { getProducts, getProduct, createProduct, updateProduct, deleteProduct, getRecommendations, calculateBulkDiscount } from '../controllers/productController.js';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant, TenantRequest } from '../middleware/tenant.js';
import { upload } from '../utils/upload.js';
import { supabase } from '../utils/supabase.js';

const router = Router();

router.get('/', getProducts);
router.get('/recommendations', authenticateToken, resolveTenant, getRecommendations);
router.get('/my-products', authenticateToken, resolveTenant, async (req: TenantRequest, res: Response) => {
  try {
    const { data, error } = await supabase
      .from('marketplace_products')
      .select('*')
      .eq('organization_id', req.tenant!.id)
      .order('created_at', { ascending: false });

    if (error) throw error;
    res.json({ success: true, data });
  } catch (error: any) {
    res.status(500).json({ success: false, error: 'Failed to fetch organization products' });
  }
});
router.get('/:id', getProduct);
router.get('/:id/bulk-discount', calculateBulkDiscount);
router.post('/', authenticateToken, resolveTenant, upload.array('images', 5), createProduct);
router.patch('/:id', authenticateToken, resolveTenant, upload.array('images', 5), updateProduct);
router.delete('/:id', authenticateToken, resolveTenant, deleteProduct);

export default router;
