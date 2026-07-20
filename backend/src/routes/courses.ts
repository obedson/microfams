import { Router } from 'express';
import {
  getCourses, getCourse, getOrganizationCourses, getOrganizationCourse,
  createCourse, updateCourse, deleteCourse, updateProgress, getUserProgress,
  getRecommendations, generateCertificate,
} from '../controllers/courseController.js';
import { authenticateToken } from '../middleware/auth.js';
import { requireTenantRole, resolveTenant } from '../middleware/tenant.js';

const router = Router();

router.get('/', getCourses);
router.get('/recommendations', authenticateToken, resolveTenant, getRecommendations);
router.get('/organization', authenticateToken, resolveTenant, getOrganizationCourses);
router.get('/organization/:id', authenticateToken, resolveTenant, getOrganizationCourse);
router.get('/user/progress', authenticateToken, resolveTenant, getUserProgress);
router.get('/:id', getCourse);
router.post('/', authenticateToken, resolveTenant, requireTenantRole(['owner', 'admin', 'program_manager']), createCourse);
router.put('/:id', authenticateToken, resolveTenant, requireTenantRole(['owner', 'admin', 'program_manager']), updateCourse);
router.delete('/:id', authenticateToken, resolveTenant, requireTenantRole(['owner', 'admin', 'program_manager']), deleteCourse);
router.post('/:courseId/progress', authenticateToken, resolveTenant, updateProgress);
router.post('/:courseId/certificate', authenticateToken, resolveTenant, generateCertificate);

export default router;
