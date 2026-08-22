import cron from 'node-cron';
import { logger } from '../utils/logger.js';
import { retentionSelectionWorker } from '../services/retentionSelectionWorker.js';

export const startRetentionJobs = () => {
  cron.schedule('*/5 * * * *', async () => {
    try {
      const result = await retentionSelectionWorker.runOnce();
      if (result.scanned > 0) logger.info('Processed retention dry-run selections', result);
    } catch (error) {
      logger.error('Error processing retention dry-run selections', { error });
    }
  });
};
