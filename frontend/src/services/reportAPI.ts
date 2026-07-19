import { getTenantHeaders } from '../api/tenantHeaders';

const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

interface BookingReportSummary {
  total_bookings: number;
  total_revenue: number;
  status_breakdown: Record<string, number>;
  category_breakdown: Record<string, number>;
}

interface EngagementReport {
  period_days: number;
  unique_active_users: number;
  total_actions: number;
  top_actions: [string, number][];
}

interface RetentionBI {
  repeat_customers: any[];
  estimated_churn_count: number;
  analysis_date: string;
}

class ReportAPI {
  private getAuthHeaders() {
    const token = localStorage.getItem('token');
    return getTenantHeaders(token);
  }

  async getBookingReport(startDate: string, endDate: string): Promise<{ summary: BookingReportSummary; bookings: any[] }> {
    const response = await fetch(`${API_BASE}/reports/bookings?start_date=${startDate}&end_date=${endDate}`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch booking report');
    return response.json();
  }

  async getEngagementReport(days: number = 30): Promise<EngagementReport> {
    const response = await fetch(`${API_BASE}/reports/engagement?days=${days}`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch engagement report');
    return response.json();
  }

  async getRetentionBI(): Promise<RetentionBI> {
    const response = await fetch(`${API_BASE}/reports/retention`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch retention BI');
    return response.json();
  }

  async exportData(table: string, fields: string[]): Promise<Blob> {
    const response = await fetch(`${API_BASE}/reports/export`, {
      method: 'POST',
      headers: {
        ...this.getAuthHeaders(),
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ table, fields })
    });
    if (!response.ok) throw new Error('Export failed');
    return response.blob();
  }
}

export const reportAPI = new ReportAPI();
export type { BookingReportSummary, EngagementReport, RetentionBI };
