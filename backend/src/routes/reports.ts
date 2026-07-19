import { Router } from 'express';
import { authenticateToken } from '../middleware/auth.js';
import { requireTenantRole, resolveTenant } from '../middleware/tenant.js';
import { getBookingReport, getEngagementReport, getRetentionBI, exportData } from '../controllers/reportController.js';

const router = Router();

router.use(authenticateToken);
router.use(resolveTenant);
router.use(requireTenantRole(['owner', 'admin', 'finance_manager', 'program_manager', 'farm_manager', 'auditor']));

router.get('/bookings', getBookingReport);
router.get('/engagement', getEngagementReport);
router.get('/retention', getRetentionBI);
router.post('/export', exportData);

export default router;
