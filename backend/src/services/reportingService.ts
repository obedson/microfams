import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';
import { buildCsv } from './reportingPolicy.js';

export class ReportingService {
  static async getBookingReport(organizationId: string, startDate: string, endDate: string) {
    const { data: bookings, error } = await supabase.from('bookings').select(`
      id, total_amount, status, payment_status, created_at,
      organization_id, provider_organization_id,
      properties(title, city, livestock_type)
    `).eq('provider_organization_id', organizationId)
      .gte('created_at', startDate).lte('created_at', endDate);
    if (error) throw error;
    const rows = bookings || [];
    return {
      summary: {
        total_bookings: rows.length,
        total_revenue: rows.filter((booking) => booking.payment_status === 'paid')
          .reduce((sum, booking) => sum + Number(booking.total_amount), 0),
        status_breakdown: rows.reduce((result: Record<string, number>, booking) => {
          result[booking.status] = (result[booking.status] || 0) + 1;
          return result;
        }, {}),
        category_breakdown: rows.reduce((result: Record<string, number>, booking) => {
          const category = (booking.properties as any)?.livestock_type || 'other';
          result[category] = (result[category] || 0) + 1;
          return result;
        }, {}),
      },
      bookings: rows,
    };
  }

  static async getEngagementReport(organizationId: string, days = 30) {
    const startDate = new Date(Date.now() - days * 86400000).toISOString();
    const { data: logs, error } = await supabase.from('audit_logs')
      .select('action, created_at, user_id').eq('organization_id', organizationId).gte('created_at', startDate);
    if (error) throw error;
    const rows = logs || [];
    const activeUsers = new Set(rows.map((log) => log.user_id).filter(Boolean));
    const counts = rows.reduce((result: Record<string, number>, log) => {
      result[log.action] = (result[log.action] || 0) + 1;
      return result;
    }, {});
    return {
      period_days: days,
      unique_active_users: activeUsers.size,
      total_actions: rows.length,
      top_actions: Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 10),
    };
  }

  static async getRetentionBI(organizationId: string) {
    const threshold = new Date(Date.now() - 60 * 86400000).toISOString();
    const [bookingResult, membershipResult, activityResult] = await Promise.all([
      supabase.from('bookings').select('farmer_id').eq('provider_organization_id', organizationId),
      supabase.from('organization_memberships').select('user_id').eq('organization_id', organizationId).eq('status', 'active'),
      supabase.from('audit_logs').select('user_id').eq('organization_id', organizationId).gte('created_at', threshold),
    ]);
    if (bookingResult.error || membershipResult.error || activityResult.error) {
      throw bookingResult.error || membershipResult.error || activityResult.error;
    }
    const bookingCounts = (bookingResult.data || []).reduce((result: Record<string, number>, row) => {
      result[row.farmer_id] = (result[row.farmer_id] || 0) + 1;
      return result;
    }, {});
    const activeUsers = new Set((activityResult.data || []).map((row) => row.user_id));
    const members = membershipResult.data || [];
    return {
      repeat_customers: Object.entries(bookingCounts).filter(([, count]) => count > 1)
        .map(([user_id, booking_count]) => ({ user_id, booking_count })),
      active_member_count: members.length,
      estimated_churn_count: members.filter((member) => !activeUsers.has(member.user_id)).length,
      analysis_date: new Date().toISOString(),
    };
  }

  static async exportToCSV(organizationId: string, tableName: string, fields: string[]) {
    let query = supabase.from(tableName).select(fields.join(',')).limit(1000);
    if (tableName === 'bookings') {
      query = query.or(`organization_id.eq.${organizationId},provider_organization_id.eq.${organizationId}`);
    } else if (tableName === 'orders') {
      query = query.or(`organization_id.eq.${organizationId},supplier_organization_id.eq.${organizationId}`);
    } else {
      query = query.eq('organization_id', organizationId);
    }
    const { data, error } = await query;
    if (error) {
      logger.error('Tenant report export failed', { tableName, organizationId, error });
      throw error;
    }
    return buildCsv(fields, (data || []) as unknown as Record<string, unknown>[]);
  }
}
