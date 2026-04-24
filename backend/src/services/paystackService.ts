import axios from 'axios';

export class PaystackService {
  private static readonly BASE_URL = 'https://api.paystack.co';
  private static readonly SECRET_KEY = process.env.PAYSTACK_SECRET_KEY!;

  private static getHeaders() {
    return {
      Authorization: `Bearer ${this.SECRET_KEY}`,
      'Content-Type': 'application/json',
    };
  }

  static async initializeTransaction(data: {
    email: string;
    amount: number;
    reference?: string;
    callback_url?: string;
  }) {
    const response = await axios.post(
      `${this.BASE_URL}/transaction/initialize`,
      data,
      { headers: this.getHeaders() }
    );
    return response.data;
  }

  static async verifyTransaction(reference: string) {
    const response = await axios.get(
      `${this.BASE_URL}/transaction/verify/${reference}`,
      { headers: this.getHeaders() }
    );
    return response.data;
  }
}
