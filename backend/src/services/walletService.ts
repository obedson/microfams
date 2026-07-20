import { supabase } from '../utils/supabase.js';
import { interswitchService } from './interswitchService.js';
import { ledgerService, InsufficientFundsError } from './ledgerService.js';
import { logAudit } from '../utils/audit.js';
import { sendEmail } from './emailService.js'; // Assuming basic email support
import jwt from 'jsonwebtoken';
import { randomUUID } from 'node:crypto';
import { assertMinorUnits, formatNgnMinor, majorDecimalToMinor, minorToMajorDecimal } from '../domains/financial/money.js';
import { payoutService } from '../domains/financial/payoutService.js';

const withdrawalResponse = (request: any) => {
  const { amount, fee_amount, amount_minor, fee_amount_minor, account_number, ...identity } = request;
  return {
    ...identity,
    ...(account_number ? { maskedAccountNumber: `******${String(account_number).slice(-4)}` } : {}),
    amountMinor: Number(amount_minor ?? majorDecimalToMinor(amount)),
    feeMinor: Number(fee_amount_minor ?? majorDecimalToMinor(fee_amount)),
    currency: 'NGN',
  };
};

const previewSigningSecret = (): string => {
  if (!process.env.JWT_SECRET) throw new Error('Wallet preview signing is not configured');
  return process.env.JWT_SECRET;
};

const groupRequestResponse = (request: any) => {
  const { amount, ...identity } = request;
  return { ...identity, amountMinor: majorDecimalToMinor(amount), currency: 'NGN' };
};

