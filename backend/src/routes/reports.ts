import { Router } from 'express';
import { authenticateToken, requireRole } from '../middleware/auth.js';
import { getBookingReport, getEngagementReport, getRetentionBI, exportData } from '../controllers/reportController.js';

const router = Router();

// All reporting routes require admin privileges
router.use(authenticateToken);
router.use(requireRole(['admin']));

router.get('/bookings', getBookingReport);
router.get('/engagement', getEngagementReport);
router.get('/retention', getRetentionBI);
router.post('/export', exportData);

export default router;
