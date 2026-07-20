import axios from 'axios';
import crypto from 'crypto';
import dotenv from 'dotenv';

dotenv.config();

export class InterswitchAuthError extends Error {
  constructor(message: string) {
    super(`InterswitchAuthError: ${message}`);
    this.name = 'InterswitchAuthError';
  }
}

class InterswitchService {
  private readonly marketplaceUrl: string;
  private readonly apiUrl: string;
  private readonly baseUrl: string;
  private readonly authUrl: string;
  private readonly clientId: string;
  private readonly clientSecret: string;
  private readonly webhookSecret: string;
  private tokenCache: { accessToken: string; expiresAt: number } | null = null;

  constructor() {
    this.marketplaceUrl = process.env.INTERSWITCH_MARKETPLACE_URL || 'https://api-marketplace-routing.k8.isw.la';
    this.apiUrl = process.env.INTERSWITCH_API_URL || 'https://api.interswitchng.com';
    this.baseUrl = this.apiUrl;
    this.authUrl = process.env.INTERSWITCH_AUTH_URL || 'https://passport-v2.k8.isw.la/passport/oauth/token';
    this.clientId = process.env.INTERSWITCH_CLIENT_ID || '';
    this.clientSecret = process.env.INTERSWITCH_CLIENT_SECRET || '';
    this.webhookSecret = process.env.INTERSWITCH_WEBHOOK_SECRET || '';

    if (!this.clientId || !this.clientSecret) {
      console.warn('Interswitch credentials missing in environment variables');
    }
  }

  /**
   * Requirement 1: OAuth2 Token Management
   */
  async getAccessToken(): Promise<string> {
    const now = Date.now();
    
    if (this.tokenCache && this.tokenCache.expiresAt > now + 60000) {
      return this.tokenCache.accessToken;
    }

    try {
      const url = this.authUrl;
      const auth = Buffer.from(`${this.clientId}:${this.clientSecret}`).toString('base64');
      
      const params = new URLSearchParams();
      params.append('grant_type', 'client_credentials');
      params.append('scope', 'profile');

      console.log(`Interswitch Passport: Requesting token from ${url}`);

      const response = await axios.post(
        url,
        params.toString(),
        {
          headers: {
            'Authorization': `Basic ${auth}`,
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json'
          },
          timeout: 15000
        }
      );

      const { access_token, expires_in } = response.data;
      this.tokenCache = {
        accessToken: access_token,
        expiresAt: now + (expires_in * 1000)
      };

      return access_token;
    } catch (error: any) {
      if (error.response?.data) {
        console.error('Interswitch Passport Error Body:', JSON.stringify(error.response.data, null, 2));
      } else {
        console.error('Interswitch Passport Connection Error:', error.message);
      }
      throw new InterswitchAuthError(error.response?.data?.error_description || error.message);
    }
  }

  /**
   * Requirement 3.1: NIN Verification
   * Documentation Match: prompt3.md (use 'id' key and TerminalId header)
   */
  async getNINFullDetails(nin: string, consent: boolean = true) {
    try {
      const token = await this.getAccessToken();
      
      const body = { 
        id: nin,
        isConsent: consent 
      };

      console.log(`Interswitch NIN: Requesting details for ${nin.slice(0,3)}******* with consent ${consent}`);
      
      const response = await axios.post(
        `${this.marketplaceUrl}/marketplace-routing/api/v1/verify/identity/nin/verify`,
        body,
        {
          headers: {
            'Authorization': `Bearer ${token}`,
            'TerminalId': process.env.INTERSWITCH_TERMINAL_ID || '3PXM0001',
            'Content-Type': 'application/json',
            'Accept': 'application/json'
          },
          timeout: 30000
        }
      );

      return response.data;
    } catch (error: any) {
      console.error('Interswitch NIN API request failed');
      
      // Provide more specific error messages
      const errorData = error.response?.data;
      let errorMessage = 'NIN verification failed';
      
      if (errorData?.message && errorData.message.trim()) {
        errorMessage = errorData.message.trim();
      } else if (errorData?.responseCode === 'ERROR') {
        errorMessage = 'Invalid NIN or NIN not found in NIMC database. Please verify the NIN is correct.';
      } else if (error.message) {
        errorMessage = error.message;
      }
      
      throw new Error(errorMessage);
    }
  }

  /**
   * Safetoken: Generate and Send OTP (Identity/Authentication Flow)
   */
  async sendOTP(phoneNumber: string, requestRef: string) {
    try {
      const token = await this.getAccessToken();
      const response = await axios.post(
        `${this.apiUrl}/api/v1/tokens/generate`,
        { 
          terminalId: process.env.INTERSWITCH_TERMINAL_ID || '3PXM0001',
          amount: '0',
          phoneNumber: phoneNumber,
          email: '',
          orderId: `MF-VER-${requestRef.slice(0, 8)}`,
          paymentCode: '90301'
        },
        {
          headers: {
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json'
          }
        }
      );

      return response.data;
    } catch (error: any) {
      console.error('Interswitch OTP send request failed');
      throw new Error('Failed to send verification code');
    }
  }

