const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

interface AuditLog {
  id: string;
  user_id: string;
  action: string;
  resource_name: string;
  status: string;
  created_at: string;
  users?: {
    name: string;
    email: string;
  };
}

class AdminAPI {
  private getAuthHeaders() {
    const token = localStorage.getItem('token');
    return {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    };
  }

  async getAuditLogs(): Promise<AuditLog[]> {
    const response = await fetch(`${API_BASE}/admin/audit-logs`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch audit logs');
    return response.json();
  }

  async getSecurityAlerts(): Promise<AuditLog[]> {
    const response = await fetch(`${API_BASE}/admin/security-alerts`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch security alerts');
    return response.json();
  }

  async setupMFA(): Promise<{ secret: string; qrCode: string }> {
    const response = await fetch(`${API_BASE}/admin/mfa/setup`, {
      method: 'POST',
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to setup MFA');
    return response.json();
  }

  async verifyMFA(token: string): Promise<{ success: boolean }> {
    const response = await fetch(`${API_BASE}/admin/mfa/verify`, {
      method: 'POST',
      headers: this.getAuthHeaders(),
      body: JSON.stringify({ token })
    });
    if (!response.ok) throw new Error('Invalid MFA token');
    return response.json();
  }
}

export const adminAPI = new AdminAPI();
export type { AuditLog };
