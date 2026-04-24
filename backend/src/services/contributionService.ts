import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

export class ContributionService {
  /**
   * Get user's available group funds for booking
   */
  static async getUserGroupFunds(userId: string) {
    try {
      // Get all groups where the user is an active member
      const { data: memberships, error } = await supabase
        .from('group_members')
        .select(`
          group_id,
          groups (
            id,
            name,
            group_fund_balance,
            member_count,
            group_booking_discount
          )
        `)
        .eq('user_id', userId)
        .eq('member_status', 'active');

      if (error) throw error;

      return memberships?.map((m: any) => ({
        group_id: m.group_id,
        group_name: m.groups.name,
        available_balance: m.groups.group_fund_balance || 0,
        discount_rate: m.groups.group_booking_discount || 5 // Default 5% discount
      })) || [];
    } catch (error) {
      logger.error('Error getting user group funds:', error);
      return [];
    }
  }

  /**
   * Calculate group booking discount
   */
  static async calculateGroupDiscount(groupId: string, bookingAmount: number) {
    try {
      const { data: group, error } = await supabase
        .from('groups')
        .select('group_booking_discount, group_fund_balance')
        .eq('id', groupId)
        .single();

      if (error || !group) throw new Error('Group not found');

      const discountRate = parseFloat(group.group_booking_discount || '5');
      const discountAmount = bookingAmount * (discountRate / 100);
      const discountedPrice = bookingAmount - discountAmount;

      return {
        original_amount: bookingAmount,
        discounted_amount: discountedPrice,
        saving: discountAmount,
        discount_rate: discountRate,
        can_afford: (group.group_fund_balance || 0) >= discountedPrice
      };
    } catch (error) {
      logger.error('Error calculating group discount:', error);
      throw error;
    }
  }

  /**
   * Process payment using group funds
   */
  static async processGroupFundPayment(bookingId: string, groupId: string, amount: number) {
    try {
      // Using a RPC call to ensure atomicity
      const { data, error } = await supabase.rpc('process_group_fund_payment', {
        p_booking_id: bookingId,
        p_group_id: groupId,
        p_amount: amount
      });

      if (error) throw error;
      return data;
    } catch (error) {
      logger.error('Error processing group fund payment:', error);
      throw error;
    }
  }
}
