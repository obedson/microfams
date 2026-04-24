import { Response } from 'express';
import { AuthRequest } from '../middleware/auth.js';
import { ContributionModel } from '../models/Contribution.js';
import { ContributionService } from '../services/contributionService.js';
import supabase from '../utils/supabase.js';

export const getUserGroupFunds = async (req: AuthRequest, res: Response) => {
  try {
    const userId = req.user.id;
    const funds = await ContributionService.getUserGroupFunds(userId);
    res.json(funds);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const calculateGroupDiscount = async (req: AuthRequest, res: Response) => {
  try {
    const { groupId } = req.params;
    const { amount } = req.query;
    
    const result = await ContributionService.calculateGroupDiscount(
      groupId, 
      parseFloat(amount as string)
    );
    res.json(result);
  } catch (error: any) {
    res.status(400).json({ error: error.message });
  }
};

export const processGroupFundPayment = async (req: AuthRequest, res: Response) => {
  try {
    const { bookingId, groupId, amount } = req.body;
    
    // Get group info
    const { data: group } = await supabase
      .from('groups')
      .select('creator_id, member_count')
      .eq('id', groupId)
      .single();

    if (!group) return res.status(404).json({ error: 'Group not found' });

    // Verify user is group admin OR platform admin
    const isGroupAdmin = group.creator_id === req.user.id;
    const isPlatformAdmin = req.user.role === 'admin';

    if (!isGroupAdmin && !isPlatformAdmin) {
      return res.status(403).json({ error: 'Only the Group Admin or Platform Admin can propose group fund payments' });
    }

    const { data: request, error: reqError } = await supabase
      .from('group_consensus_requests')
      .insert({
        group_id: groupId,
        requested_by: req.user.id,
        amount: amount,
        booking_id: bookingId,
        request_type: 'BOOKING_PAYMENT',
        status: group.member_count <= 1 ? 'PENDING' : 'PENDING' // Keep pending to let the voting endpoint process execution in unified way, or auto-execute if 1
      })
      .select()
      .single();

    if (reqError) throw reqError;

    if (group.member_count <= 1) {
      // Auto execute for single member group since 1/1 is 100%
      await supabase.rpc('process_group_fund_payment', {
        p_booking_id: bookingId, p_group_id: groupId, p_amount: amount
      });
      await supabase.from('group_consensus_requests').update({ status: 'EXECUTED' }).eq('id', request.id);
      return res.json({ message: 'Payment executed automatically for single-member group', request });
    }

    res.status(201).json({ message: 'Voting request created for group payment', request });
  } catch (error: any) {
    res.status(400).json({ error: error.message });
  }
};

export const proposeAdminChange = async (req: AuthRequest, res: Response) => {
  try {
    const { groupId, proposedAdminId } = req.body;

    // Get group info
    const { data: group } = await supabase
      .from('groups')
      .select('creator_id, member_count')
      .eq('id', groupId)
      .single();

    if (!group) return res.status(404).json({ error: 'Group not found' });

    // Verify user is group admin OR platform admin
    const isGroupAdmin = group.creator_id === req.user.id;
    const isPlatformAdmin = req.user.role === 'admin';

    if (!isGroupAdmin && !isPlatformAdmin) {
      return res.status(403).json({ error: 'Only the Group Admin or Platform Admin can propose an admin change' });
    }

    const { data: request, error: reqError } = await supabase
      .from('group_consensus_requests')
      .insert({
        group_id: groupId,
        requested_by: req.user.id,
        proposed_admin_id: proposedAdminId,
        amount: 0,
        request_type: 'ADMIN_CHANGE',
        status: 'PENDING'
      })
      .select()
      .single();

    if (reqError) throw reqError;

    if (group.member_count <= 1) {
      await supabase.from('groups').update({ creator_id: proposedAdminId }).eq('id', groupId);
      await supabase.from('group_consensus_requests').update({ status: 'EXECUTED' }).eq('id', request.id);
      return res.json({ message: 'Admin role transferred automatically for single-member group', request });
    }

    res.status(201).json({ message: 'Voting request created for admin change', request });
  } catch (error: any) {
    res.status(400).json({ error: error.message });
  }
};

export const voteOnConsensusRequest = async (req: AuthRequest, res: Response) => {
  try {
    const { requestId } = req.params;

    // Check request
    const { data: request, error: fetchError } = await supabase
      .from('group_consensus_requests')
      .select('*, groups(member_count)')
      .eq('id', requestId)
      .single();

    if (fetchError || !request) return res.status(404).json({ error: 'Request not found' });
    if (request.status !== 'PENDING') return res.status(400).json({ error: 'Request is already ' + request.status });

    // Verify user is an active member
    const { data: member } = await supabase
      .from('group_members')
      .select('id')
      .eq('group_id', request.group_id)
      .eq('user_id', req.user.id)
      .eq('member_status', 'active')
      .single();

    if (!member) return res.status(403).json({ error: 'You are not an active member of this group' });

    // Cast vote
    const { error: voteError } = await supabase
      .from('group_consensus_approvals')
      .insert({ request_id: requestId, voter_id: req.user.id });

    if (voteError && voteError.code === '23505') {
       return res.status(400).json({ error: 'You have already voted on this request' });
    }

    // Count votes
    const { count: voteCount } = await supabase
      .from('group_consensus_approvals')
      .select('*', { count: 'exact', head: true })
      .eq('request_id', requestId);

    const requiredVotes = Math.ceil((request.groups.member_count as number) * (2 / 3));

    if ((voteCount || 0) >= requiredVotes) {
      // Execute the request
      if (request.request_type === 'BOOKING_PAYMENT') {
        const { error: execError } = await supabase.rpc('process_group_fund_payment', {
          p_booking_id: request.booking_id,
          p_group_id: request.group_id,
          p_amount: request.amount
        });
        if (execError) throw execError;
        
      } else if (request.request_type === 'ADMIN_CHANGE') {
        const { error: adminUpdateError } = await supabase
          .from('groups')
          .update({ creator_id: request.proposed_admin_id })
          .eq('id', request.group_id);
        if (adminUpdateError) throw adminUpdateError;
      }
      
      // Update request to executed
      await supabase.from('group_consensus_requests').update({ status: 'EXECUTED' }).eq('id', requestId);
      return res.json({ message: 'Vote cast and request executed successfully', executed: true });
    }

    res.json({ message: 'Vote cast successfully. Still pending more votes.', executed: false, currentVotes: voteCount, requiredVotes });
  } catch (error: any) {
    res.status(400).json({ error: error.message });
  }
};

export const updateSettings = async (req: AuthRequest, res: Response) => {
  try {
    const { id } = req.params;
    const settings = req.body;

    // Verify user is group creator
    const { data: group } = await supabase
      .from('groups')
      .select('creator_id')
      .eq('id', id)
      .single();

    if (group?.creator_id !== req.user.id) {
      return res.status(403).json({ error: 'Only group creator can update settings' });
    }

    const { data, error } = await supabase
      .from('groups')
      .update({
        contribution_enabled: settings.contribution_enabled,
        contribution_amount: settings.contribution_amount,
        payment_day: settings.payment_day,
        grace_period_days: settings.grace_period_days,
        late_penalty_amount: settings.late_penalty_amount,
        late_penalty_type: settings.late_penalty_type,
        auto_suspend_after: settings.auto_suspend_after,
        auto_expel_after: settings.auto_expel_after
      })
      .eq('id', id)
      .select()
      .single();

    if (error) throw error;
    res.json(data);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const getSettings = async (req: AuthRequest, res: Response) => {
  try {
    const { id } = req.params;

    // Verify user is group creator
    const { data: group } = await supabase
      .from('groups')
      .select('creator_id')
      .eq('id', id)
      .single();

    if (group?.creator_id !== req.user.id) {
      return res.status(403).json({ error: 'Only group creator can view settings' });
    }

    const { data, error } = await supabase
      .from('groups')
      .select('contribution_enabled, contribution_amount, payment_day, grace_period_days, late_penalty_amount, late_penalty_type, auto_suspend_after, auto_expel_after')
      .eq('id', id)
      .single();

    if (error) throw error;
    res.json(data);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const createCycle = async (req: AuthRequest, res: Response) => {
  try {
    const { id } = req.params;
    const { month, year } = req.body;

    const cycle = await ContributionModel.createCycle(id, month, year);
    res.status(201).json(cycle);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const getCurrentCycle = async (req: AuthRequest, res: Response) => {
  try {
    const { id } = req.params;
    const cycle = await ContributionModel.getCurrentCycle(id);
    
    if (!cycle) {
      return res.status(404).json({ error: 'No active cycle found' });
    }

    res.json(cycle);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const getCycleDetails = async (req: AuthRequest, res: Response) => {
  try {
    const { cycleId } = req.params;
    const details = await ContributionModel.getCycleDetails(cycleId);
    res.json(details);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const makePayment = async (req: AuthRequest, res: Response) => {
  try {
    const { id } = req.params;
    const { payment_reference } = req.body;

    // Get contribution details
    const { data: contribution } = await supabase
      .from('member_contributions')
      .select('*, member:group_members(user_id)')
      .eq('id', id)
      .single();

    if (contribution?.member.user_id !== req.user.id) {
      return res.status(403).json({ error: 'Unauthorized' });
    }

    const penalty = await ContributionModel.calculatePenalty(id);
    const totalAmount = contribution.expected_amount + penalty;

    const payment = await ContributionModel.recordPayment(id, totalAmount, payment_reference);
    res.json(payment);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const getMyHistory = async (req: AuthRequest, res: Response) => {
  try {
    // Get user's group memberships
    const { data: memberships } = await supabase
      .from('group_members')
      .select('id')
      .eq('user_id', req.user.id);

    if (!memberships || memberships.length === 0) {
      return res.json([]);
    }

    const memberIds = memberships.map(m => m.id);
    const history = await ContributionModel.getMemberHistory(memberIds[0]);
    res.json(history);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const suspendMember = async (req: AuthRequest, res: Response) => {
  try {
    const { memberId } = req.params;

    const member = await ContributionModel.updateMemberStatus(memberId, 'suspended');
    res.json(member);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const expelMember = async (req: AuthRequest, res: Response) => {
  try {
    const { memberId } = req.params;

    const member = await ContributionModel.updateMemberStatus(memberId, 'expelled');
    res.json(member);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const getContributionById = async (req: AuthRequest, res: Response) => {
  try {
    const { id } = req.params;

    const { data, error } = await supabase
      .from('member_contributions')
      .select(`
        *,
        member:group_members(user_id, user:users(email, name)),
        cycle:contribution_cycles(
          cycle_month,
          cycle_year,
          deadline_date,
          group:groups(name, grace_period_days, late_penalty_amount, late_penalty_type)
        )
      `)
      .eq('id', id)
      .single();

    if (error) throw error;
    res.json(data);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const getPenalty = async (req: AuthRequest, res: Response) => {
  try {
    const { id } = req.params;
    const penalty = await ContributionModel.calculatePenalty(id);
    res.json({ penalty });
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};
