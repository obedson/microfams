import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { intelligenceController } from '../controllers/intelligenceController.js';

const router = Router();
router.get('/mapping', authenticateToken, resolveTenant, requireFeature('integration.mapping'), intelligenceController.mapping);
router.get('/satellite', authenticateToken, resolveTenant, requireFeature('integration.satellite'), intelligenceController.satellite);
export default router;
