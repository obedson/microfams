import cron from 'node-cron';
import { supabase } from '../utils/supabase.js';
import { walletService } from '../services/walletService.js';
import { logger } from '../utils/logger.js';
import { providerEventDrainWorker } from '../services/providerEventDrainService.js';
import { pendingPaymentRecoveryWorker } from '../services/pendingPaymentRecoveryService.js';
import { payoutReconciliationWorker } from '../services/payoutReconciliationWorker.js';


/**
 * Requirement 2.3: NUBAN retry job
 * Runs every 5 minutes
 */
const retryNubanProvisioning = async () => {
  try {
    const { data: pendingGvas } = await supabase
      .from('group_virtual_accounts')
      .select('*, groups(name, organization_id)')
      .eq('status', 'PENDING')
      .lt('retry_count', 3);

    if (!pendingGvas || pendingGvas.length === 0) return;

    for (const gva of pendingGvas) {
      // Exponential backoff: 1min, 2min, 4min
      const delay = Math.pow(2, gva.retry_count) * 60 * 1000;
      const lastAttempt = new Date(gva.updated_at).getTime();
      
      if (Date.now() - lastAttempt < delay) continue;

      try {
        const group = gva.groups as any;
        await walletService.provisionGroupNuban(gva.group_id, group.name);
        logger.info(`Successfully provisioned NUBAN for group ${gva.group_id} on retry ${gva.retry_count + 1}`);
      } catch (error: any) {
        await supabase
          .from('group_virtual_accounts')
          .update({ 
            retry_count: gva.retry_count + 1,
            updated_at: new Date().toISOString()
          })
          .eq('id', gva.id)
          .eq('organization_id', gva.organization_id);
        logger.error(`Failed NUBAN retry ${gva.retry_count + 1} for group ${gva.group_id}`);
      }
    }
  } catch (error: any) {
    logger.error(`Error in retryNubanProvisioning job: ${error.message}`);
  }
};

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
  cron.schedule('*/5 * * * *', retryNubanProvisioning);

  // Grace period expiry (daily at 2 AM)
  cron.schedule('0 2 * * *', checkGracePeriodExpiries);
  
  logger.info('✅ Wallet jobs scheduled');
};
