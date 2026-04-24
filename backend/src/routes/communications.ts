import { Router } from 'express';
import multer from 'multer';
import { 
  sendMessage,
  getBookingMessages,
  markMessageAsRead,
  getUnreadMessages,
  getAllUserMessages
} from '../controllers/communicationController.js';
import { uploadMedia } from '../controllers/uploadController.js';
import { authenticateToken } from '../middleware/auth.js';
import { apiLimiter } from '../middleware/rateLimiter.js';

const router = Router();

// Configure multer for file uploads
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 10 * 1024 * 1024, // 10MB limit
  },
  fileFilter: (req, file, cb) => {
    // Allow images and videos
    if (file.mimetype.startsWith('image/') || file.mimetype.startsWith('video/')) {
      cb(null, true);
    } else {
      cb(new Error('Only images and videos are allowed'));
    }
  }
});

// All communication routes require authentication
router.use(authenticateToken);

// Send message (with rate limiting)
router.post('/send', apiLimiter, sendMessage);

// Get messages for a specific booking
router.get('/booking/:booking_id', getBookingMessages);

// Mark message as read
router.put('/message/:message_id/read', markMessageAsRead);

// Get unread messages for current user
router.get('/unread', getUnreadMessages);

// Get all messages for current user (for conversations)
router.get('/all', getAllUserMessages);

// Upload media file
router.post('/upload', upload.single('file'), uploadMedia);

export default router;
