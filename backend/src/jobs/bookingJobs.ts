import cron from 'node-cron';
import { bookingNotificationOutboxWorker } from '../services/bookingNotificationOutboxService.js';

import { logger } from '../utils/logger.js';

export const startBookingJobs = () => {
  cron.schedule('* * * * *', async () => {
    try {
      const result = await bookingNotificationOutboxWorker.runOnce();
      if (result.claimed > 0) {
        logger.info('Processed booking notification outbox', result);
      }
    } catch (error) {
      logger.error('Error processing booking notification outbox', { error });
    }
  });
};
