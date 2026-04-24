import supabase from '../utils/supabase.js';
import bcrypt from 'bcryptjs';
import { User } from '../types/index.js';

export class UserModel {
  static async create(userData: {
    email: string;
    password: string;
    name: string;
    role: 'farmer' | 'owner';
    phone?: string;
    referredBy?: string;
  }): Promise<User> {
    const hashedPassword = await bcrypt.hash(userData.password, 10);
    
    // Generate unique referral code
    const referralCode = Math.random().toString(36).substring(2, 10).toUpperCase();
    
    // Find referrer if code provided
    let referrerId = null;
    if (userData.referredBy) {
      const { data: referrer } = await supabase
        .from('users')
        .select('id')
        .eq('referral_code', userData.referredBy)
        .single();
      referrerId = referrer?.id;
    }
    
    const { data, error } = await supabase
      .from('users')
      .insert({
        email: userData.email,
        password: hashedPassword,
        name: userData.name,
        role: userData.role,
        phone: userData.phone,
        referral_code: referralCode,
        referred_by: referrerId,
      })
      .select()
      .single();

    if (error) throw error;
    return data;
  }

  static async findByEmail(email: string): Promise<User | null> {
    const { data, error } = await supabase
      .from('users')
      .select('*')
      .eq('email', email)
      .single();

    if (error) return null;
    return data;
  }

  static async findById(id: string): Promise<User | null> {
    const { data, error } = await supabase
      .from('users')
      .select('*')
      .eq('id', id)
      .single();

    if (error) return null;
    return data;
  }

  static async verifyPassword(plainPassword: string, hashedPassword: string): Promise<boolean> {
    return bcrypt.compare(plainPassword, hashedPassword);
  }

  static async updateResetToken(email: string, token: string, expires: Date): Promise<void> {
    const { error } = await supabase
      .from('users')
      .update({
        reset_token: token,
        reset_token_expires: expires.toISOString(),
      })
      .eq('email', email);

    if (error) throw error;
  }

  static async findByResetToken(token: string): Promise<User | null> {
    const { data, error } = await supabase
      .from('users')
      .select('*')
      .eq('reset_token', token)
      .gt('reset_token_expires', new Date().toISOString())
      .single();

    if (error) return null;
    return data;
  }

  static async updatePassword(id: string, newPassword: string): Promise<void> {
    const hashedPassword = await bcrypt.hash(newPassword, 10);
    
    const { error } = await supabase
      .from('users')
      .update({
        password: hashedPassword,
        reset_token: null,
        reset_token_expires: null,
      })
      .eq('id', id);

    if (error) throw error;
  }
}
