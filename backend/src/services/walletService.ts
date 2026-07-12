import { supabase } from '../utils/supabase.js';
import { interswitchService } from './interswitchService.js';
import { ledgerService, InsufficientFundsError } from './ledgerService.js';
import { logAudit } from '../utils/audit.js';
import { sendEmail } from './emailService.js'; // Assuming basic email support
import jwt from 'jsonwebtoken';
import { randomUUID } from 'node:crypto';

export class WalletService {
  /**
   * Requirement 7.1, 7.2: Provision User Wallet
   */
  async provisionUserWallet(userId: string) {
    const { data, error } = await supabase
      .from('user_wallets')
      .upsert({ user_id: userId }, { onConflict: 'user_id' })
      .select()
      .single();

    if (error) {
      console.error(`Failed to provision wallet for user ${userId}:`, error.message);
      throw error;
    }

    return data;
  }

  /**
   * Requirement 2.1, 2.2: Provision Group NUBAN
   */
  async provisionGroupNuban(groupId: string, groupName: string) {
    // Check for existing ACTIVE NUBAN
    const { data: existing } = await supabase
      .from('group_virtual_accounts')
      .select()
      .eq('group_id', groupId)
      .eq('status', 'ACTIVE')
      .single();

    if (existing) return existing;

    try {
      const interswitchData = await interswitchService.provisionVirtualAccount(groupId, groupName);

      const { data, error } = await supabase
        .from('group_virtual_accounts')
        .upsert({
          group_id: groupId,
          nuban: interswitchData.nuban,
          bank_name: interswitchData.bankName,
          interswitch_ref: interswitchData.interswitchRef,
          status: 'ACTIVE',
          updated_at: new Date().toISOString()
        }, { onConflict: 'group_id' })
        .select()
        .single();

      if (error) throw error;
      return data;
    } catch (error: any) {
      console.error(`Failed to provision NUBAN for group ${groupId}:`, error.message);

      // Mark as PENDING for retry
      await supabase
        .from('group_virtual_accounts')
        .upsert({
          group_id: groupId,
          status: 'PENDING',
          updated_at: new Date().toISOString()
        }, { onConflict: 'group_id' });

      throw error;
    }
  }

  /**
   * Requirement 7.4: Get wallet with history
   */
  async getWalletWithHistory(userId: string, page: number = 1, limit: number = 10) {
    let { data: wallet, error: walletError } = await supabase
      .from('user_wallets')
      .select('*')
      .eq('user_id', userId)
      .single();

    if (walletError && walletError.code === 'PGRST116') {
      // Wallet missing (migration scenario), create it
      wallet = await this.provisionUserWallet(userId);
    } else if (walletError) {
      throw walletError;
    }

    const { data: transactions, count, error: txError } = await supabase
      .from('wallet_transactions')
      .select('*', { count: 'exact' })
      .eq('wallet_id', wallet.id)
      .order('created_at', { ascending: false })
      .range((page - 1) * limit, page * limit - 1);

    if (txError) throw txError;

    return {
      wallet,
      transactions,
      pagination: {
        page,
        limit,
        total: count
      }
    };
  }

  /**
   * Requirement 4.2: Get group wallet details
   */
  async getGroupWallet(groupId: string, userId: string) {
    // Verify membership
    const { data: membership } = await supabase
      .from('group_members')
      .select('payment_status')
      .eq('group_id', groupId)
      .eq('user_id', userId)
      .single();

    if (!membership || membership.payment_status !== 'paid') {
      throw new Error('User is not a paid member of this group');
    }

    const { data: group } = await supabase
      .from('groups')
      .select('id, name, group_fund_balance')
      .eq('id', groupId)
      .single();

    const { data: nuban } = await supabase
      .from('group_virtual_accounts')
      .select('nuban, bank_name, status')
      .eq('group_id', groupId)
      .maybeSingle();

    return { group, nuban };
  }

