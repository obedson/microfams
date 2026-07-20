import { Router } from 'express';
import { 
  createRecord, 
  getMyRecords, 
  getAnalytics, 
  updateRecord, 
  deleteRecord,
  linkToBooking,
  getPropertyProductivity,
  getFarmerRecommendations
} from '../controllers/farmRecordController.js';
import { authenticateToken } from '../middleware/auth.js';
import { resolveTenant } from '../middleware/tenant.js';

const router = Router();

router.use(authenticateToken, resolveTenant);
router.get('/', getMyRecords);
router.post('/', createRecord);
router.get('/my-records', getMyRecords);
router.get('/analytics', getAnalytics);
router.get('/recommendations', getFarmerRecommendations);
router.put('/:id', updateRecord);
router.delete('/:id', deleteRecord);
router.patch('/:id/link-booking', linkToBooking);
router.get('/property/:propertyId/productivity', getPropertyProductivity);

export default router;
