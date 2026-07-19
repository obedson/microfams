import cron from 'node-cron';
import { supabase } from '../utils/supabase.js';
import { interswitchService } from '../services/interswitchService.js';
import { walletService } from '../services/walletService.js';
import { logger } from '../utils/logger.js';

/**
 * Requirement 5.11: Pending withdrawal timeout job
 * Runs every hour
 */
const checkPendingWithdrawals = async () => {
  try {
    const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    
    const { data: pendingRequests } = await supabase
      .from('withdrawal_requests')
      .select('*')
      .eq('status', 'PENDING')
      .lt('created_at', twentyFourHoursAgo);

    if (!pendingRequests || pendingRequests.length === 0) return;

    logger.info(`Checking ${pendingRequests.length} pending withdrawals`);

    for (const request of pendingRequests) {
      try {
        if (!request.internal_ref) continue;
        
        const statusResult = await interswitchService.queryTransactionStatus(request.internal_ref);
        
        if (statusResult.status !== 'PENDING') {
          await walletService.handleWithdrawalStatusUpdate(request.internal_ref, statusResult.status);
          logger.info(`Updated withdrawal ${request.internal_ref} to ${statusResult.status}`);
        }
      } catch (error: any) {
        logger.error(`Failed to query status for withdrawal ${request.internal_ref}: ${error.message}`);
      }
    }
  } catch (error: any) {
    logger.error(`Error in checkPendingWithdrawals job: ${error.message}`);
  }
};

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
  cron.schedule('0 * * * *', checkPendingWithdrawals);
  
  // NUBAN retry (every 5 minutes)
  cron.schedule('*/5 * * * *', retryNubanProvisioning);

  // Grace period expiry (daily at 2 AM)
  cron.schedule('0 2 * * *', checkGracePeriodExpiries);
  
  logger.info('✅ Wallet jobs scheduled');
};
