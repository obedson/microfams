import supabase from '../utils/supabase.js';

export class ContributionModel {
  // Create new contribution cycle
  static async createCycle(groupId: string, month: number, year: number, organizationId?: string) {
    let groupQuery = supabase
      .from('groups')
      .select('contribution_amount, payment_day, member_count, organization_id')
      .eq('id', groupId);
    if (organizationId) groupQuery = groupQuery.eq('organization_id', organizationId);
    const { data: group } = await groupQuery.single();

    if (!group?.contribution_amount) throw new Error('Contributions not enabled');

    const deadlineDate = new Date(year, month - 1, group.payment_day);
    const expectedAmount = group.contribution_amount * group.member_count;

    const { data, error } = await supabase
      .from('contribution_cycles')
      .insert({
        group_id: groupId,
        organization_id: group.organization_id,
        cycle_month: month,
        cycle_year: year,
        expected_amount: expectedAmount,
        outstanding_amount: expectedAmount,
        deadline_date: deadlineDate.toISOString()
      })
      .select()
      .single();

    if (error) throw error;

    // Create member contributions
    const { data: members } = await supabase
      .from('group_members')
      .select('id')
      .eq('group_id', groupId)
      .eq('member_status', 'active');

    if (members) {
      await supabase.from('member_contributions').insert(
        members.map(m => ({
          cycle_id: data.id,
          member_id: m.id,
          organization_id: group.organization_id,
          expected_amount: group.contribution_amount
        }))
      );
    }

    return data;
  }

  // Get current active cycle
  static async getCurrentCycle(groupId: string, organizationId?: string) {
    let query = supabase
      .from('contribution_cycles')
      .select('*')
      .eq('group_id', groupId)
      .eq('status', 'active')
      .order('created_at', { ascending: false })
      .limit(1);
    if (organizationId) query = query.eq('organization_id', organizationId);
    const { data, error } = await query.single();

    if (error && error.code !== 'PGRST116') throw error;
    return data;
  }

  // Get cycle with member payments
  static async getCycleDetails(cycleId: string, organizationId?: string) {
    let cycleQuery = supabase
      .from('contribution_cycles')
      .select('*')
      .eq('id', cycleId);
    if (organizationId) cycleQuery = cycleQuery.eq('organization_id', organizationId);
    const { data: cycle, error: cycleError } = await cycleQuery.single();

    if (cycleError) throw cycleError;

    let contributionQuery = supabase
      .from('member_contributions')
      .select(`
        *,
        member:group_members(
          id,
          user:users(id, name, email)
        )
      `)
      .eq('cycle_id', cycleId);
    if (organizationId) contributionQuery = contributionQuery.eq('organization_id', organizationId);
    const { data: contributions, error: contribError } = await contributionQuery;

    if (contribError) throw contribError;

    return { ...cycle, contributions };
  }

  // Calculate penalty for late payment
  static async calculatePenalty(contributionId: string, organizationId?: string) {
    let query = supabase
      .from('member_contributions')
      .select(`
        *,
        cycle:contribution_cycles(
          deadline_date,
          group:groups(grace_period_days, late_penalty_amount, late_penalty_type)
        )
      `)
      .eq('id', contributionId);
    if (organizationId) query = query.eq('organization_id', organizationId);
    const { data: contribution } = await query.single();

    if (!contribution) return 0;

    const deadline = new Date(contribution.cycle.deadline_date);
    const gracePeriod = contribution.cycle.group.grace_period_days || 0;
    const graceDeadline = new Date(deadline);
    graceDeadline.setDate(graceDeadline.getDate() + gracePeriod);

    const now = new Date();
    if (now <= graceDeadline) return 0;

    const penaltyType = contribution.cycle.group.late_penalty_type;
    const penaltyAmount = contribution.cycle.group.late_penalty_amount;

    if (penaltyType === 'percentage') {
      return (contribution.expected_amount * penaltyAmount) / 100;
    }
    return penaltyAmount;
  }

  // Record payment
  static async recordPayment(contributionId: string, amount: number, reference: string, organizationId?: string) {
    let ownershipQuery = supabase
      .from('member_contributions')
      .select('id')
      .eq('id', contributionId);
    if (organizationId) ownershipQuery = ownershipQuery.eq('organization_id', organizationId);
    const { data: ownedContribution } = await ownershipQuery.maybeSingle();
    if (!ownedContribution) throw new Error('Contribution not found in the active organization');
    const { data, error } = await supabase
      .rpc('record_payment_transaction', {
        p_contribution_id: contributionId,
        p_amount: amount,
        p_reference: reference
      });

    if (error) throw error;
    return data;
  }

  // Get member contribution history
  static async getMemberHistory(memberId: string, organizationId?: string) {
    let query = supabase
      .from('member_contributions')
      .select(`
        *,
        cycle:contribution_cycles(
          cycle_month,
          cycle_year,
          deadline_date,
          group:groups(name)
        )
      `)
      .eq('member_id', memberId);
    if (organizationId) query = query.eq('organization_id', organizationId);
    const { data, error } = await query.order('created_at', { ascending: false });

    if (error) throw error;
    return data;
  }

  // Update member status
  static async updateMemberStatus(memberId: string, status: string, organizationId?: string) {
    let ownershipQuery = supabase
      .from('group_members')
      .select('id, groups!inner(organization_id)')
      .eq('id', memberId);
    if (organizationId) ownershipQuery = ownershipQuery.eq('groups.organization_id', organizationId);
    const { data: ownedMember } = await ownershipQuery.maybeSingle();
    if (!ownedMember) throw new Error('Member not found in the active organization');
    const { data, error } = await supabase
      .from('group_members')
      .update({ member_status: status })
      .eq('id', memberId)
      .select()
      .single();

    if (error) throw error;
    return data;
  }

  // Mark overdue contributions
  static async markOverdueContributions() {
    const now = new Date().toISOString();
    
    // Get overdue contributions by joining with cycles
    const { data: overdueContributions, error: fetchError } = await supabase
      .from('member_contributions')
      .select('id, cycle:contribution_cycles!inner(deadline_date)')
      .eq('payment_status', 'pending')
      .lt('cycle.deadline_date', now);

    if (fetchError) throw fetchError;
    if (!overdueContributions || overdueContributions.length === 0) return [];

    // Update them to overdue
    const ids = overdueContributions.map(c => c.id);
    const { data, error } = await supabase
      .from('member_contributions')
      .update({ payment_status: 'overdue' })
      .in('id', ids)
      .select();

    if (error) throw error;
    return data;
  }
}