export class WalletService {
  /**
   * Requirement 7.1, 7.2: Provision User Wallet
   */
  async provisionUserWallet(userId: string, organizationId?: string) {
    const tenantId = organizationId ?? userId;
    const { data, error } = await supabase
      .from('user_wallets')
      .upsert({ user_id: userId, organization_id: tenantId }, { onConflict: 'organization_id,user_id' })
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
  async getWalletWithHistory(userId: string, page: number = 1, limit: number = 10, organizationId?: string) {
    let walletQuery = supabase
      .from('user_wallets')
      .select('*')
      .eq('user_id', userId);
    if (organizationId) walletQuery = walletQuery.eq('organization_id', organizationId);
    let { data: wallet, error: walletError } = await walletQuery.single();

    if (walletError && walletError.code === 'PGRST116') {
      // Wallet missing (migration scenario), create it
      wallet = await this.provisionUserWallet(userId, organizationId);
    } else if (walletError) {
      throw walletError;
    }

    const { data: transactions, count, error: txError } = await supabase
      .from('wallet_transactions')
      .select('*', { count: 'exact' })
      .eq('wallet_id', wallet.id)
      .eq('organization_id', organizationId ?? wallet.organization_id)
      .order('created_at', { ascending: false })
      .range((page - 1) * limit, page * limit - 1);

    if (txError) throw txError;

    const balanceSummary = await ledgerService.getWalletBalanceSummary(wallet.id);
    const { balance: _legacyBalance, ...walletIdentity } = wallet as any;
    const minorTransactions = (transactions || []).map((transaction: any) => {
      const { amount: legacyAmount, amount_minor: storedMinor, ...identity } = transaction;
      return {
        ...identity,
        amountMinor: storedMinor === null || storedMinor === undefined
          ? majorDecimalToMinor(legacyAmount)
          : Number(storedMinor),
        currency: 'NGN',
      };
    });

    return {
      wallet: { ...walletIdentity, ...balanceSummary },
      transactions: minorTransactions,
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
  async getGroupWallet(groupId: string, userId: string, organizationId?: string) {
    let groupQuery = supabase
      .from('groups')
      .select('id, name, group_fund_balance')
      .eq('id', groupId);
    if (organizationId) groupQuery = groupQuery.eq('organization_id', organizationId);
    const { data: group } = await groupQuery.maybeSingle();
    if (!group) throw new Error('Group not found in the active organization');

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

    const { data: nuban } = await supabase
      .from('group_virtual_accounts')
      .select('nuban, bank_name, status')
      .eq('group_id', groupId)
      .maybeSingle();

    const balanceSummary = await ledgerService.getGroupWalletBalanceSummary(group.id);
    const { group_fund_balance: _legacyBalance, ...groupIdentity } = group as any;
    return { group: { ...groupIdentity, ...balanceSummary }, nuban };
  }

  /**
   * Requirement 6.1-6.9: P2P Transfer
   */
  async initiateP2PTransfer(senderId: string, recipientId: string, amountMinor: number, idempotencyKey: string, ip: string, organizationId?: string) {
    assertMinorUnits(amountMinor);
    if (amountMinor < 10000) {
      throw new Error('Minimum P2P transfer amount is ₦100');
    }

    // Get wallets
    let senderQuery = supabase.from('user_wallets').select('id, organization_id').eq('user_id', senderId);
    let recipientQuery = supabase.from('user_wallets').select('id, status, organization_id').eq('user_id', recipientId);
    if (organizationId) {
      senderQuery = senderQuery.eq('organization_id', organizationId);
      recipientQuery = recipientQuery.eq('organization_id', organizationId);
    }
    const { data: senderWallet } = await senderQuery.single();
    const { data: recipientWallet } = await recipientQuery.single();

    if (!senderWallet || !recipientWallet) throw new Error('Wallet not found');
    if (recipientWallet.status !== 'ACTIVE') throw new Error('Recipient wallet is not active');
    if (senderWallet.organization_id !== recipientWallet.organization_id) {
      throw new Error('Wallet transfer cannot cross organizations');
    }
    await this.check24hrP2PLimit(senderWallet.id, amountMinor, senderWallet.organization_id);

    const reference = `P2P-${idempotencyKey}`;

    const result = await ledgerService.atomicP2PTransfer({
      senderWalletId: senderWallet.id,
      recipientWalletId: recipientWallet.id,
      amountMinor,
      reference
    });

    await logAudit({
      user_id: senderId,
      action: 'P2P_TRANSFER',
      resource_type: 'wallet',
      resource_id: senderWallet.id,
      ip_address: ip,
      details: { recipientId, amountMinor, currency: 'NGN', reference }
    });

    // Notify users
    this.sendWalletNotification(senderId, `You sent ${formatNgnMinor(amountMinor)} to another user.`);
    this.sendWalletNotification(recipientId, `You received ${formatNgnMinor(amountMinor)} from another user.`);

    return result;
  }

  /**
   * Requirement 5.4, 6.3: Limit checks
   */
  private async check24hrP2PLimit(walletId: string, amountMinor: number, organizationId: string) {
    const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

    const { data: txs } = await supabase
      .from('wallet_transactions')
      .select('amount, amount_minor')
      .eq('type', 'P2P_TRANSFER')
      .eq('direction', 'DEBIT')
      .eq('status', 'SUCCESS')
      .eq('wallet_id', walletId)
      .eq('organization_id', organizationId)
      .gte('created_at', twentyFourHoursAgo);

    const total = (txs || []).reduce((sum, tx: any) => sum + (
      tx.amount_minor === null || tx.amount_minor === undefined
        ? majorDecimalToMinor(tx.amount)
        : Number(tx.amount_minor)
    ), 0);

    if (total + amountMinor > 5000000) {
      throw new Error('24-hour P2P transfer limit of ₦50,000 exceeded');
    }
  }

  private async check24hrWithdrawalLimit(userId: string, amountMinor: number, organizationId?: string) {
    const twentyFourHoursAgo = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();

    let query = supabase
      .from('wallet_transactions')
      .select('amount, amount_minor')
      .eq('type', 'WITHDRAWAL')
      .eq('direction', 'DEBIT')
      .eq('status', 'SUCCESS')
      .gte('created_at', twentyFourHoursAgo);
    if (organizationId) query = query.eq('organization_id', organizationId);
    const { data: txs } = await query;

    const total = (txs || []).reduce((sum, tx: any) => sum + (
      tx.amount_minor === null || tx.amount_minor === undefined
        ? majorDecimalToMinor(tx.amount)
        : Number(tx.amount_minor)
    ), 0);

    if (total + amountMinor > 10000000) {
      throw new Error('24-hour withdrawal limit of ₦100,000 exceeded');
    }
  }

  /**
   * Requirement 5.1-5.6: Individual Withdrawal (Two-Step)
   */
  async previewWithdrawal(
    userId: string,
    accountNumber: string,
    bankCode: string,
    amountMinor: number,
    idempotencyKey: string,
    organizationId?: string,
  ) {
    assertMinorUnits(amountMinor);
    if (amountMinor < 100000) throw new Error('Minimum withdrawal amount is ₦1,000');

    await this.check24hrWithdrawalLimit(userId, amountMinor, organizationId);

    const { accountName } = await payoutService.validateDestination(
      organizationId ?? userId, userId, accountNumber, bankCode,
    );

    const feeMinor = Number(process.env.INTERSWITCH_TRANSFER_FEE) || 5000;
    assertMinorUnits(feeMinor, 'Transfer fee');

    let walletQuery = supabase.from('user_wallets').select('id').eq('user_id', userId);
    if (organizationId) walletQuery = walletQuery.eq('organization_id', organizationId);
    const { data: wallet } = await walletQuery.single();
    if (!wallet) throw new Error('Wallet not found');
    const summary = await ledgerService.getWalletBalanceSummary(wallet.id);
    if (summary.availableBalanceMinor < amountMinor + feeMinor) {
      throw new InsufficientFundsError('Insufficient funds for withdrawal and fee');
    }

    const previewToken = jwt.sign(
      {
        userId, organizationId, accountNumber, bankCode, amountMinor, feeMinor,
        currency: 'NGN', accountName, idempotencyKey, correlationId: randomUUID(),
      },
      previewSigningSecret(),
      { expiresIn: '5m' }
    );

    return { accountName, feeMinor, currency: 'NGN', previewToken };
  }

  async confirmWithdrawal(userId: string, previewToken: string, ip: string, organizationId?: string) {
    const decoded: any = jwt.verify(previewToken, previewSigningSecret());
    if (decoded.userId !== userId) throw new Error('Invalid preview token');
    if (organizationId && decoded.organizationId !== organizationId) throw new Error('Preview token belongs to another organization');

    let walletQuery = supabase.from('user_wallets').select('id').eq('user_id', userId);
    if (organizationId) walletQuery = walletQuery.eq('organization_id', organizationId);
    const { data: wallet } = await walletQuery.single();
    if (!wallet) throw new Error('Wallet not found');

    if (decoded.currency !== 'NGN') throw new Error('Unsupported withdrawal currency');
    assertMinorUnits(decoded.amountMinor);
    assertMinorUnits(decoded.feeMinor, 'Transfer fee');
    const internalRef = `WD-${decoded.idempotencyKey}`;
    const totalMinor = decoded.amountMinor + decoded.feeMinor;
    const reservation = await ledgerService.reserveWalletFunds({
      walletId: wallet.id,
      amountMinor: totalMinor,
      sourceRecordId: internalRef,
      idempotencyKey: decoded.idempotencyKey,
      correlationId: decoded.correlationId,
      actorId: userId,
      expiresAt: new Date(decoded.exp * 1000).toISOString(),
    });

    // Create withdrawal request
    const { data: request, error: reqError } = await supabase
      .from('withdrawal_requests')
      .upsert({
        user_id: userId,
        organization_id: organizationId,
        wallet_id: wallet.id,
        reservation_id: reservation.id,
        amount: minorToMajorDecimal(decoded.amountMinor),
        fee_amount: minorToMajorDecimal(decoded.feeMinor),
        amount_minor: decoded.amountMinor,
        fee_amount_minor: decoded.feeMinor,
        account_number: decoded.accountNumber,
        bank_code: decoded.bankCode,
        account_name: decoded.accountName,
        internal_ref: internalRef,
        status: 'PENDING'
      }, { onConflict: 'reservation_id' })
      .select()
      .single();

    if (reqError) {
      throw reqError;
    }
    const consumed = await ledgerService.consumeWalletReservation(reservation.id, userId);
    if (consumed.state !== 'consumed') throw new Error('Withdrawal reservation expired before submission');

    const payout = await payoutService.createAndSubmit({
      withdrawalRequestId: request.id,
      organizationId: organizationId ?? decoded.organizationId,
      actorId: userId,
      correlationId: decoded.correlationId,
      internalReference: internalRef,
      amountMinor: decoded.amountMinor,
      feeAmountMinor: decoded.feeMinor,
      accountNumber: decoded.accountNumber,
      bankCode: decoded.bankCode,
      accountName: decoded.accountName,
    });

    await logAudit({
      user_id: userId,
      action: 'WITHDRAWAL_INITIATED',
      resource_type: 'withdrawal_request',
      resource_id: request.id,
      ip_address: ip,
      details: { amountMinor: decoded.amountMinor, feeMinor: decoded.feeMinor, currency: 'NGN', internalRef }
    });

    return { ...withdrawalResponse(request), payout };
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

      const amountMinor = Number(request.amount_minor ?? majorDecimalToMinor(request.amount));
      this.sendWalletNotification(request.user_id, `Withdrawal of ${formatNgnMinor(amountMinor)} was successful.`);
    } else {
      if (request.reservation_id) {
        await ledgerService.restoreWalletReservation(request.reservation_id, request.user_id, `REV-${internalRef}`);
      } else {
        await ledgerService.creditWallet({
          walletId: request.wallet_id,
          amount: Number(request.amount) + Number(request.fee_amount),
          type: 'WITHDRAWAL',
          reference: `REV-${internalRef}`,
          metadata: { original_ref: internalRef, reason: 'Transfer failed' }
        });
      }

      await supabase
        .from('withdrawal_requests')
        .update({ status: 'FAILED', updated_at: new Date().toISOString() })
        .eq('id', request.id);

      const amountMinor = Number(request.amount_minor ?? majorDecimalToMinor(request.amount));
      this.sendWalletNotification(request.user_id, `Withdrawal of ${formatNgnMinor(amountMinor)} failed and was restored to your wallet.`);
    }
  }

  /**
   * Requirement 4.1-4.8: Group Withdrawal (Multi-sig)
   */
  async initiateGroupWithdrawal(groupId: string, requestedBy: string, amountMinor: number, idempotencyKey: string, targetUserId: string, ip: string, organizationId?: string) {
    assertMinorUnits(amountMinor);
    if (organizationId) {
      const { data: ownedGroup } = await supabase.from('groups').select('id')
        .eq('id', groupId).eq('organization_id', organizationId).maybeSingle();
      if (!ownedGroup) throw new Error('Group not found in the active organization');
    }
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
      .upsert({
        group_id: groupId,
        requested_by: requestedBy,
        target_user_id: targetUserId,
        amount: minorToMajorDecimal(amountMinor),
        idempotency_key: idempotencyKey,
        status: 'PENDING'
      }, { onConflict: 'group_id,requested_by,idempotency_key' })
      .select()
      .single();

    if (error) throw error;

    await logAudit({
      user_id: requestedBy,
      action: 'GROUP_WITHDRAWAL_INITIATED',
      resource_type: 'group_consensus_request',
      resource_id: request.id,
      ip_address: ip,
      details: { groupId, amountMinor, currency: 'NGN', idempotencyKey, targetUserId }
    });

    // Notify Group Admin
    const { data: group } = await supabase.from('groups').select('creator_id, name').eq('id', groupId).single();
    if (group) {
      this.sendWalletNotification(group.creator_id, `A withdrawal request for ${formatNgnMinor(amountMinor)} was initiated in group ${group.name}.`);
    }

    return groupRequestResponse(request);
  }

  async getGroupWithdrawalRequest(requestId: string, organizationId?: string) {
    let query = supabase
      .from('group_consensus_requests')
      .select('*, groups!inner(organization_id), group_consensus_approvals(voter_id, voted_at)')
      .eq('id', requestId);
    if (organizationId) query = query.eq('groups.organization_id', organizationId);
    const { data, error } = await query.single();

    if (error) throw error;
    return groupRequestResponse(data);
  }

  async castApprovalVote(requestId: string, voterId: string, ip: string, organizationId?: string) {
    let requestQuery = supabase
      .from('group_consensus_requests')
      .select('*, groups!inner(member_count, creator_id, organization_id)')
      .eq('id', requestId);
    if (organizationId) requestQuery = requestQuery.eq('groups.organization_id', organizationId);
    const { data: request } = await requestQuery.single();

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
        .eq('organization_id', (request.groups as any).organization_id)
        .single();

      if (!targetWallet) throw new Error('Target user wallet not found');

      await ledgerService.atomicGroupTransfer({
        groupId: request.group_id,
        recipientWalletId: targetWallet.id,
        amountMinor: majorDecimalToMinor(request.amount),
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

      this.sendWalletNotification(request.target_user_id, `${formatNgnMinor(majorDecimalToMinor(request.amount))} has been transferred to your wallet from your group fund.`);

      return { approved: true, status: 'EXECUTED' };
    }

    return { approved: false, status: 'PENDING', approvalCount, threshold };
  }

  /**
   * Requirement 10.1, 10.2: Get transaction details
   */
  async getTransaction(userId: string, transactionId: string, organizationId?: string) {
    let walletQuery = supabase
      .from('user_wallets')
      .select('id')
      .eq('user_id', userId);
    if (organizationId) walletQuery = walletQuery.eq('organization_id', organizationId);
    const { data: wallet } = await walletQuery.single();

    if (!wallet) throw new Error('Wallet not found');

    let transactionQuery = supabase
      .from('wallet_transactions')
      .select('*')
      .eq('id', transactionId)
      .eq('wallet_id', wallet.id);
    if (organizationId) transactionQuery = transactionQuery.eq('organization_id', organizationId);
    const { data: transaction, error } = await transactionQuery.single();

    if (error) throw error;
    const { amount, amount_minor, ...identity } = transaction;
    return {
      ...identity,
      amountMinor: Number(amount_minor ?? majorDecimalToMinor(amount)),
      currency: 'NGN',
    };
  }

  /**
   * Requirement 5.10, 5.11: Manual sync/confirmation for testing/pending
   */
  async syncWithdrawalStatus(userId: string, requestId: string, organizationId?: string) {
    let query = supabase
      .from('withdrawal_requests')
      .select('*')
      .eq('id', requestId)
      .eq('user_id', userId);
    if (organizationId) query = query.eq('organization_id', organizationId);
    const { data: request } = await query.single();

    if (!request) throw new Error('Withdrawal request not found');
    if (request.status !== 'PENDING') return withdrawalResponse(request);

    const { data: payout, error: payoutError } = await supabase
      .from('payouts').select('id').eq('withdrawal_request_id', request.id).single();
    if (payoutError || !payout) throw new Error('Payout orchestration record not found');
    const result = await payoutService.queryAndApply(payout.id);
    const { data: updated } = await supabase
      .from('withdrawal_requests').select('*').eq('id', requestId).single();
    return { ...withdrawalResponse(updated ?? request), payout: result };
  }

  async getWithdrawalStatus(userId: string, requestId: string, organizationId: string) {
    const { data, error } = await supabase
      .from('withdrawal_requests')
      .select('*')
      .eq('id', requestId)
      .eq('user_id', userId)
      .eq('organization_id', organizationId)
      .single();
    if (error || !data) throw new Error('Withdrawal not found');
    return withdrawalResponse(data);
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
    const rawPayload = Buffer.isBuffer(payload) ? payload : Buffer.from(JSON.stringify(payload));
    if (!interswitchService.verifyWebhookSignature(rawPayload.toString('utf8'), signature)) {
      throw new Error('Invalid webhook signature');
    }

    const event = Buffer.isBuffer(payload) ? JSON.parse(rawPayload.toString('utf8')) : payload;
    const { accountNumber, amount, transactionReference } = event;

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

    const amountMinor = Number(amount);
    assertMinorUnits(amountMinor, 'Webhook amount');

    const { error: creditError } = await supabase.rpc('atomic_group_credit_minor', {
      p_group_id: groupAccount.group_id,
      p_amount_minor: String(amountMinor),
      p_reference: transactionReference
    });

    if (creditError) throw creditError;

    // Notify Admin
    const { data: group } = await supabase.from('groups').select('creator_id, name').eq('id', groupAccount.group_id).single();
    if (group) {
      this.sendWalletNotification(group.creator_id, `Group fund ${group.name} was credited with ${formatNgnMinor(amountMinor)}.`);
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
