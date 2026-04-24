import supabase from '../utils/supabase.js';

export class ContributionModel {
  // Create new contribution cycle
  static async createCycle(groupId: string, month: number, year: number) {
    const { data: group } = await supabase
      .from('groups')
      .select('contribution_amount, payment_day, member_count')
      .eq('id', groupId)
      .single();

    if (!group?.contribution_amount) throw new Error('Contributions not enabled');

    const deadlineDate = new Date(year, month - 1, group.payment_day);
    const expectedAmount = group.contribution_amount * group.member_count;

    const { data, error } = await supabase
      .from('contribution_cycles')
      .insert({
        group_id: groupId,
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
          expected_amount: group.contribution_amount
        }))
      );
    }

    return data;
  }

  // Get current active cycle
  static async getCurrentCycle(groupId: string) {
    const { data, error } = await supabase
      .from('contribution_cycles')
      .select('*')
      .eq('group_id', groupId)
      .eq('status', 'active')
      .order('created_at', { ascending: false })
      .limit(1)
      .single();

    if (error && error.code !== 'PGRST116') throw error;
    return data;
  }

  // Get cycle with member payments
  static async getCycleDetails(cycleId: string) {
    const { data: cycle, error: cycleError } = await supabase
      .from('contribution_cycles')
      .select('*')
      .eq('id', cycleId)
      .single();

    if (cycleError) throw cycleError;

    const { data: contributions, error: contribError } = await supabase
      .from('member_contributions')
      .select(`
        *,
        member:group_members(
          id,
          user:users(id, name, email)
        )
      `)
      .eq('cycle_id', cycleId);

    if (contribError) throw contribError;

    return { ...cycle, contributions };
  }

  // Calculate penalty for late payment
  static async calculatePenalty(contributionId: string) {
    const { data: contribution } = await supabase
      .from('member_contributions')
      .select(`
        *,
        cycle:contribution_cycles(
          deadline_date,
          group:groups(grace_period_days, late_penalty_amount, late_penalty_type)
        )
      `)
      .eq('id', contributionId)
      .single();

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
  static async recordPayment(contributionId: string, amount: number, reference: string) {
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
  static async getMemberHistory(memberId: string) {
    const { data, error } = await supabase
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
      .eq('member_id', memberId)
      .order('created_at', { ascending: false });

    if (error) throw error;
    return data;
  }

  // Update member status
  static async updateMemberStatus(memberId: string, status: string) {
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
