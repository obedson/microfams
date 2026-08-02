import { Response } from 'express';
import { supabase } from '../utils/supabase.js';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';

class GroupAdminController {
  /**
   * Requirement 5.1 - 5.7: Get Admin Dashboard Data
   */
  async getAdminDashboard(req: TenantRequest, res: Response) {
    const groupId = req.params.id;
    try {
      const [membershipResult, tenantMembershipResult] = await Promise.all([
        supabase.from('group_members').select('role')
          .eq('organization_id', req.tenant!.id).eq('group_id', groupId)
          .eq('user_id', req.user!.id).eq('status', 'active').maybeSingle(),
        supabase.from('organization_memberships').select('role,permissions')
          .eq('organization_id', req.tenant!.id).eq('user_id', req.user!.id)
          .eq('status', 'active').maybeSingle(),
      ]);
      const tenantMembership = tenantMembershipResult.data;
      const canManage = membershipResult.data?.role === 'owner'
        || tenantMembership?.role === 'owner' || tenantMembership?.role === 'admin'
        || (tenantMembership?.permissions ?? []).includes('groups.membership.discipline.manage')
        || (tenantMembership?.permissions ?? []).includes('groups.governance.manage');
      if (!canManage) {
        return res.status(403).json({ error: 'Access denied. Group admin permissions required.' });
      }

      // 2. Fetch Group Details & Stats
      const { data: group } = await supabase
        .from('groups')
        .select('*, states(name), lgas(name)')
        .eq('id', groupId)
        .eq('organization_id', req.tenant!.id)
        .single();
      if (!group) return res.status(404).json({ error: 'Group not found' });

      const { count: memberCount } = await supabase
        .from('group_members')
        .select('*', { count: 'exact', head: true })
        .eq('organization_id', req.tenant!.id)
        .eq('group_id', groupId)
        .eq('status', 'active');

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
        .eq('organization_id', req.tenant!.id)
        .eq('group_id', groupId);

      const { data: disciplineCases } = await supabase
        .from('group_member_discipline_cases')
        .select('id,membership_id,target_user_id,proposed_action,state,reason_code,public_notice,response_due_at,proposal_id,appeal_deadline,created_at')
        .eq('organization_id', req.tenant!.id)
        .eq('group_id', groupId)
        .order('created_at', { ascending: false })
        .limit(50);

      res.json({
        group,
        stats: { memberCount },
        wallet: { nuban, transactions },
        members,
        disciplineCases: disciplineCases ?? []
      });
    } catch (error: any) {
      res.status(500).json({ error: error.message });
    }
  }

  /**
   * Requirement 5.10, 5.11: Update Group
   */
  async updateGroup(req: TenantRequest, res: Response) {
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
      const [membershipResult, tenantMembershipResult] = await Promise.all([
        supabase.from('group_members').select('role')
          .eq('organization_id', req.tenant!.id).eq('group_id', groupId)
          .eq('user_id', req.user!.id).eq('status', 'active').maybeSingle(),
        supabase.from('organization_memberships').select('role,permissions')
          .eq('organization_id', req.tenant!.id).eq('user_id', req.user!.id)
          .eq('status', 'active').maybeSingle(),
      ]);
      const tenantMembership = tenantMembershipResult.data;
      const canManage = membershipResult.data?.role === 'owner'
        || tenantMembership?.role === 'owner' || tenantMembership?.role === 'admin'
        || (tenantMembership?.permissions ?? []).includes('groups.membership.manage');
      if (!canManage) {
        return res.status(403).json({ error: 'Access denied' });
      }

      const { error: updateError } = await supabase
        .from('groups')
        .update({ ...value, updated_at: new Date().toISOString() })
        .eq('id', groupId)
        .eq('organization_id', req.tenant!.id);

      if (updateError) throw updateError;

      res.json({ success: true, message: 'Group updated successfully' });
    } catch (error: any) {
      res.status(500).json({ error: error.message });
    }
  }

  /**
   * Requirement 6.1 - 6.7: Get Member Dashboard Data
   */
  async getMemberDashboard(req: TenantRequest, res: Response) {
    const groupId = req.params.id;
    try {
      // 1. Verify membership (paid member)
      const { data: membership } = await supabase
        .from('group_members')
        .select('*')
        .eq('organization_id', req.tenant!.id)
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
        .eq('organization_id', req.tenant!.id)
        .single();
      if (!group) return res.status(404).json({ error: 'Group not found' });

      // 3. Fetch Member Names List
      const { data: members } = await supabase
        .from('group_members')
        .select('user:users(name)')
        .eq('organization_id', req.tenant!.id)
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