  /**
   * Safetoken: Validate OTP
   */
  async validateOTP(otp: string, phoneNumber: string) {
    try {
      const token = await this.getAccessToken();
      const response = await axios.post(
        `${this.apiUrl}/api/v1/tokens/validate`,
        { 
          terminalId: process.env.INTERSWITCH_TERMINAL_ID || '3PXM0001',
          otp: otp,
          phoneNumber: phoneNumber
        },
        {
          headers: {
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json'
          }
        }
      );

      return response.data.status === 'SUCCESS' || response.data.responseCode === '00';
    } catch (error: any) {
      console.error('Interswitch OTP validation request failed');
      return false;
    }
  }

  /**
   * Requirement 2: Provision Virtual Account
   */
  async provisionVirtualAccount(groupId: string, groupName: string) {
    try {
      const token = await this.getAccessToken();
      const response = await axios.post(
        `${this.baseUrl}/api/v1/virtual-accounts`,
        {
          accountName: groupName,
          merchantReference: groupId,
          accountType: 'STATIC'
        },
        {
          headers: {
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json'
          }
        }
      );

      const data = response.data;
      return {
        nuban: data.accountNumber,
        bankName: data.bankName,
        interswitchRef: data.reference
      };
    } catch (error: any) {
      console.error('Interswitch Virtual Account Error:', error.response?.data || error.message);
      throw new Error(error.response?.data?.message || 'Failed to provision virtual account');
    }
  }

  /**
   * Requirement 5.1: Name Enquiry
   */
  async nameEnquiry(accountNumber: string, bankCode: string) {
    try {
      const token = await this.getAccessToken();
      const response = await axios.post(
        `${this.baseUrl}/api/v1/name-enquiry`,
        { accountNumber, bankCode },
        {
          headers: {
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json'
          }
        }
      );

      return {
        accountName: response.data.accountName,
        bankCode: bankCode
      };
    } catch (error: any) {
      console.error('Interswitch Name Enquiry Error:', error.response?.data || error.message);
      throw new Error(error.response?.data?.message || 'Account validation failed');
    }
  }

  /**
   * Requirement 5.7: Single Transfer
   */
  async singleTransfer(params: {
    accountNumber: string;
    bankCode: string;
    amount: number; // in kobo
    reference: string;
    narration: string;
  }) {
    try {
      const token = await this.getAccessToken();
      const response = await axios.post(
        `${this.baseUrl}/api/v1/transfers`,
        {
          transferReference: params.reference,
          amount: params.amount,
          accountNumber: params.accountNumber,
          bankCode: params.bankCode,
          narration: params.narration
        },
        {
          headers: {
            'Authorization': `Bearer ${token}`,
            'Content-Type': 'application/json'
          }
        }
      );

      return {
        transferRef: response.data.interswitchReference,
        status: this.mapStatus(response.data.status)
      };
    } catch (error: any) {
      console.error('Interswitch Transfer Error:', error.response?.data || error.message);
      throw new Error(error.response?.data?.message || 'Transfer initiation failed');
    }
  }

  /**
   * Requirement 5.11: Query Transaction Status
   */
  async queryTransactionStatus(reference: string): Promise<{
    status: 'PENDING' | 'SUCCESS' | 'FAILED';
    amount: number;
  }> {
    try {
      const token = await this.getAccessToken();
      const response = await axios.get(
        `${this.baseUrl}/api/v1/transfers/status/${reference}`,
        {
          headers: { 'Authorization': `Bearer ${token}` }
        }
      );

      return {
        status: this.mapStatus(response.data.status),
        amount: response.data.amount
      };
    } catch (error: any) {
      console.error('Interswitch Query Error:', error.response?.data || error.message);
      throw new Error('Failed to query transaction status');
    }
  }

  private mapStatus(status: string): 'PENDING' | 'SUCCESS' | 'FAILED' {
    const s = status.toLowerCase();
    if (s === 'success' || s === 'completed') return 'SUCCESS';
    if (s === 'failed' || s === 'rejected') return 'FAILED';
    return 'PENDING';
  }

  /**
   * Requirement 3.1, 11.5: Webhook Signature Verification
   */
  verifyWebhookSignature(payload: string, signature: string): boolean {
    if (!this.webhookSecret) return false;
    
    const hmac = crypto.createHmac('sha512', this.webhookSecret);
    const computed = hmac.update(payload).digest('hex');
    
    try {
      return crypto.timingSafeEqual(
        Buffer.from(computed),
        Buffer.from(signature)
      );
    } catch {
      return false;
    }
  }
}

export const interswitchService = new InterswitchService();
