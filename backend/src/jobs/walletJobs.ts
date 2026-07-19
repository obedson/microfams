import cron from 'node-cron';
import { supabase } from '../utils/supabase.js';
import { walletService } from '../services/walletService.js';
import { logger } from '../utils/logger.js';
import { payoutService } from '../domains/financial/payoutService.js';

/**
 * Requirement 5.11: Pending withdrawal timeout job
 * Runs every hour
 */
const checkPendingWithdrawals = async () => {
  try {
    const { data: expiredReservations, error: expiryError } = await supabase.rpc(
      'expire_wallet_reservations',
      { p_organization_id: null },
    );
    if (expiryError) {
      logger.error(`Failed to expire wallet reservations: ${expiryError.message}`);
    } else if (Number(expiredReservations) > 0) {
      logger.info(`Expired ${expiredReservations} wallet fund reservations`);
    }
    const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    
    const { data: pendingPayouts } = await supabase
      .from('payouts')
      .select('id, internal_reference')
      .in('state', ['submitted', 'processing'])
      .lt('updated_at', twentyFourHoursAgo);

    if (!pendingPayouts || pendingPayouts.length === 0) return;

    logger.info(`Checking ${pendingPayouts.length} pending payouts`);

    for (const payout of pendingPayouts) {
      try {
        const result = await payoutService.queryAndApply(payout.id);
        logger.info(`Reconciled payout ${payout.internal_reference} to ${result.state}`);
      } catch (error: any) {
        logger.error(`Failed to reconcile payout ${payout.internal_reference}: ${error.message}`);
      }
    }
  } catch (error: any) {
    logger.error(`Error in checkPendingWithdrawals job: ${error.message}`);
  }
};

const processProviderEvents = async () => {
  try {
    const { data: events, error } = await supabase
      .from('provider_events')
      .select('id')
      .eq('processing_state', 'received')
      .order('received_at', { ascending: true })
      .limit(50);
    if (error) throw error;
    for (const event of events ?? []) {
      try {
        await payoutService.processProviderEvent(event.id);
      } catch (eventError: any) {
        logger.error(`Failed to process provider event ${event.id}: ${eventError.message}`);
      }
    }
  } catch (error: any) {
    logger.error(`Error in provider event processing job: ${error.message}`);
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

  // Verified provider events (every minute)
  cron.schedule('* * * * *', processProviderEvents);
  
  // NUBAN retry (every 5 minutes)
  cron.schedule('*/5 * * * *', retryNubanProvisioning);

  // Grace period expiry (daily at 2 AM)
  cron.schedule('0 2 * * *', checkGracePeriodExpiries);
  
  logger.info('✅ Wallet jobs scheduled');
};
