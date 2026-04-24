import axios from 'axios';
import crypto from 'crypto';
import dotenv from 'dotenv';
import { v4 as uuidv4 } from 'uuid';

dotenv.config();

export class OnePipeApiError extends Error {
  constructor(message: string, public statusCode?: number, public data?: any) {
    super(`OnePipeApiError: ${message}`);
    this.name = 'OnePipeApiError';
  }
}

class OnePipeService {
  private readonly baseUrl: string;
  private readonly apiKey: string;
  private readonly apiSecret: string;

  constructor() {
    this.baseUrl = process.env.ONEPIPE_BASE_URL || 'https://api.onepipe.io/v2';
    this.apiKey = process.env.ONEPIPE_API_KEY || '';
    this.apiSecret = process.env.ONEPIPE_SECRET || '';

    if (!this.apiKey || !this.apiSecret) {
      console.warn('OnePipe credentials missing in environment variables');
    }
  }

  /**
   * Generates a signature for OnePipe requests
   * Formula: MD5(request_ref;api_secret)
   */
  private generateSignature(requestRef: string): string {
    return crypto
      .createHash('md5')
      .update(`${requestRef};${this.apiSecret}`)
      .digest('hex');
  }

  /**
   * Core transaction method
   */
  async transact(body: any): Promise<any> {
    try {
      const signature = this.generateSignature(body.request_ref);
      
      const response = await axios.post(
        `${this.baseUrl}/transact`,
        body,
        {
          headers: {
            'Authorization': `Bearer ${this.apiKey}`,
            'Signature': signature,
            'Content-Type': 'application/json'
          },
          timeout: 30000
        }
      );

      return response.data;
    } catch (error: any) {
      console.error('OnePipe API Error:', error.response?.data || error.message);
      throw new OnePipeApiError(
        error.response?.data?.message || error.message,
        error.response?.status,
        error.response?.data
      );
    }
  }

  /**
   * NIN Lookup (Mid)
   * This handles the initial request which may return 'WaitingForOTP'
   */
  async lookupNIN(params: {
    nin: string;
    firstName: string;
    lastName: string;
    email: string;
    phone: string;
    dob: string;
  }) {
    const body = {
      request_ref: uuidv4(),
      request_type: 'lookup_nin_mid',
      auth: {
        type: 'nin',
        secure: params.nin,
        auth_provider: 'Demoprovider', // Use real provider in prod
        route_mode: null
      },
      transaction: {
        mock_mode: process.env.NODE_ENV === 'production' ? 'live' : 'mock',
        transaction_ref: uuidv4(),
        transaction_desc: 'NIN Verification',
        amount: 0,
        customer: {
          customer_ref: `CUST_${uuidv4().slice(0, 8)}`,
          firstname: params.firstName,
          surname: params.lastName,
          email: params.email,
          mobile_no: params.phone
        },
        details: {
          dob: params.dob
        }
      }
    };

    return await this.transact(body);
  }

  /**
   * Validate OTP for NIN/BVN lookups
   */
  async validateOTP(requestRef: string, otp: string) {
    const body = {
      request_ref: uuidv4(),
      request_type: 'validate_otp',
      auth: {
        type: 'otp',
        secure: otp,
        auth_provider: 'Demoprovider',
        route_mode: null
      },
      transaction: {
        transaction_ref_parent: requestRef,
        amount: 0
      }
    };

    return await this.transact(body);
  }

  /**
   * Name Enquiry
   */
  async nameEnquiry(accountNumber: string, bankCode: string) {
    const body = {
      request_ref: uuidv4(),
      request_type: 'account_lookup',
      transaction: {
        mock_mode: process.env.NODE_ENV === 'production' ? 'live' : 'mock',
        transaction_ref: uuidv4(),
        details: {
          account_number: accountNumber,
          bank_code: bankCode
        }
      }
    };

    const response = await this.transact(body);
    return {
      accountName: response.data.account_name,
      bankCode: bankCode
    };
  }

  /**
   * Provision Virtual Account
   */
  async provisionVirtualAccount(groupId: string, groupName: string) {
    const body = {
      request_ref: uuidv4(),
      request_type: 'virtual_account',
      transaction: {
        mock_mode: process.env.NODE_ENV === 'production' ? 'live' : 'mock',
        transaction_ref: groupId,
        transaction_desc: `Virtual Account for Group ${groupName}`,
        amount: 0,
        details: {
          name: groupName,
          // OnePipe specific fields
        }
      }
    };

    const response = await this.transact(body);
    return {
      nuban: response.data.account_number,
      bankName: response.data.bank_name,
      providerRef: response.data.provider_reference
    };
  }

  /**
   * Disbursement (Single Transfer)
   */
  async singleTransfer(params: {
    accountNumber: string;
    bankCode: string;
    amount: number; // in kobo
    reference: string;
    narration: string;
  }) {
    const body = {
      request_ref: uuidv4(),
      request_type: 'disburse',
      transaction: {
        mock_mode: process.env.NODE_ENV === 'production' ? 'live' : 'mock',
        transaction_ref: params.reference,
        transaction_desc: params.narration,
        amount: params.amount,
        details: {
          destination_account_number: params.accountNumber,
          destination_bank_code: params.bankCode
        }
      }
    };

    const response = await this.transact(body);
    return {
      transferRef: response.data.provider_reference,
      status: this.mapStatus(response.status)
    };
  }

  /**
   * Transaction Status Query
   */
  async queryTransactionStatus(reference: string): Promise<{
    status: 'PENDING' | 'SUCCESS' | 'FAILED';
    amount: number;
  }> {
    const body = {
      request_ref: uuidv4(),
      request_type: 'transaction_query',
      transaction: {
        transaction_ref: reference
      }
    };

    const response = await this.transact(body);
    return {
      status: this.mapStatus(response.status),
      amount: response.data.amount // in kobo
    };
  }

  private mapStatus(onePipeStatus: string): 'PENDING' | 'SUCCESS' | 'FAILED' {
    const status = onePipeStatus.toLowerCase();
    if (status === 'successful' || status === 'success') return 'SUCCESS';
    if (status === 'failed') return 'FAILED';
    return 'PENDING';
  }

  /**
   * Webhook Signature Verification
   */
  verifyWebhookSignature(body: any, signature: string): boolean {
    const computed = this.generateSignature(body);
    return crypto.timingSafeEqual(
      Buffer.from(computed),
      Buffer.from(signature)
    );
  }
}

export const onePipeService = new OnePipeService();
