import supabase from '../utils/supabase.js';
import { sendEmail } from './emailService.js';

export const sendPaymentReminder = async (userId: string, contributionId: string) => {
  try {
    const { data: user } = await supabase
      .from('users')
      .select('email, name')
      .eq('id', userId)
      .single();

    const { data: contribution } = await supabase
      .from('member_contributions')
      .select(`
        expected_amount,
        cycle:contribution_cycles(
          cycle_month,
          cycle_year,
          deadline_date,
          group:groups(name)
        )
      `)
      .eq('id', contributionId)
      .single();

    if (!user || !contribution) return;

    const cycle = contribution.cycle as any;
    const group = Array.isArray(cycle.group) ? cycle.group[0] : cycle.group;

    await sendEmail({
      to: user.email,
      subject: `Payment Reminder - ${group.name}`,
      html: `
        <h2>Payment Reminder</h2>
        <p>Hi ${user.name},</p>
        <p>This is a reminder that your contribution payment is due in 3 days.</p>
        <p><strong>Group:</strong> ${group.name}</p>
        <p><strong>Amount:</strong> ₦${contribution.expected_amount.toLocaleString()}</p>
        <p><strong>Deadline:</strong> ${new Date(cycle.deadline_date).toLocaleDateString()}</p>
        <p>Please make your payment before the deadline to avoid penalties.</p>
      `
    });
  } catch (error) {
    console.error('Error sending payment reminder:', error);
  }
};

export const sendOverdueNotice = async (userId: string, contributionId: string) => {
  try {
    const { data: user } = await supabase
      .from('users')
      .select('email, name')
      .eq('id', userId)
      .single();

    const { data: contribution } = await supabase
      .from('member_contributions')
      .select(`
        expected_amount,
        penalty_amount,
        cycle:contribution_cycles(group:groups(name))
      `)
      .eq('id', contributionId)
      .single();

    if (!user || !contribution) return;

    const cycle = contribution.cycle as any;
    const group = Array.isArray(cycle.group) ? cycle.group[0] : cycle.group;

    await sendEmail({
      to: user.email,
      subject: `Overdue Payment Notice - ${group.name}`,
      html: `
        <h2>Overdue Payment Notice</h2>
        <p>Hi ${user.name},</p>
        <p>Your contribution payment is now overdue.</p>
        <p><strong>Group:</strong> ${group.name}</p>
        <p><strong>Amount Due:</strong> ₦${contribution.expected_amount.toLocaleString()}</p>
        <p><strong>Penalty:</strong> ₦${contribution.penalty_amount.toLocaleString()}</p>
        <p>Please make your payment immediately to avoid suspension.</p>
      `
    });
  } catch (error) {
    console.error('Error sending overdue notice:', error);
  }
};

export const sendSuspensionNotice = async (userId: string) => {
  try {
    const { data: user } = await supabase
      .from('users')
      .select('email, name')
      .eq('id', userId)
      .single();

    if (!user) return;

    await sendEmail({
      to: user.email,
      subject: 'Account Suspended',
      html: `
        <h2>Account Suspended</h2>
        <p>Hi ${user.name},</p>
        <p>Your group membership has been suspended due to missed payments.</p>
        <p>Please contact the group administrator to resolve this issue.</p>
      `
    });
  } catch (error) {
    console.error('Error sending suspension notice:', error);
  }
};

export const sendExpulsionNotice = async (userId: string) => {
  try {
    const { data: user } = await supabase
      .from('users')
      .select('email, name')
      .eq('id', userId)
      .single();

    if (!user) return;

    await sendEmail({
      to: user.email,
      subject: 'Membership Terminated',
      html: `
        <h2>Membership Terminated</h2>
        <p>Hi ${user.name},</p>
        <p>Your group membership has been terminated due to excessive missed payments.</p>
        <p>If you believe this is an error, please contact the group administrator.</p>
      `
    });
  } catch (error) {
    console.error('Error sending expulsion notice:', error);
  }
};

export const sendPaymentConfirmation = async (userId: string, contributionId: string) => {
  try {
    const { data: user } = await supabase
      .from('users')
      .select('email, name')
      .eq('id', userId)
      .single();

    const { data: contribution } = await supabase
      .from('member_contributions')
      .select(`
        paid_amount,
        paid_at,
        cycle:contribution_cycles(
          cycle_month,
          cycle_year,
          group:groups(name)
        )
      `)
      .eq('id', contributionId)
      .single();

    if (!user || !contribution) return;

    const cycle = contribution.cycle as any;
    const group = Array.isArray(cycle.group) ? cycle.group[0] : cycle.group;

    await sendEmail({
      to: user.email,
      subject: `Payment Confirmed - ${group.name}`,
      html: `
        <h2>Payment Confirmed</h2>
        <p>Hi ${user.name},</p>
        <p>Your contribution payment has been received and confirmed.</p>
        <p><strong>Group:</strong> ${group.name}</p>
        <p><strong>Amount:</strong> ₦${contribution.paid_amount.toLocaleString()}</p>
        <p><strong>Date:</strong> ${new Date(contribution.paid_at).toLocaleDateString()}</p>
        <p>Thank you for your payment!</p>
      `
    });
  } catch (error) {
    console.error('Error sending payment confirmation:', error);
  }
};
