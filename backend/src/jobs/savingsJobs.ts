import cron from 'node-cron';
import { durableSavingsStandingOrderJob } from './durableSavingsStandingOrderJob.js';
import { logger } from '../utils/logger.js';

export const startSavingsJobs = () => {
  cron.schedule('* * * * *', async () => {
    try {
      const result = await durableSavingsStandingOrderJob.runOnce();
      if (result.due > 0) logger.info('Processed savings standing orders', result);
    } catch (error) {
      logger.error('Savings standing-order worker failed', {
        error: error instanceof Error ? error.message : 'UNKNOWN_WORKER_ERROR',
      });
    }
  });
  logger.info('Savings standing-order jobs scheduled');
};
