import { PaymentRecoveryService } from '../services/paymentRecoveryService.js';
import { logAudit } from '../utils/audit.js';

/**
 * Job to process automatic payment timeout cancellations
 * This should be run periodically (e.g., every hour) to check for expired payments
 */
export class PaymentTimeoutJob {
  /**
   * Processes all expired payment bookings
   */
  static async processTimeouts(): Promise<void> {
    try {
      console.log('Starting payment timeout processing...');
      
      const results = await PaymentRecoveryService.processTimeoutCancellations();
      
      // Log job execution
      await logAudit({
        user_id: null, // System job
        action: 'payment_timeout_job_executed',
        resource_type: 'system',
        resource_id: 'payment_timeout_job',
        details: {
          processed: results.processed,
          cancelled: results.cancelled,
          errors: results.errors,
          executed_at: new Date().toISOString()
        }
      });

      if (results.errors.length > 0) {
        console.error('Payment timeout job completed with errors:', results.errors);
      } else {
        console.log(`Payment timeout job completed successfully: ${results.cancelled}/${results.processed} bookings cancelled`);
      }

    } catch (error) {
      console.error('Payment timeout job failed:', error);
      
      // Log job failure
      await logAudit({
        user_id: null,
        action: 'payment_timeout_job_failed',
        resource_type: 'system',
        resource_id: 'payment_timeout_job',
        details: {
          error: error instanceof Error ? error.message : 'Unknown error',
          executed_at: new Date().toISOString()
        }
      });
    }
  }

  /**
   * Schedules the timeout job to run periodically
   * This would typically be called from a cron job or scheduler
   */
  static scheduleJob(): void {
    // Run every hour
    setInterval(async () => {
      await this.processTimeouts();
    }, 60 * 60 * 1000); // 1 hour in milliseconds

    console.log('Payment timeout job scheduled to run every hour');
  }
}

// Export for use in other modules
export default PaymentTimeoutJob;