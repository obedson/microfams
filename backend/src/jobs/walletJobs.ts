import cron from 'node-cron';
import { logger } from '../utils/logger.js';
import { providerEventDrainWorker } from '../services/providerEventDrainService.js';
import { pendingPaymentRecoveryWorker } from '../services/pendingPaymentRecoveryService.js';
import { payoutReconciliationWorker } from '../services/payoutReconciliationWorker.js';
import { nubanRetryWorker } from '../services/nubanRetryWorker.js';

export const startWalletJobs = () => {
  // Pending withdrawal timeout (every hour)
  cron.schedule('0 * * * *', async () => {
    try {
      await payoutReconciliationWorker.runOnce();
    } catch (error) {
      logger.error('Payout reconciliation could not run', {
        error: error instanceof Error ? error.message : 'Unknown error',
      });
    }
  });

  // Verified provider events (every minute)
  cron.schedule('* * * * *', async () => {
    try {
      await providerEventDrainWorker.runOnce();
    } catch (error) {
      logger.error('Provider event drain could not run', {
        error: error instanceof Error ? error.message : 'Unknown error',
      });
    }
  });
  cron.schedule('*/15 * * * *', async () => {
    try {
      await pendingPaymentRecoveryWorker.runOnce();
    } catch (error) {
      logger.error('Pending payment recovery could not run', {
        error: error instanceof Error ? error.message : 'Unknown error',
      });
    }
  });
  
  // NUBAN retry (every 5 minutes)
  cron.schedule('*/5 * * * *', async () => {
    try {
      await nubanRetryWorker.runOnce();
    } catch (error) {
      logger.error('NUBAN retry worker could not run', { error: error instanceof Error ? error.message : 'Unknown error' });
    }
  });
  logger.info('✅ Wallet jobs scheduled');
};
