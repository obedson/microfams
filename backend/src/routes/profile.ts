import { Router } from 'express';
import { profileController } from '../controllers/profileController.js';
import { authenticateToken } from '../middleware/auth.js';
import multer from 'multer';

const router = Router();
const upload = multer({ storage: multer.memoryStorage() });

router.use(authenticateToken as any);

router.get('/', profileController.getProfile);
router.post('/verify-nin', profileController.verifyNIN);
router.post('/send-otp', profileController.sendOTP);
router.post('/confirm-otp', profileController.confirmOTP);
router.post('/upload-profile-picture', upload.single('image'), profileController.uploadProfilePicture);
router.post('/subscribe', profileController.subscribe);

export default router;
