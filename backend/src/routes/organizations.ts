import { Router } from 'express';
import { organizationController } from '../controllers/organizationController.js';
import { authenticateToken } from '../middleware/auth.js';
import { requireTenantRole, resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';

const router = Router();

router.use(authenticateToken);
router.get('/', organizationController.list);
router.post('/', organizationController.create);
router.get('/current', resolveTenant, organizationController.current);
router.get('/current/verification', resolveTenant, organizationController.getVerification);
router.post(
  '/current/verification',
  resolveTenant,
  requireTenantRole(['owner', 'admin']),
  requireFeature('integration.organization_verification'),
  organizationController.submitVerification,
);
router.patch(
  '/current/branding',
  resolveTenant,
  requireTenantRole(['owner', 'admin']),
  organizationController.updateBranding,
);

export default router;
