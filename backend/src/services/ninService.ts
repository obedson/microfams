import { supabase } from '../utils/supabase.js';
import s3Client from '../config/s3.js';
import { PutObjectCommand } from '@aws-sdk/client-s3';
import { randomUUID } from 'node:crypto';
import {
  NINProvider,
  InterswitchNINProvider,
  MockNINProvider,
  NINVerifyResult
} from './ninProviders.js';
import { interswitchService } from './interswitchService.js';

class NINService {
  private provider: NINProvider;

  constructor() {
    const useMock = process.env.USE_MOCK_KYC === 'true' ||
                    process.env.NODE_ENV === 'test' ||
                    (!process.env.INTERSWITCH_CLIENT_ID && process.env.NODE_ENV !== 'production');

    this.provider = useMock ? new MockNINProvider() : new InterswitchNINProvider();

    if (useMock) {
      console.info('NINService: Initialized with Mock Provider');
    } else {
      console.info('NINService: Initialized with Interswitch Provider');
    }
  }

  /**
   * Step 1: Initiate NIN Lookup
   */
  async initiateVerification(nin: string, firstName: string, lastName: string, consent: boolean): Promise<{ requestRef: string; maskedPhone: string }> {
    try {
      console.log(`NINService: Calling provider for ${firstName} ${lastName} (Consent: ${consent})`);
      const result = await this.provider.verify(nin, firstName, lastName, consent);

      if (!result || result.status === 'FAILED') {
        throw new Error(result?.message || 'NIN provider returned an error');
      }

      const requestRef = randomUUID();
      console.log(`NINService: NIN found, caching with ref ${requestRef}`);

      const { error: cacheError } = await supabase
        .from('analytics_cache')
        .insert({
          cache_key: `nin_verify_${requestRef}`,
          data: result,
          expires_at: new Date(Date.now() + 15 * 60 * 1000).toISOString()
        });

      if (cacheError) {
        console.error('NINService: Supabase Cache Error:', cacheError);
        throw new Error(`Session storage failed: ${cacheError.message}`);
      }

      return {
        requestRef,
        maskedPhone: result.maskedPhone || ''
      };
    } catch (error: any) {
      console.error('NINService Error:', error.message);
      throw error;
    }
  }

  /**
   * Step 2: Validate Full Phone and Send OTP
   */
  async sendVerificationOTP(requestRef: string, fullPhone: string) {
    // 1. Get cached data
    const { data: cache, error } = await supabase
      .from('analytics_cache')
      .select('data')
      .eq('cache_key', `nin_verify_${requestRef}`)
      .single();

    if (error || !cache) throw new Error('Verification session expired or invalid');

    const ninData = cache.data as NINVerifyResult;

    // 2. Validate phone match
    // Standardize phone formats (remove leading + or 0)
    const cleanPhoneInput = fullPhone.replace(/\D/g, '').slice(-10);
    const cleanPhoneNIN = ninData.phone?.replace(/\D/g, '').slice(-10);

    if (cleanPhoneInput !== cleanPhoneNIN) {
      throw new Error('Phone number does not match NIN records');
    }

    // 3. Send OTP via Interswitch
    const otpResponse = await interswitchService.sendOTP(fullPhone, requestRef);

    // 4. Update cache with OTP reference
    await supabase
      .from('analytics_cache')
      .update({
        data: { ...ninData, otpRef: otpResponse.reference || otpResponse.otpreferenece }
      })
      .eq('cache_key', `nin_verify_${requestRef}`);

    return { success: true, message: 'OTP sent to your registered phone number' };
  }

  /**
   * Step 3: Verify OTP and Complete Profile
   */
  async verifyOTPAndComplete(userId: string, requestRef: string, otp: string) {
    // 1. Get cached data
    const { data: cache, error } = await supabase
      .from('analytics_cache')
      .select('data')
      .eq('cache_key', `nin_verify_${requestRef}`)
      .single();

    if (error || !cache) throw new Error('Verification session expired');

    const ninData = cache.data as any;

    // 2. Validate OTP
    const isValid = await interswitchService.validateOTP(otp, ninData.otpRef);
    if (!isValid && process.env.NODE_ENV !== 'development') {
      throw new Error('Invalid or expired OTP');
    }

    // 3. Confirm and Persist
    await this.confirmNIN(userId, ninData);

    // 4. Cleanup cache
    await supabase.from('analytics_cache').delete().eq('cache_key', `nin_verify_${requestRef}`);

    return { success: true };
  }

  /**
   * Requirement 3.4, 3.5, 3.6: Confirm and Persist NIN
   */
  async confirmNIN(userId: string, data: NINVerifyResult) {
    const { data: user, error: userError } = await supabase
      .from('users')
      .select('nin_verified')
      .eq('id', userId)
      .single();

    if (userError) throw userError;
    if (user.nin_verified) throw new Error('User is already verified');

    // Uniqueness check
    const { data: existing } = await supabase
      .from('users')
      .select('id')
      .eq('nin_number', data.nin)
      .eq('nin_verified', true)
      .maybeSingle();

    if (existing) throw new Error('NIN already verified on another account');

    const { error: updateError } = await supabase
      .from('users')
      .update({
        nin_number: data.nin,
        nin_verified: true,
        nin_full_name: data.fullName,
        nin_date_of_birth: data.dateOfBirth,
        nin_gender: data.gender,
        nin_address: data.address,
        nin_phone: data.phone,
        updated_at: new Date().toISOString()
      })
      .eq('id', userId);

    if (updateError) throw updateError;

    if (data.photo) {
      try {
        const photoUrl = await this.uploadProfilePictureFromUrl(userId, data.photo);
        await supabase.from('users').update({ profile_picture_url: photoUrl }).eq('id', userId);
      } catch (e) { console.warn('Photo upload failed', e); }
    }
  }

  async uploadProfilePicture(userId: string, buffer: Buffer, contentType: string) {
    const fileName = `profiles/${userId}/${randomUUID()}`;
    const command = new PutObjectCommand({
      Bucket: process.env.S3_BUCKET_NAME,
      Key: fileName,
      Body: buffer,
      ContentType: contentType,
      ACL: 'public-read'
    });

    await s3Client.send(command);
    const profileUrl = `https://${process.env.S3_BUCKET_NAME}.s3.${process.env.AWS_REGION}.amazonaws.com/${fileName}`;
    await supabase.from('users').update({ profile_picture_url: profileUrl }).eq('id', userId);
    return profileUrl;
  }

  private async uploadProfilePictureFromUrl(userId: string, url: string) {
    const response = await fetch(url);
    const buffer = Buffer.from(await response.arrayBuffer());
    const contentType = response.headers.get('content-type') || 'image/jpeg';
    return await this.uploadProfilePicture(userId, buffer, contentType);
  }
}

export const ninService = new NINService();