  /**
   * Requirement 6.1-6.9: P2P Transfer
   */
  async initiateP2PTransfer(senderId: string, recipientId: string, amount: number, ip: string) {
    if (amount < 100) {
      throw new Error('Minimum P2P transfer amount is ₦100');
    }

    // Check 24hr limit
    await this.check24hrP2PLimit(senderId, amount);

    // Get wallets
    const { data: senderWallet } = await supabase.from('user_wallets').select('id').eq('user_id', senderId).single();
    const { data: recipientWallet } = await supabase.from('user_wallets').select('id, status').eq('user_id', recipientId).single();

    if (!senderWallet || !recipientWallet) throw new Error('Wallet not found');
    if (recipientWallet.status !== 'ACTIVE') throw new Error('Recipient wallet is not active');

    const reference = `P2P-${randomUUID()}`;

    const result = await ledgerService.atomicP2PTransfer({
      senderWalletId: senderWallet.id,
      recipientWalletId: recipientWallet.id,
      amount,
      reference
    });

    await logAudit({
      user_id: senderId,
      action: 'P2P_TRANSFER',
      resource_type: 'wallet',
      resource_id: senderWallet.id,
      ip_address: ip,
      details: { recipientId, amount, reference }
    });

    // Notify users
    this.sendWalletNotification(senderId, `You sent ₦${amount.toLocaleString()} to another user.`);
    this.sendWalletNotification(recipientId, `You received ₦${amount.toLocaleString()} from another user.`);

    return result;
  }

  /**
   * Requirement 5.4, 6.3: Limit checks
   */
  private async check24hrP2PLimit(userId: string, amount: number) {
    const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

    const { data: txs } = await supabase
      .from('wallet_transactions')
      .select('amount')
      .eq('type', 'P2P_TRANSFER')
      .eq('direction', 'DEBIT')
      .eq('status', 'SUCCESS')
      .gte('created_at', twentyFourHoursAgo);

    const total = (txs || []).reduce((sum, tx) => sum + Number(tx.amount), 0);

    if (total + amount > 50000) {
      throw new Error('24-hour P2P transfer limit of ₦50,000 exceeded');
    }
  }

  private async check24hrWithdrawalLimit(userId: string, amount: number) {
    const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

    const { data: txs } = await supabase
      .from('wallet_transactions')
      .select('amount')
      .eq('type', 'WITHDRAWAL')
      .eq('direction', 'DEBIT')
      .eq('status', 'SUCCESS')
      .gte('created_at', twentyFourHoursAgo);

    const total = (txs || []).reduce((sum, tx) => sum + Number(tx.amount), 0);

    if (total + amount > 100000) {
      throw new Error('24-hour withdrawal limit of ₦100,000 exceeded');
    }
  }

  /**
   * Requirement 5.1-5.6: Individual Withdrawal (Two-Step)
   */
  async previewWithdrawal(userId: string, accountNumber: string, bankCode: string, amount: number) {
    if (amount < 1000) throw new Error('Minimum withdrawal amount is ₦1,000');

    await this.check24hrWithdrawalLimit(userId, amount);

    const { accountName } = await interswitchService.nameEnquiry(accountNumber, bankCode);

    const feeKobo = Number(process.env.INTERSWITCH_TRANSFER_FEE) || 5000;
    const feeNaira = feeKobo / 100;

    const { data: wallet } = await supabase.from('user_wallets').select('balance').eq('user_id', userId).single();
    if (!wallet || Number(wallet.balance) < amount + feeNaira) {
      throw new InsufficientFundsError('Insufficient funds for withdrawal and fee');
    }

    const previewToken = jwt.sign(
      { userId, accountNumber, bankCode, amount, fee: feeNaira, accountName },
      process.env.JWT_SECRET || 'secret',
      { expiresIn: '5m' }
    );

    return { accountName, fee: feeNaira, previewToken };
  }

