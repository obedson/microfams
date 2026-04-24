import { Router } from 'express';
import { 
  generateReceipt,
  downloadReceipt
} from '../controllers/receiptController.js';
import { authenticateToken } from '../middleware/auth.js';

const router = Router();

// All receipt routes require authentication
router.use(authenticateToken);

// Generate receipt
router.post('/:bookingId/generate', generateReceipt);

// Download receipt
router.get('/:bookingId/download', downloadReceipt);

// Legacy endpoint for backward compatibility
router.get('/:bookingId', downloadReceipt);

export default router;
