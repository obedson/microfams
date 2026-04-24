const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

interface GroupFund {
  group_id: string;
  group_name: string;
  available_balance: number;
  discount_rate: number;
}

interface GroupDiscount {
  original_amount: number;
  discounted_amount: number;
  saving: number;
  discount_rate: number;
  can_afford: boolean;
}

class ContributionAPI {
  private getAuthHeaders() {
    const token = localStorage.getItem('token');
    return {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    };
  }

  async getUserGroupFunds(): Promise<GroupFund[]> {
    const response = await fetch(`${API_BASE}/user/group-funds`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch group funds');
    return response.json();
  }

  async calculateGroupDiscount(groupId: string, amount: number): Promise<GroupDiscount> {
    const response = await fetch(`${API_BASE}/groups/${groupId}/booking-discount?amount=${amount}`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to calculate discount');
    return response.json();
  }

  async payWithGroupFunds(bookingId: string, groupId: string, amount: number): Promise<any> {
    const response = await fetch(`${API_BASE}/bookings/pay-with-group-funds`, {
      method: 'POST',
      headers: this.getAuthHeaders(),
      body: JSON.stringify({ bookingId, groupId, amount })
    });
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to process group fund payment');
    }
    return response.json();
  }
}

export const contributionAPI = new ContributionAPI();
export type { GroupFund, GroupDiscount };
