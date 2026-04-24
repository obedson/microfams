import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

export class ReportingService {
  /**
   * Get comprehensive booking and revenue report
   */
  static async getBookingReport(startDate: string, endDate: string) {
    try {
      const { data: bookings, error } = await supabase
        .from('bookings')
        .select(`
          id,
          total_amount,
          status,
          payment_status,
          created_at,
          properties (
            title,
            city,
            livestock_type
          )
        `)
        .gte('created_at', startDate)
        .lte('created_at', endDate);

      if (error) throw error;

      const summary = {
        total_bookings: bookings.length,
        total_revenue: bookings
          .filter(b => b.payment_status === 'paid')
          .reduce((sum, b) => sum + parseFloat(b.total_amount), 0),
        status_breakdown: bookings.reduce((acc: any, b) => {
          acc[b.status] = (acc[b.status] || 0) + 1;
          return acc;
        }, {}),
        category_breakdown: bookings.reduce((acc: any, b) => {
          const cat = (b.properties as any)?.livestock_type || 'other';
          acc[cat] = (acc[cat] || 0) + 1;
          return acc;
        }, {})
      };

      return { summary, bookings };
    } catch (error) {
      logger.error('Error generating booking report:', error);
      throw error;
    }
  }

  /**
   * Get user engagement metrics based on audit logs
   */
  static async getEngagementReport(days: number = 30) {
    try {
      const startDate = new Date(Date.now() - days * 24 * 60 * 60 * 1000).toISOString();
      
      const { data: logs, error } = await supabase
        .from('audit_logs')
        .select('action, created_at, user_id')
        .gte('created_at', startDate);

      if (error) throw error;

      const dailyActiveUsers = new Set();
      const actionCounts: any = {};
      
      logs.forEach(log => {
        dailyActiveUsers.add(log.user_id);
        actionCounts[log.action] = (actionCounts[log.action] || 0) + 1;
      });

      return {
        period_days: days,
        unique_active_users: dailyActiveUsers.size,
        total_actions: logs.length,
        top_actions: Object.entries(actionCounts)
          .sort((a: any, b: any) => b[1] - a[1])
          .slice(0, 10)
      };
    } catch (error) {
      logger.error('Error generating engagement report:', error);
      throw error;
    }
  }

  /**
   * Get retention and churn data (BI)
   */
  static async getRetentionBI() {
    try {
      // Retention: Users who booked more than once
      const { data: repeatFarmers, error: repeatError } = await supabase.rpc('get_repeat_customers');
      
      // Churn: Users who haven't active in 60 days
      const churnThreshold = new Date(Date.now() - 60 * 24 * 60 * 60 * 1000).toISOString();
      const { count: churnedCount, error: churnError } = await supabase
        .from('users')
        .select('id', { count: 'exact', head: true })
        .lt('last_sign_in_at', churnThreshold);

      if (repeatError || churnError) throw repeatError || churnError;

      return {
        repeat_customers: repeatFarmers || [],
        estimated_churn_count: churnedCount || 0,
        analysis_date: new Date().toISOString()
      };
    } catch (error) {
      logger.error('Error generating retention BI:', error);
      throw error;
    }
  }

  /**
   * Export data to CSV format
   */
  static async exportToCSV(tableName: string, fields: string[]) {
    try {
      const { data, error } = await supabase
        .from(tableName)
        .select(fields.join(','))
        .limit(1000);

      if (error) throw error;

      if (!data || data.length === 0) return '';

      const header = fields.join(',');
      const rows = data.map(row => 
        fields.map(field => {
          const val = (row as any)[field];
          return typeof val === 'string' ? `"${val.replace(/"/g, '""')}"` : val;
        }).join(',')
      );

      return [header, ...rows].join('\n');
    } catch (error) {
      logger.error(`Error exporting ${tableName} to CSV:`, error);
      throw error;
    }
  }
}
