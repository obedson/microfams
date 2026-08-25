import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { weatherController } from '../controllers/weatherController.js';
const router=Router();
router.get('/forecast', authenticateToken, resolveTenant, requireFeature('integration.weather'), weatherController.forecast);
export default router;