  async confirmWithdrawal(userId: string, previewToken: string, ip: string) {
    const decoded: any = jwt.verify(previewToken, process.env.JWT_SECRET || 'secret');
    if (decoded.userId !== userId) throw new Error('Invalid preview token');

    const { data: wallet } = await supabase.from('user_wallets').select('id').eq('user_id', userId).single();
    if (!wallet) throw new Error('Wallet not found');

    const internalRef = `WD-${randomUUID()}`;

    // Debit wallet
    await ledgerService.debitWallet({
      walletId: wallet.id,
      amount: decoded.amount + decoded.fee,
      type: 'WITHDRAWAL',
      reference: internalRef
    });

    // Create withdrawal request
    const { data: request, error: reqError } = await supabase
      .from('withdrawal_requests')
      .insert({
        user_id: userId,
        wallet_id: wallet.id,
        amount: decoded.amount,
        fee_amount: decoded.fee,
        account_number: decoded.account_number,
        bank_code: decoded.bank_code,
        account_name: decoded.account_name,
        internal_ref: internalRef,
        status: 'PENDING'
      })
      .select()
      .single();

    if (reqError) throw reqError;

    // Initiate Interswitch transfer
    try {
      const result = await interswitchService.singleTransfer({
        accountNumber: decoded.account_number,
        bankCode: decoded.bank_code,
        amount: decoded.amount * 100, // to kobo
        reference: internalRef,
        narration: `Microfams Withdrawal ${internalRef}`
      });

      await supabase
        .from('withdrawal_requests')
        .update({ interswitch_ref: result.transferRef })
        .eq('id', request.id);

      if (result.status === 'SUCCESS' || result.status === 'FAILED') {
        await this.handleWithdrawalStatusUpdate(internalRef, result.status);
      }
    } catch (error: any) {
      console.error(`Interswitch transfer initiation failed for ${internalRef}:`, error.message);
      // Leave as PENDING for cron to resolve
    }

    await logAudit({
      user_id: userId,
      action: 'WITHDRAWAL_INITIATED',
      resource_type: 'withdrawal_request',
      resource_id: request.id,
      ip_address: ip,
      details: { amount: decoded.amount, internalRef }
    });

    return request;
  }

  async handleWithdrawalStatusUpdate(internalRef: string, status: 'SUCCESS' | 'FAILED') {
    const { data: request } = await supabase
      .from('withdrawal_requests')
      .select('*')
      .eq('internal_ref', internalRef)
      .single();

    if (!request || request.status !== 'PENDING') return;

    if (status === 'SUCCESS') {
      await supabase
        .from('withdrawal_requests')
        .update({ status: 'SUCCESS', updated_at: new Date().toISOString() })
        .eq('id', request.id);

      this.sendWalletNotification(request.user_id, `Withdrawal of ₦${request.amount.toLocaleString()} was successful.`);
    } else {
      // REVERSAL
      await ledgerService.creditWallet({
        walletId: request.wallet_id,
        amount: Number(request.amount) + Number(request.fee_amount),
        type: 'WITHDRAWAL',
        reference: `REV-${internalRef}`,
        metadata: { original_ref: internalRef, reason: 'Transfer failed' }
      });

      await supabase
        .from('withdrawal_requests')
        .update({ status: 'FAILED', updated_at: new Date().toISOString() })
        .eq('id', request.id);

      this.sendWalletNotification(request.user_id, `Withdrawal of ₦${request.amount.toLocaleString()} failed and was reversed to your wallet.`);
    }
  }

  /**
   * Requirement 4.1-4.8: Group Withdrawal (Multi-sig)
   */
  async initiateGroupWithdrawal(groupId: string, requestedBy: string, amount: number, targetUserId: string, ip: string) {
    // Verify requester is a member
    const { data: member } = await supabase
      .from('group_members')
      .select('role')
      .eq('group_id', groupId)
      .eq('user_id', requestedBy)
      .single();

    if (!member) throw new Error('User is not a member of this group');

    const { data: request, error } = await supabase
      .from('group_consensus_requests')
      .insert({
        group_id: groupId,
        requested_by: requestedBy,
        target_user_id: targetUserId,
        amount,
        status: 'PENDING'
      })
      .select()
      .single();

    if (error) throw error;

    await logAudit({
      user_id: requestedBy,
      action: 'GROUP_WITHDRAWAL_INITIATED',
      resource_type: 'group_consensus_request',
      resource_id: request.id,
      ip_address: ip,
      details: { groupId, amount, targetUserId }
    });

    // Notify Group Admin
    const { data: group } = await supabase.from('groups').select('creator_id, name').eq('id', groupId).single();
    if (group) {
      this.sendWalletNotification(group.creator_id, `A withdrawal request for ₦${amount.toLocaleString()} was initiated in group ${group.name}.`);
    }

    return request;
  }

