import supabase from '../utils/supabase.js';
import { verifyPaystackPayment } from '../utils/paystack.js';
import { evaluateGroupCreationEligibility } from '../domains/groups/groupPolicy.js';

export class GroupModel {
  static async createWithPayment(groupData: any, userId: string, organizationId: string, paymentRef: string) {
    const entryFee = Number(groupData.entry_fee);
    if (entryFee < 500 || entryFee > 10000) {
      throw new Error('Entry fee must be between ₦500 and ₦10,000');
    }

    // Verify payment
    const verification = await verifyPaystackPayment(paymentRef);
    
    if (!verification.valid) {
      throw new Error(verification.message || 'Payment verification failed');
    }

    if (verification.amount < entryFee) {
      throw new Error(`Payment amount (₦${verification.amount}) is less than entry fee (₦${entryFee})`);
    }

    // Use atomic RPC function
    const { data, error } = await supabase.rpc('create_group_with_creator', {
      p_name: groupData.name,
      p_description: groupData.description,
      p_category: groupData.category,
      p_creator_id: userId,
      p_organization_id: organizationId,
      p_state_id: groupData.state_id,
      p_lga_id: groupData.lga_id,
      p_entry_fee: entryFee,
      p_max_members: groupData.max_members || 50,
      p_payment_reference: paymentRef,
      p_amount_paid: entryFee
    });

    if (error) {
      if (error.message?.includes('already used')) {
        throw new Error('This payment reference has already been used');
      }
      throw error;
    }

    // Fetch and return the created group
    const { data: group, error: fetchError } = await supabase
      .from('groups')
      .select('*')
      .eq('id', data.group_id)
      .single();

    if (fetchError) throw fetchError;
    return group;
  }

  static async findPublicNearby(stateId?: string, lgaId?: string) {
    let query = supabase.from('public_group_directory').select('*');
    if (stateId) query = query.eq('state_id', stateId);
    if (lgaId) query = query.eq('lga_id', lgaId);
    const { data, error } = await query;
    if (error) throw error;
    return data;
  }

  static async findPublicById(id: string) {
    const query = supabase
      .from('public_group_directory')
      .select('*')
      .eq('id', id);
    const { data, error } = await query.maybeSingle();
    if (error) throw error;
    return data;
  }

  static async joinGroup(groupId: string, userId: string, organizationId: string, paymentRef: string, amount: number) {
    const { data: group } = await supabase
      .from('groups')
      .select('id')
      .eq('id', groupId)
      .eq('organization_id', organizationId)
      .maybeSingle();
    if (!group) throw new Error('Group not found in the active organization');
    const { data, error } = await supabase
      .from('group_members')
      .insert({
        organization_id: organizationId,
        group_id: groupId, 
        user_id: userId,
        payment_reference: paymentRef,
        amount_paid: amount,
        payment_status: 'pending'
      })
      .select()
      .single();
    if (error) throw error;
    return data;
  }

  static async confirmPayment(memberId: string) {
    const { data, error } = await supabase
      .rpc('confirm_group_payment_transaction', { p_member_id: memberId });
    
    if (error) throw error;
    return data;
  }

  static async getMembers(groupId: string, organizationId: string) {
    const { data, error } = await supabase
      .from('group_members')
      .select('*, groups!inner(organization_id), user:users(id, name, email, role)')
      .eq('group_id', groupId)
      .eq('groups.organization_id', organizationId)
      .eq('payment_status', 'paid');
    if (error) throw error;
    return data;
  }

  static async canCreateGroup(userId: string) {
    const { data: user, error } = await supabase
      .from('users')
      .select('nin_verified, is_platform_subscriber, role')
      .eq('id', userId)
      .single();
    if (error) throw error;
    
    // Admins can always create groups
    if (user.role === 'admin') return {
      canCreate: true,
      conditions: {
        nin_verified: true,
        is_platform_subscriber: true,
        paid_invitees: 2,
      },
    };

    // Count referred users who are platform subscribers (paid invitees)
    const { count: paidInviteesCount } = await supabase
      .from('users')
      .select('*', { count: 'exact', head: true })
      .eq('referred_by', userId)
      .eq('is_platform_subscriber', true);

    const conditions = {
      nin_verified: !!user.nin_verified,
      is_platform_subscriber: !!user.is_platform_subscriber,
      paid_invitees: paidInviteesCount || 0,
    };

    const canCreate = evaluateGroupCreationEligibility({
      role: user.role,
      ninVerified: conditions.nin_verified,
      platformSubscriber: conditions.is_platform_subscriber,
      paidInvitees: conditions.paid_invitees,
    });

    return { canCreate, conditions };
  }

  static async castMemberActionVote({ groupId, actionType, targetMemberId, voterId }: { 
    groupId: string, 
    actionType: 'SUSPEND' | 'EXPEL', 
    targetMemberId: string, 
    voterId: string 
  }) {
    // 1. Check if voter already voted for this action on this target in this group
    const { data: existingVote } = await supabase
      .from('group_member_action_votes')
      .select('id')
      .eq('group_id', groupId)
      .eq('target_user_id', targetMemberId)
      .eq('voter_id', voterId)
      .eq('action_type', actionType)
      .maybeSingle();

    if (existingVote) {
      const error: any = new Error('You have already voted for this action');
      error.statusCode = 409;
      throw error;
    }

    // 2. Prevent self-voting
    if (voterId === targetMemberId) {
      const error: any = new Error('You cannot vote on your own membership status');
      error.statusCode = 400;
      throw error;
    }

    // 3. Record the vote
    const { error: insertError } = await supabase
      .from('group_member_action_votes')
      .insert({
        group_id: groupId,
        target_user_id: targetMemberId,
        voter_id: voterId,
        action_type: actionType
      });

    if (insertError) throw insertError;

    // 4. Count current votes
    const { count: voteCount } = await supabase
      .from('group_member_action_votes')
      .select('*', { count: 'exact', head: true })
      .eq('group_id', groupId)
      .eq('target_user_id', targetMemberId)
      .eq('action_type', actionType);

    // 5. Get active member count
    const { count: memberCount } = await supabase
      .from('group_members')
      .select('*', { count: 'exact', head: true })
      .eq('group_id', groupId)
      .eq('payment_status', 'paid')
      .eq('is_active', true);

    const threshold = Math.ceil((2/3) * (memberCount || 0));
    let executed = false;

    // 6. Execute action if threshold reached
    if (voteCount && voteCount >= threshold) {
      const newStatus = actionType === 'SUSPEND' ? 'suspended' : 'expelled';
      const { error: updateError } = await supabase
        .from('group_members')
        .update({ 
          status: newStatus,
          is_active: false,
          updated_at: new Date().toISOString()
        })
        .eq('group_id', groupId)
        .eq('user_id', targetMemberId);

      if (updateError) throw updateError;
      executed = true;
    }

    return { voteCount, threshold, executed };
  }
}
