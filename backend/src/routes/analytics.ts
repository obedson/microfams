import express from 'express';
import { authenticateToken } from '../middleware/auth.js';
import {
  getPropertyAnalytics,
  getDashboardAnalytics,
  getRevenueBreakdown,
  getPropertyPerformance,
  getMonthlyTrends,
  getOccupancyRate
} from '../controllers/analyticsController.js';

const router = express.Router();

// All analytics routes require authentication
router.use(authenticateToken);

// Property-specific analytics
router.get('/property/:id', getPropertyAnalytics);
router.get('/occupancy-rate/:propertyId', getOccupancyRate);

// Dashboard analytics
router.get('/dashboard', getDashboardAnalytics);

// Revenue analytics
router.get('/revenue-breakdown', getRevenueBreakdown);

// Performance analytics
router.get('/property-performance', getPropertyPerformance);
router.get('/monthly-trends', getMonthlyTrends);

export default router;