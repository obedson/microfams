import { getTenantHeaders } from '../api/tenantHeaders';

const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

interface FarmRecommendation {
  type: 'warning' | 'info' | 'onboarding';
  title: string;
  message: string;
}

interface ProductivityReport {
  total_records: number;
  avg_mortality_rate: number;
  total_livestock_handled: number;
  top_livestock_types: string[];
}

class FarmRecordAPI {
  private getAuthHeaders() {
    const token = localStorage.getItem('token');
    return getTenantHeaders(token, true);
  }

  async getRecommendations(): Promise<FarmRecommendation[]> {
    const response = await fetch(`${API_BASE}/farm-records/recommendations`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch recommendations');
    const result = await response.json();
    return result.data || result;
  }

  async getPropertyProductivity(propertyId: string): Promise<ProductivityReport> {
    const response = await fetch(`${API_BASE}/farm-records/property/${propertyId}/productivity`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch productivity report');
    const result = await response.json();
    return result.data || result;
  }

  async linkToBooking(recordId: string, bookingId: string): Promise<any> {
    const response = await fetch(`${API_BASE}/farm-records/${recordId}/link-booking`, {
      method: 'PATCH',
      headers: this.getAuthHeaders(),
      body: JSON.stringify({ booking_id: bookingId })
    });
    if (!response.ok) throw new Error('Failed to link record');
    return response.json();
  }
}

export const farmRecordAPI = new FarmRecordAPI();
export type { FarmRecommendation, ProductivityReport };
