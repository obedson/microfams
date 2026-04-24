// Communication API service
const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

interface SendMessageRequest {
  booking_id: string;
  recipient_id: string;
  content?: string;
  message_type?: string;
  media_url?: string;
  media_type?: string;
}

interface Message {
  id: string;
  booking_id: string;
  sender_id: string;
  recipient_id: string;
  content: string;
  message_type: string;
  media_url?: string;
  media_type?: string;
  sent_at: string;
  read_at?: string;
  sender: {
    id: string;
    name: string;
  };
  recipient: {
    id: string;
    name: string;
  };
}

class CommunicationAPI {
  private getAuthHeaders() {
    const token = localStorage.getItem('token');
    return {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    };
  }

  async sendMessage(data: SendMessageRequest): Promise<{ success: boolean; message: Message }> {
    const response = await fetch(`${API_BASE}/communications/send`, {
      method: 'POST',
      headers: this.getAuthHeaders(),
      body: JSON.stringify(data)
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to send message');
    }

    return response.json();
  }

  async getBookingMessages(bookingId: string): Promise<{ success: boolean; messages: Message[] }> {
    const response = await fetch(`${API_BASE}/communications/booking/${bookingId}`, {
      method: 'GET',
      headers: this.getAuthHeaders()
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to get messages');
    }

    return response.json();
  }

  async markMessageAsRead(messageId: string): Promise<{ success: boolean; message: string }> {
    const response = await fetch(`${API_BASE}/communications/message/${messageId}/read`, {
      method: 'PUT',
      headers: this.getAuthHeaders()
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to mark message as read');
    }

    return response.json();
  }

  async getUnreadMessages(): Promise<{ success: boolean; unread_count: number; messages: Message[] }> {
    const response = await fetch(`${API_BASE}/communications/unread`, {
      method: 'GET',
      headers: this.getAuthHeaders()
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to get unread messages');
    }

    return response.json();
  }

  async uploadMedia(file: File): Promise<{ success: boolean; url: string }> {
    const formData = new FormData();
    formData.append('file', file);

    const response = await fetch(`${API_BASE}/communications/upload`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${localStorage.getItem('token')}`
      },
      body: formData
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to upload file');
    }

    return response.json();
  }
  async getAllUserMessages(): Promise<{ success: boolean; messages: Message[] }> {
    const response = await fetch(`${API_BASE}/communications/all`, {
      method: 'GET',
      headers: this.getAuthHeaders()
    });

    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || 'Failed to get messages');
    }

    return response.json();
  }
}

export const communicationAPI = new CommunicationAPI();
export type { Message, SendMessageRequest };
