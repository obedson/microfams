import { Router } from 'express';
import { groupAdminController } from '../controllers/groupAdminController.js';
import { authenticateToken } from '../middleware/auth.js';

const router = Router();

router.use(authenticateToken as any);

router.get('/:id/admin/dashboard', groupAdminController.getAdminDashboard);
router.put('/:id', groupAdminController.updateGroup);
router.post('/:id/members/:memberId/vote', groupAdminController.castVote);
router.get('/:id/votes', groupAdminController.getVotes);
router.get('/:id/member/dashboard', groupAdminController.getMemberDashboard);

export default router;