  async getGroupWithdrawalRequest(requestId: string) {
    const { data, error } = await supabase
      .from('group_consensus_requests')
      .select('*, group_consensus_approvals(voter_id, voted_at)')
      .eq('id', requestId)
      .single();

    if (error) throw error;
    return data;
  }

  async castApprovalVote(requestId: string, voterId: string, ip: string) {
    const { data: request } = await supabase
      .from('group_consensus_requests')
      .select('*, groups(member_count, creator_id)')
      .eq('id', requestId)
      .single();

    if (!request || request.status !== 'PENDING') throw new Error('Request not found or not pending');

    // Verify voter is member
    const { data: voterMember } = await supabase
      .from('group_members')
      .select('role')
      .eq('group_id', request.group_id)
      .eq('user_id', voterId)
      .single();

    if (!voterMember) throw new Error('Voter is not a member of this group');

    // Cast vote
    const { error: voteError } = await supabase
      .from('group_consensus_approvals')
      .insert({ approval_request_id: requestId, voter_id: voterId });

    if (voteError && voteError.code === '23505') {
       // Already voted, ignore
    } else if (voteError) {
      throw voteError;
    }

    // Check threshold
    const { count: approvalCount } = await supabase
      .from('group_consensus_approvals')
      .select('*', { count: 'exact', head: true })
      .eq('approval_request_id', requestId);

    const { data: adminVoted } = await supabase
      .from('group_consensus_approvals')
      .select('*')
      .eq('approval_request_id', requestId)
      .eq('voter_id', (request.groups as any).creator_id)
      .single();

    const memberCount = (request.groups as any).member_count;
    const threshold = Math.ceil((2/3) * memberCount);

    if (adminVoted && approvalCount! >= threshold) {
      // Execute
      const { data: targetWallet } = await supabase
        .from('user_wallets')
        .select('id')
        .eq('user_id', request.target_user_id)
        .single();

      if (!targetWallet) throw new Error('Target user wallet not found');

      await ledgerService.atomicGroupTransfer({
        groupId: request.group_id,
        recipientWalletId: targetWallet.id,
        amount: request.amount,
        reference: `GWD-${requestId}`,
        approvalRequestId: requestId
      });

      await logAudit({
        user_id: voterId,
        action: 'GROUP_WITHDRAWAL_EXECUTED',
        resource_type: 'group_consensus_request',
        resource_id: requestId,
        ip_address: ip,
        details: { approvalCount, threshold }
      });

      this.sendWalletNotification(request.target_user_id, `₦${request.amount.toLocaleString()} has been transferred to your wallet from your group fund.`);

      return { approved: true, status: 'EXECUTED' };
    }

    return { approved: false, status: 'PENDING', approvalCount, threshold };
  }

  /**
   * Requirement 10.1, 10.2: Get transaction details
   */
  async getTransaction(userId: string, transactionId: string) {
    const { data: wallet } = await supabase
      .from('user_wallets')
      .select('id')
      .eq('user_id', userId)
      .single();

    if (!wallet) throw new Error('Wallet not found');

    const { data: transaction, error } = await supabase
      .from('wallet_transactions')
      .select('*')
      .eq('id', transactionId)
      .eq('wallet_id', wallet.id)
      .single();

    if (error) throw error;
    return transaction;
  }

  /**
   * Requirement 5.10, 5.11: Manual sync/confirmation for testing/pending
   */
  async syncWithdrawalStatus(userId: string, requestId: string) {
    const { data: request } = await supabase
      .from('withdrawal_requests')
      .select('*')
      .eq('id', requestId)
      .eq('user_id', userId)
      .single();

    if (!request) throw new Error('Withdrawal request not found');
    if (request.status !== 'PENDING') return request;

    try {
      const statusResult = await interswitchService.queryTransactionStatus(request.internal_ref);

      if (statusResult.status !== 'PENDING') {
        await this.handleWithdrawalStatusUpdate(request.internal_ref, statusResult.status);

        const { data: updated } = await supabase
          .from('withdrawal_requests')
          .select('*')
          .eq('id', requestId)
          .single();
        return updated;
      }
    } catch (error: any) {
      console.error(`Sync failed for withdrawal ${request.internal_ref}:`, error.message);
    }

    return request;
  }

