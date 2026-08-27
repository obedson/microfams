import { Router } from 'express';
import { reconciliationController } from '../controllers/reconciliationController.js';
import { authenticateToken } from '../middleware/auth.js';
import { requireFeature } from '../middleware/requireFeature.js';
import { requireTenantPermission, resolveTenant } from '../middleware/tenant.js';

const router = Router();
router.use(authenticateToken as any);
router.use(resolveTenant);
router.post('/exceptions/:exceptionId/investigate', requireFeature('financial.accounting.read'), requireTenantPermission('financial.reconciliation.manual'), reconciliationController.startInvestigation);
router.post('/exceptions/:exceptionId/resolutions', requireFeature('financial.accounting.read'), requireTenantPermission('financial.reconciliation.manual'), reconciliationController.requestResolution);
router.post('/resolutions/:requestId/decision', requireFeature('financial.accounting.read'), requireTenantPermission('financial.reconciliation.approve'), reconciliationController.decideResolution);
export default router;
