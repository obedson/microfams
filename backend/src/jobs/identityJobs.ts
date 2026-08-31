import cron from 'node-cron';
import { durableIdentityChallengeExpiryJob } from './durableIdentityChallengeExpiryJob.js';
import { logger } from '../utils/logger.js';

export const startIdentityJobs = () => {
  cron.schedule('* * * * *', async () => {
    try {
      const result = await durableIdentityChallengeExpiryJob.runOnce();
      if (result.expired > 0) {
        logger.info('Expired identity challenges', { expired: result.expired });
      }
    } catch {
      logger.error('Identity challenge expiry worker failed', {
        failureCode: 'IDENTITY_CHALLENGE_EXPIRY_JOB_FAILED',
      });
    }
  });
  logger.info('Identity challenge expiry job scheduled');
};