  /**
   * Requirement 9.4, 9.5: Grace period expiry handling
   */
  async handleGracePeriodExpiry(userId: string) {
    const { data: wallet } = await supabase
      .from('user_wallets')
      .select('*')
      .eq('user_id', userId)
      .single();

    if (!wallet || Number(wallet.balance) <= 0) return;

    // 1. Deduct outstanding penalties
    const { data: penalties } = await supabase
      .from('member_contributions')
      .select('penalty_amount')
      .eq('user_id', userId)
      .eq('payment_status', 'pending');

    const totalPenalty = (penalties || []).reduce((sum, p) => sum + Number(p.penalty_amount), 0);
    let currentBalance = Number(wallet.balance);

    if (totalPenalty > 0) {
      const deduction = Math.min(totalPenalty, currentBalance);
      await ledgerService.debitWallet({
        walletId: wallet.id,
        amount: deduction,
        type: 'WITHDRAWAL',
        reference: `PENALTY-${randomUUID()}`,
        metadata: { reason: 'Grace period penalty settlement' }
      });
      currentBalance -= deduction;
    }

    if (currentBalance > 0) {
      // 2. Transfer back to primary group
      const { data: membership } = await supabase
        .from('group_members')
        .select('group_id')
        .eq('user_id', userId)
        .order('joined_at', { ascending: true })
        .limit(1)
        .maybeSingle();

      if (membership) {
        await ledgerService.debitWallet({
          walletId: wallet.id,
          amount: currentBalance,
          type: 'INTERNAL_TRANSFER',
          reference: `GRACE-RETURN-${randomUUID()}`
        });

        await supabase.rpc('atomic_group_credit', {
          p_group_id: membership.group_id,
          p_amount: currentBalance,
          p_reference: `GRACE-RETURN-${userId}`
        });

      } else {
        // Manual review flag
        await logAudit({
          user_id: userId,
          action: 'GRACE_PERIOD_MANUAL_REVIEW',
          resource_type: 'wallet',
          resource_id: wallet.id,
          details: { remainingBalance: currentBalance }
        });
      }
    }
  }

  /**
   * Requirement 3.1-3.6: Webhook Ingress
   */
  async handleInterswitchWebhook(payload: any, signature: string) {
    const rawPayload = JSON.stringify(payload);
    if (!interswitchService.verifyWebhookSignature(rawPayload, signature)) {
      throw new Error('Invalid webhook signature');
    }

    const { accountNumber, amount, transactionReference } = payload;

    // Deduplicate
    const { data: existing } = await supabase
      .from('wallet_transactions')
      .select('id')
      .eq('reference', transactionReference)
      .single();

    if (existing) return;

    const { data: groupAccount } = await supabase
      .from('group_virtual_accounts')
      .select('group_id')
      .eq('nuban', accountNumber)
      .single();

    if (!groupAccount) {
      console.warn(`Unknown NUBAN in webhook: ${accountNumber}`);
      return;
    }

    const amountNaira = Number(amount) / 100;

    const { error: creditError } = await supabase.rpc('atomic_group_credit', {
      p_group_id: groupAccount.group_id,
      p_amount: amountNaira,
      p_reference: transactionReference
    });

    if (creditError) throw creditError;

    // Notify Admin
    const { data: group } = await supabase.from('groups').select('creator_id, name').eq('id', groupAccount.group_id).single();
    if (group) {
      this.sendWalletNotification(group.creator_id, `Group fund ${group.name} was credited with ₦${amountNaira.toLocaleString()}.`);
    }
  }

  private async sendWalletNotification(userId: string, message: string) {
    try {
      const { data: user } = await supabase.from('users').select('email, name').eq('id', userId).single();
      if (!user) return;

      // In-app notification placeholder
      await supabase.from('notifications').insert({
        user_id: userId,
        title: 'Wallet Update',
        message,
        type: 'wallet'
      });

      // Email notification
      await sendEmail({
        to: user.email,
        subject: 'Wallet Notification',
        html: `<p>Hi ${user.name},</p><p>${message}</p>`
      });
    } catch (error) {
      console.error('Failed to send wallet notification:', error);
    }
  }
}

export const walletService = new WalletService();
