import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant, requireTenantRole } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { escrowController } from '../controllers/escrowController.js';

const router = Router();
router.use(authenticateToken, resolveTenant, requireTenantRole(['owner', 'admin']));
router.post('/contracts', requireFeature('financial.escrow.create'), escrowController.create);
router.post('/contracts/:contractId/activate', requireFeature('financial.escrow.create'), escrowController.activate);
export default router;
