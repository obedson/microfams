import { Router } from 'express';
import { profileController } from '../controllers/profileController.js';
import { authenticateToken } from '../middleware/auth.js';
import multer from 'multer';
import { resolveTenant } from '../middleware/tenant.js';
import { requireFeature } from '../middleware/requireFeature.js';

const router = Router();
const upload = multer({ storage: multer.memoryStorage() });

router.use(authenticateToken as any);

router.get('/', profileController.getProfile);
router.post('/verify-nin', resolveTenant, requireFeature('integration.identity_verification'), profileController.verifyNIN as any);
router.post('/send-otp', resolveTenant, requireFeature('integration.identity_verification'), profileController.sendOTP as any);
router.post('/confirm-otp', resolveTenant, requireFeature('integration.identity_verification'), profileController.confirmOTP as any);
router.post('/upload-profile-picture', upload.single('image'), profileController.uploadProfilePicture);
router.post('/subscribe', profileController.subscribe);

export default router;
