import axios from 'axios';

interface InitializeTransactionInput {
  email: string;
  amount: number;
  currency?: 'NGN';
  reference?: string;
  callback_url?: string;
  metadata?: Record<string, string | number | boolean>;
}

interface CreateRefundInput {
  transaction: string;
  amount: number;
  merchant_note: string;
}

export class PaystackService {
  private static readonly BASE_URL = 'https://api.paystack.co';

  private static getHeaders() {
    const secretKey = process.env.PAYSTACK_SECRET_KEY;
    if (!secretKey) throw new Error('Paystack payment provider is not configured');
    return {
      Authorization: `Bearer ${secretKey}`,
      'Content-Type': 'application/json',
    };
  }

  static async initializeTransaction(data: InitializeTransactionInput) {
    const response = await axios.post(
      `${this.BASE_URL}/transaction/initialize`,
      data,
      { headers: this.getHeaders(), timeout: 15000 },
    );
    return response.data;
  }

  static async verifyTransaction(reference: string) {
    const response = await axios.get(
      `${this.BASE_URL}/transaction/verify/${encodeURIComponent(reference)}`,
      { headers: this.getHeaders(), timeout: 15000 },
    );
    return response.data;
  }

  static async createRefund(data: CreateRefundInput) {
    const response = await axios.post(
      `${this.BASE_URL}/refund`,
      data,
      { headers: this.getHeaders(), timeout: 15000 },
    );
    return response.data;
  }

  static async fetchRefund(reference: string) {
    const response = await axios.get(
      `${this.BASE_URL}/refund/${encodeURIComponent(reference)}`,
      { headers: this.getHeaders(), timeout: 15000 },
    );
    return response.data;
  }
}
