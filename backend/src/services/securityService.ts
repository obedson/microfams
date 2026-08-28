import crypto from 'crypto';
import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';
import QRCode from 'qrcode';
import { backendConfiguration } from '../config/environment.js';

export class SecurityService {
  private static readonly ENCRYPTION_ALGORITHM = 'aes-256-cbc';
  private static readonly KEY = crypto.scryptSync(backendConfiguration.jwt.secret, 'salt', 32);

  private static encodeBase32(value: Buffer): string {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    let bits = '';
    for (const byte of value) bits += byte.toString(2).padStart(8, '0');
    let encoded = '';
    for (let offset = 0; offset < bits.length; offset += 5) {
      encoded += alphabet[parseInt(bits.slice(offset, offset + 5).padEnd(5, '0'), 2)];
    }
    return encoded;
  }

  private static decodeBase32(value: string): Buffer {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    const normalized = value.toUpperCase().replace(/=+$/u, '');
    if (!normalized || !/^[A-Z2-7]+$/u.test(normalized)) {
      throw new Error('MFA secret is not valid base32');
    }
    let bits = '';
    for (const character of normalized) {
      bits += alphabet.indexOf(character).toString(2).padStart(5, '0');
    }
    const bytes: number[] = [];
    for (let offset = 0; offset + 8 <= bits.length; offset += 8) {
      bytes.push(parseInt(bits.slice(offset, offset + 8), 2));
    }
    return Buffer.from(bytes);
  }

  private static totpAt(secret: string, timestampMs: number): string {
    const counter = Math.floor(timestampMs / 30_000);
    const counterBytes = Buffer.alloc(8);
    counterBytes.writeBigUInt64BE(BigInt(counter));
    const digest = crypto.createHmac('sha1', this.decodeBase32(secret))
      .update(counterBytes)
      .digest();
    const offset = digest[digest.length - 1] & 0x0f;
    const binary = (digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000;
    return binary.toString().padStart(6, '0');
  }

  /**
   * Encrypt sensitive data
   */
  static encrypt(text: string): { iv: string; encryptedData: string } {
    const iv = crypto.randomBytes(16);
    const cipher = crypto.createCipheriv(this.ENCRYPTION_ALGORITHM, this.KEY, iv);
    let encrypted = cipher.update(text);
    encrypted = Buffer.concat([encrypted, cipher.final()]);
    return {
      iv: iv.toString('hex'),
      encryptedData: encrypted.toString('hex')
    };
  }

  /**
   * Decrypt sensitive data
   */
  static decrypt(encryptedData: string, iv: string): string {
    const decipher = crypto.createDecipheriv(
      this.ENCRYPTION_ALGORITHM, 
      this.KEY, 
      Buffer.from(iv, 'hex')
    );
    let decrypted = decipher.update(Buffer.from(encryptedData, 'hex'));
    decrypted = Buffer.concat([decrypted, decipher.final()]);
    return decrypted.toString();
  }

  /**
   * Generate MFA secret and QR code
   */
  static async generateMFASecret(userId: string, email: string) {
    const secret = this.encodeBase32(crypto.randomBytes(20));
    const label = encodeURIComponent(`Micro Fams:${email}`);
    const issuer = encodeURIComponent('Micro Fams');
    const otpauthUrl = `otpauth://totp/${label}?secret=${secret}&issuer=${issuer}&algorithm=SHA1&digits=6&period=30`;
    
    const qrCodeDataUrl = await QRCode.toDataURL(otpauthUrl);
    
    // Store secret temporarily (should be confirmed first)
    await supabase
      .from('users')
      .update({ 
        temp_mfa_secret: secret 
      })
      .eq('id', userId);

    return {
      secret,
      qrCode: qrCodeDataUrl
    };
  }

  /**
   * RFC 6238 TOTP verification with one time-step of clock drift by default.
   */
  static verifyTOTP(
    secret: string,
    token: string,
    timestampMs = Date.now(),
    window = 1,
  ): boolean {
    if (!/^\d{6}$/u.test(token) || !Number.isInteger(window) || window < 0 || window > 2) return false;
    try {
      const supplied = Buffer.from(token, 'utf8');
      for (let drift = -window; drift <= window; drift += 1) {
        const expected = Buffer.from(this.totpAt(secret, timestampMs + drift * 30_000), 'utf8');
        if (crypto.timingSafeEqual(supplied, expected)) return true;
      }
    } catch {
      return false;
    }
    return false;
  }

  /**
   * Log administrative or security actions
   */
  static async logAction(data: {
    userId: string;
    action: string;
    resource: string;
    details?: any;
    ipAddress?: string;
    userAgent?: string;
    status: 'success' | 'failure' | 'warning';
  }) {
    try {
      await supabase
        .from('audit_logs')
        .insert({
          user_id: data.userId,
          action: data.action,
          resource_name: data.resource,
          details: data.details,
          ip_address: data.ipAddress,
          user_agent: data.userAgent,
          status: data.status
        });
    } catch (error) {
      logger.error('Error logging security action:', error);
    }
  }

  /**
   * Check for potential fraud patterns
   */
  static async detectFraud(userId: string, actionData: any): Promise<{ isFraud: boolean; reason?: string }> {
    // Basic fraud detection: multiple high-value bookings in short time
    if (actionData.amount > 500000) {
      const { data: recentBookings } = await supabase
        .from('bookings')
        .select('id')
        .eq('farmer_id', userId)
        .gte('created_at', new Date(Date.now() - 3600000).toISOString()); // Last hour

      if (recentBookings && recentBookings.length > 3) {
        return { isFraud: true, reason: 'High frequency of high-value transactions' };
      }
    }

    return { isFraud: false };
  }
}
