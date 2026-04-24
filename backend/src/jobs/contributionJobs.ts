import cron from 'node-cron';
import { ContributionModel } from '../models/Contribution.js';
import supabase from '../utils/supabase.js';
import { sendPaymentReminder, sendOverdueNotice, sendSuspensionNotice, sendExpulsionNotice } from '../services/notificationService.js';

// Run on 1st of each month at 00:00
export const createMonthlyCycles = cron.schedule('0 0 1 * *', async () => {
  console.log('Creating monthly contribution cycles...');
  
  try {
    const { data: groups } = await supabase
      .from('groups')
      .select('id')
      .eq('contribution_enabled', true);

    if (!groups) return;

    const now = new Date();
    const month = now.getMonth() + 1;
    const year = now.getFullYear();

    for (const group of groups) {
      await ContributionModel.createCycle(group.id, month, year);
    }

    console.log(`Created cycles for ${groups.length} groups`);
  } catch (error) {
    console.error('Error creating monthly cycles:', error);
  }
}, {
  scheduled: false
});

// Run daily at 09:00
export const checkOverduePayments = cron.schedule('0 9 * * *', async () => {
  console.log('Checking overdue payments...');
  
  try {
    const { data: contributions, error: fetchError } = await supabase
      .from('member_contributions')
      .select(`
        *,
        member:group_members(id, user_id, missed_payments_count, user:users(email, name)),
        cycle:contribution_cycles(deadline_date, group:groups(grace_period_days))
      `)
      .eq('payment_status', 'pending');

    if (fetchError) {
      console.error('Error fetching contributions:', fetchError);
      return;
    }

    if (!contributions || contributions.length === 0) {
      console.log('No pending contributions found');
      return;
    }

    const now = new Date();
    let processedCount = 0;
    
    for (const contrib of contributions) {
      try {
        const deadline = new Date(contrib.cycle.deadline_date);
        const gracePeriod = contrib.cycle.group.grace_period_days || 0;
        const graceDeadline = new Date(deadline);
        graceDeadline.setDate(graceDeadline.getDate() + gracePeriod);

        if (now > graceDeadline) {
          const { error: updateError } = await supabase
            .from('member_contributions')
            .update({ payment_status: 'overdue' })
            .eq('id', contrib.id);

          if (updateError) {
            console.error(`Error updating contribution ${contrib.id}:`, updateError);
            continue;
          }

          const { error: memberError } = await supabase
            .from('group_members')
            .update({ missed_payments_count: (contrib.member.missed_payments_count || 0) + 1 })
            .eq('id', contrib.member_id);

          if (memberError) {
            console.error(`Error updating member ${contrib.member_id}:`, memberError);
            continue;
          }

          await sendOverdueNotice(contrib.member.user_id, contrib.id);
          processedCount++;
        }
      } catch (itemError) {
        console.error(`Error processing contribution ${contrib.id}:`, itemError);
      }
    }
    
    console.log(`Processed ${processedCount} overdue payments`);
  } catch (error) {
    console.error('Error checking overdue payments:', error);
  }
}, {
  scheduled: false
});

// Run daily at 10:00
export const autoSuspendMembers = cron.schedule('0 10 * * *', async () => {
  console.log('Auto-suspending members...');
  
  try {
    const { data: members, error: fetchError } = await supabase
      .from('group_members')
      .select(`
        *,
        group:groups(auto_suspend_after),
        user:users(email, name)
      `)
      .eq('member_status', 'active');

    if (fetchError) {
      console.error('Error fetching members:', fetchError);
      return;
    }

    if (!members || members.length === 0) {
      console.log('No active members found');
      return;
    }

    let suspendedCount = 0;

    for (const member of members) {
      try {
        if (member.missed_payments_count >= member.group.auto_suspend_after) {
          await ContributionModel.updateMemberStatus(member.id, 'suspended');
          await sendSuspensionNotice(member.user_id);
          suspendedCount++;
        }
      } catch (itemError) {
        console.error(`Error suspending member ${member.id}:`, itemError);
      }
    }
    
    console.log(`Suspended ${suspendedCount} members`);
  } catch (error) {
    console.error('Error auto-suspending members:', error);
  }
}, {
  scheduled: false
});

// Run daily at 11:00
export const autoExpelMembers = cron.schedule('0 11 * * *', async () => {
  console.log('Auto-expelling members...');
  
  try {
    const { data: members, error: fetchError } = await supabase
      .from('group_members')
      .select(`
        *,
        group:groups(auto_expel_after),
        user:users(email, name)
      `)
      .in('member_status', ['active', 'suspended']);

    if (fetchError) {
      console.error('Error fetching members:', fetchError);
      return;
    }

    if (!members || members.length === 0) {
      console.log('No members to check for expulsion');
      return;
    }

    let expelledCount = 0;

    for (const member of members) {
      try {
        if (member.missed_payments_count >= member.group.auto_expel_after) {
          await ContributionModel.updateMemberStatus(member.id, 'expelled');
          await sendExpulsionNotice(member.user_id);
          expelledCount++;
        }
      } catch (itemError) {
        console.error(`Error expelling member ${member.id}:`, itemError);
      }
    }
    
    console.log(`Expelled ${expelledCount} members`);
  } catch (error) {
    console.error('Error auto-expelling members:', error);
  }
}, {
  scheduled: false
});

// Run daily at 08:00 - Send reminders 3 days before deadline
export const sendPaymentReminders = cron.schedule('0 8 * * *', async () => {
  console.log('Sending payment reminders...');
  
  try {
    const threeDaysFromNow = new Date();
    threeDaysFromNow.setDate(threeDaysFromNow.getDate() + 3);

    const { data: contributions } = await supabase
      .from('member_contributions')
      .select(`
        *,
        member:group_members(user_id),
        cycle:contribution_cycles(deadline_date)
      `)
      .eq('payment_status', 'pending');

    if (!contributions) return;

    for (const contrib of contributions) {
      const deadline = new Date(contrib.cycle.deadline_date);
      const diffDays = Math.ceil((deadline.getTime() - new Date().getTime()) / (1000 * 60 * 60 * 24));

      if (diffDays === 3) {
        await sendPaymentReminder(contrib.member.user_id, contrib.id);
      }
    }
  } catch (error) {
    console.error('Error sending payment reminders:', error);
  }
}, {
  scheduled: false
});

export const startCronJobs = () => {
  try {
    createMonthlyCycles.start();
    checkOverduePayments.start();
    autoSuspendMembers.start();
    autoExpelMembers.start();
    sendPaymentReminders.start();
    console.log('Contribution cron jobs started');
  } catch (error) {
    console.error('Error starting cron jobs:', error);
  }
};
