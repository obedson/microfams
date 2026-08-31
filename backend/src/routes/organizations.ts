import { Router } from 'express';
import { organizationController } from '../controllers/organizationController.js';
import { organizationInvitationController } from '../controllers/organizationInvitationController.js';
import { authenticateToken } from '../middleware/auth.js';
import { requireTenantRole, resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';

const router = Router();

router.use(authenticateToken);
router.get('/', organizationController.list);
router.post('/', organizationController.create);
router.post('/invitations/accept', organizationInvitationController.accept);
router.get(
  '/current/invitations',
  resolveTenant,
  requireTenantRole(['owner', 'admin']),
  organizationInvitationController.list,
);
router.post(
  '/current/invitations',
  resolveTenant,
  requireTenantRole(['owner', 'admin']),
  organizationInvitationController.create,
);
router.post(
  '/current/invitations/:invitationId/revoke',
  resolveTenant,
  requireTenantRole(['owner', 'admin']),
  organizationInvitationController.revoke,
);
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
