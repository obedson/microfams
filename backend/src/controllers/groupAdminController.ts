import { Request, Response } from 'express';
import { supabase } from '../utils/supabase.js';
import { GroupModel } from '../models/Group.js';
import Joi from 'joi';

interface AuthRequest extends Request {
  user?: {
    id: string;
    email: string;
    role: string;
  };
}

class GroupAdminController {
  /**
   * Requirement 5.1 - 5.7: Get Admin Dashboard Data
   */
  async getAdminDashboard(req: AuthRequest, res: Response) {
    const groupId = req.params.id;
    try {
      // 1. Verify access (Owner or Platform Admin)
      const { data: membership } = await supabase
        .from('group_members')
        .select('role')
        .eq('group_id', groupId)
        .eq('user_id', req.user!.id)
        .single();

      if (req.user!.role !== 'admin' && membership?.role !== 'owner') {
        return res.status(403).json({ error: 'Access denied. Group admin permissions required.' });
      }

      // 2. Fetch Group Details & Stats
      const { data: group } = await supabase
        .from('groups')
        .select('*, states(name), lgas(name)')
        .eq('id', groupId)
        .single();

      const { count: memberCount } = await supabase
        .from('group_members')
        .select('*', { count: 'exact', head: true })
        .eq('group_id', groupId)
        .eq('payment_status', 'paid');

      // 3. Fetch Wallet/NUBAN Details
      const { data: nuban } = await supabase
        .from('group_virtual_accounts')
        .select('*')
        .eq('group_id', groupId)
        .maybeSingle();

      // 4. Fetch Recent Transactions (Collection/Group Withdrawal)
      const { data: transactions } = await supabase
        .from('wallet_transactions')
        .select('*')
        .or(`source_id.eq.${groupId},destination_id.eq.${groupId}`)
        .order('created_at', { ascending: false })
        .limit(10);

      // 5. Fetch Members with Statuses
      const { data: members } = await supabase
        .from('group_members')
        .select('*, user:users(id, name, email, profile_picture_url, nin_verified)')
        .eq('group_id', groupId);

      // 6. Fetch Pending Action Votes
      const { data: pendingVotes } = await supabase
        .from('group_member_action_votes')
        .select('*, target:users!target_user_id(name)')
        .eq('group_id', groupId);

      res.json({
        group,
        stats: { memberCount },
        wallet: { nuban, transactions },
        members,
        pendingVotes
      });
    } catch (error: any) {
      res.status(500).json({ error: error.message });
    }
  }

  /**
   * Requirement 5.10, 5.11: Update Group
   */
  async updateGroup(req: AuthRequest, res: Response) {
    const groupId = req.params.id;
    const schema = Joi.object({
      name: Joi.string(),
      description: Joi.string(),
      category: Joi.string(),
      max_members: Joi.number().integer().min(1)
    });

    const { error, value } = schema.validate(req.body);
    if (error) return res.status(400).json({ error: error.details[0].message });

    try {
      // Permission check
      const { data: membership } = await supabase
        .from('group_members')
        .select('role')
        .eq('group_id', groupId)
        .eq('user_id', req.user!.id)
        .single();

      if (req.user!.role !== 'admin' && membership?.role !== 'owner') {
        return res.status(403).json({ error: 'Access denied' });
      }

      const { error: updateError } = await supabase
        .from('groups')
        .update({ ...value, updated_at: new Date().toISOString() })
        .eq('id', groupId);

      if (updateError) throw updateError;

      res.json({ success: true, message: 'Group updated successfully' });
    } catch (error: any) {
      res.status(500).json({ error: error.message });
    }
  }

  /**
   * Requirement 5.8, 5.9: Cast Member Action Vote
   */
  async castVote(req: AuthRequest, res: Response) {
    const { id: groupId, memberId: targetMemberId } = req.params;
    const { actionType } = req.body;

    if (!['SUSPEND', 'EXPEL'].includes(actionType)) {
      return res.status(400).json({ error: 'Invalid action type' });
    }

    try {
      const result = await GroupModel.castMemberActionVote({
        groupId,
        actionType,
        targetMemberId,
        voterId: req.user!.id
      });

      res.json(result);
    } catch (error: any) {
      const status = error.statusCode || 500;
      res.status(status).json({ error: error.message });
    }
  }

  /**
   * Requirement 5.6: Get Votes
   */
  async getVotes(req: AuthRequest, res: Response) {
    try {
      const { data, error } = await supabase
        .from('group_member_action_votes')
        .select('*, target:users!target_user_id(name), voter:users!voter_id(name)')
        .eq('group_id', req.params.id);

      if (error) throw error;
      res.json(data);
    } catch (error: any) {
      res.status(500).json({ error: error.message });
    }
  }

  /**
   * Requirement 6.1 - 6.7: Get Member Dashboard Data
   */
  async getMemberDashboard(req: AuthRequest, res: Response) {
    const groupId = req.params.id;
    try {
      // 1. Verify membership (paid member)
      const { data: membership } = await supabase
        .from('group_members')
        .select('*')
        .eq('group_id', groupId)
        .eq('user_id', req.user!.id)
        .eq('payment_status', 'paid')
        .single();

      if (!membership) {
        return res.status(403).json({ error: 'Access denied. Paid membership required.' });
      }

      // 2. Fetch Read-only Group Info
      const { data: group } = await supabase
        .from('groups')
        .select('id, name, description, category, group_fund_balance, created_at')
        .eq('id', groupId)
        .single();

      // 3. Fetch Member Names List
      const { data: members } = await supabase
        .from('group_members')
        .select('user:users(name)')
        .eq('group_id', groupId)
        .eq('payment_status', 'paid');

      res.json({
        group,
        membership,
        members: members?.map(m => (m.user as any).name)
      });
    } catch (error: any) {
      res.status(500).json({ error: error.message });
    }
  }
}

export const groupAdminController = new GroupAdminController();
