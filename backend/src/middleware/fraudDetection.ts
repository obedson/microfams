import { Response, NextFunction } from 'express';
import { AuthRequest } from './auth.js';
import { SecurityService } from '../services/securityService.js';
import { logger } from '../utils/logger.js';

/**
 * Middleware to detect and log suspicious booking activities
 */
export const detectBookingFraud = async (req: AuthRequest, res: Response, next: NextFunction) => {
  try {
    const userId = req.user?.id;
    if (!userId) return next();

    const { total_amount } = req.body;
    
    // Check for high-value transactions or frequent bookings
    const fraudCheck = await SecurityService.detectFraud(userId, { amount: total_amount });

    if (fraudCheck.isFraud) {
      logger.warn(`Potential fraud detected for user ${userId}: ${fraudCheck.reason}`);
      
      await SecurityService.logAction({
        userId,
        action: 'fraud_warning',
        resource: 'booking',
        details: { 
          reason: fraudCheck.reason,
          amount: total_amount,
          path: req.path
        },
        status: 'warning',
        ipAddress: req.ip,
        userAgent: req.get('user-agent')
      });
    }

    next();
  } catch (error) {
    logger.error('Fraud detection middleware error:', error);
    next(); // Don't block the request if middleware fails
  }
};
