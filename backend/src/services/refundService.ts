import axios from 'axios';

const PAYSTACK_SECRET_KEY = process.env.PAYSTACK_SECRET_KEY;
const PAYSTACK_BASE_URL = 'https://api.paystack.co';

interface RefundRequest {
  transaction: string; // Transaction reference or ID
  amount?: number; // Optional: partial refund amount in kobo
  merchant_note?: string;
  customer_note?: string;
}

export async function initiateRefund(
  transactionReference: string,
  amount?: number,
  reason?: string
): Promise<{ success: boolean; data?: any; error?: string }> {
  try {
    if (!PAYSTACK_SECRET_KEY) {
      throw new Error('Paystack secret key not configured');
    }

    const refundData: RefundRequest = {
      transaction: transactionReference,
      merchant_note: reason || 'Booking cancellation',
    };

    if (amount) {
      refundData.amount = Math.round(amount * 100); // Convert to kobo
    }

    const response = await axios.post(
      `${PAYSTACK_BASE_URL}/refund`,
      refundData,
      {
        headers: {
          Authorization: `Bearer ${PAYSTACK_SECRET_KEY}`,
          'Content-Type': 'application/json',
        },
      }
    );

    return {
      success: true,
      data: response.data.data,
    };
  } catch (error: any) {
    console.error('Refund error:', error.response?.data || error.message);
    return {
      success: false,
      error: error.response?.data?.message || 'Failed to process refund',
    };
  }
}

export async function getRefundStatus(reference: string): Promise<any> {
  try {
    if (!PAYSTACK_SECRET_KEY) {
      throw new Error('Paystack secret key not configured');
    }

    const response = await axios.get(
      `${PAYSTACK_BASE_URL}/refund/${reference}`,
      {
        headers: {
          Authorization: `Bearer ${PAYSTACK_SECRET_KEY}`,
        },
      }
    );

    return response.data.data;
  } catch (error: any) {
    console.error('Get refund status error:', error.response?.data || error.message);
    throw error;
  }
}
