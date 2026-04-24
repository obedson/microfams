import axios from 'axios';

const PAYSTACK_SECRET_KEY = process.env.PAYSTACK_SECRET_KEY;
const PAYSTACK_BASE_URL = 'https://api.paystack.co';

interface PaystackVerificationResponse {
  status: boolean;
  message: string;
  data: {
    id: number;
    status: 'success' | 'failed' | 'abandoned';
    reference: string;
    amount: number;
    currency: string;
    paid_at: string;
    customer: {
      email: string;
    };
  };
}

export async function verifyPaystackPayment(reference: string): Promise<{
  valid: boolean;
  amount: number;
  email: string;
  message?: string;
}> {
  const maxRetries = 3;
  let lastError: any;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      if (!PAYSTACK_SECRET_KEY) {
        throw new Error('Paystack secret key not configured');
      }

      const response = await axios.get<PaystackVerificationResponse>(
        `${PAYSTACK_BASE_URL}/transaction/verify/${reference}`,
        {
          headers: {
            Authorization: `Bearer ${PAYSTACK_SECRET_KEY}`,
          },
          timeout: 10000, // 10 second timeout
        }
      );

      const { data } = response.data;

      if (data.status !== 'success') {
        return {
          valid: false,
          amount: 0,
          email: '',
          message: 'Payment not successful',
        };
      }

      // Convert from kobo to naira
      const amountInNaira = data.amount / 100;

      return {
        valid: true,
        amount: amountInNaira,
        email: data.customer.email,
      };
    } catch (error: any) {
      lastError = error;
      const isNetworkError = error.code === 'ECONNREFUSED' || 
                           error.code === 'ENOTFOUND' || 
                           error.message?.includes('fetch failed') ||
                           error.message?.includes('network');

      console.error(`Payment verification attempt ${attempt}/${maxRetries} failed:`, 
                   error.response?.data || error.message);

      // Don't retry on auth errors or invalid reference
      if (error.response?.status === 401 || error.response?.status === 404) {
        break;
      }

      // Wait before retry (exponential backoff)
      if (attempt < maxRetries && isNetworkError) {
        await new Promise(resolve => setTimeout(resolve, Math.pow(2, attempt) * 1000));
      }
    }
  }

  return {
    valid: false,
    amount: 0,
    email: '',
    message: lastError?.response?.data?.message || 'Network error - payment verification failed after retries',
  };
}

