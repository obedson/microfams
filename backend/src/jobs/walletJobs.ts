import cron from 'node-cron';
import { supabase } from '../utils/supabase.js';
import { walletService } from '../services/walletService.js';
import { logger } from '../utils/logger.js';
import { providerEventDrainWorker } from '../services/providerEventDrainService.js';
import { pendingPaymentRecoveryWorker } from '../services/pendingPaymentRecoveryService.js';
import { payoutReconciliationWorker } from '../services/payoutReconciliationWorker.js';
import { nubanRetryWorker } from '../services/nubanRetryWorker.js';



/**
 * Requirement 9.4, 9.5: Grace period expiry job
 * Runs daily at 2:00 AM
 */
const checkGracePeriodExpiries = async () => {
  try {
    const today = new Date().toISOString();
    
    // Find users whose grace period has ended and still have balance
    // This assumes users table has grace_period_ends_at column
    const { data: expiredUsers } = await supabase
      .from('users')
      .select('id')
      .in('status', ['suspended', 'deleted'])
      .lt('grace_period_ends_at', today);

    if (!expiredUsers || expiredUsers.length === 0) return;

    logger.info(`Checking grace period expiry for ${expiredUsers.length} users`);

    for (const user of expiredUsers) {
      await walletService.handleGracePeriodExpiry(user.id);
    }
  } catch (error: any) {
    logger.error(`Error in checkGracePeriodExpiries job: ${error.message}`);
  }
};

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

  // Grace period expiry (daily at 2 AM)
  cron.schedule('0 2 * * *', checkGracePeriodExpiries);
  
  logger.info('✅ Wallet jobs scheduled');
};
