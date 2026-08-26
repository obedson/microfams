import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { assistantController } from '../controllers/assistantController.js';
const router = Router();
router.post('/answer', authenticateToken, resolveTenant, requireFeature('integration.ai_assistant'), assistantController.answer);
export default router;
