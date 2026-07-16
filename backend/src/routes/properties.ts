import { Router } from 'express';
import { createProperty, getProperties, getProperty, updateProperty, deleteProperty, uploadImages, deleteImage, updateImageOrder } from '../controllers/propertyController.js';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { upload } from '../utils/upload.js';

const router = Router();

router.get('/', getProperties);
router.get('/:id', getProperty);
router.post('/', authenticateToken, resolveTenant, createProperty);
router.post('/:id/images', authenticateToken, resolveTenant, upload.array('images', 5), uploadImages);
router.put('/:id', authenticateToken, resolveTenant, upload.array('images', 5), updateProperty);
router.delete('/:id', authenticateToken, resolveTenant, deleteProperty);
router.delete('/:id/images', authenticateToken, resolveTenant, deleteImage);
router.put('/:id/images/reorder', authenticateToken, resolveTenant, updateImageOrder);

export default router;
