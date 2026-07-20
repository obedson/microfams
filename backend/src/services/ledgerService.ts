import { supabase } from '../utils/supabase.js';
import { assertMinorUnits } from '../domains/financial/money.js';

export class LedgerTransactionError extends Error {
  constructor(message: string) {
    super(`LedgerTransactionError: ${message}`);
    this.name = 'LedgerTransactionError';
  }
}

export class InsufficientFundsError extends Error {
  constructor(message: string) {
    super(`InsufficientFundsError: ${message}`);
    this.name = 'InsufficientFundsError';
  }
}

export type TransactionType = 'COLLECTION' | 'INTERNAL_TRANSFER' | 'WITHDRAWAL' | 'P2P_TRANSFER';

export interface WalletTransaction {
  id: string;
  wallet_id: string;
  source_id?: string;
  destination_id?: string;
  amount: number;
  type: TransactionType;
  direction: 'CREDIT' | 'DEBIT';
  status: 'PENDING' | 'SUCCESS' | 'FAILED';
  reference: string;
  metadata?: any;
  created_at: string;
}

export interface WalletBalanceSummary {
  currency: 'NGN';
  ledgerBalanceMinor: number;
  pendingDebitsMinor: number;
  pendingCreditsMinor: number;
  availableBalanceMinor: number;
}

export interface FundReservation {
  id: string;
  organization_id: string;
  wallet_id: string;
  amount_minor: number;
  state: 'active' | 'consumed' | 'released' | 'expired';
  expires_at: string;
  consumed_journal_entry_id?: string | null;
  restoration_journal_entry_id?: string | null;
}

class LedgerService {
  async creditWallet(params: {
    walletId: string;
    amount: number;
    type: TransactionType;
    reference: string;
    sourceId?: string;
    metadata?: Record<string, any>;
  }): Promise<WalletTransaction> {
    const { data, error } = await supabase.rpc('atomic_wallet_credit', {
      p_wallet_id: params.walletId,
      p_amount: params.amount,
      p_type: params.type,
      p_reference: params.reference,
      p_metadata: { ...params.metadata, source_id: params.sourceId }
    });
    if (error) throw new LedgerTransactionError(error.message);
    return data as WalletTransaction;
  }

  async debitWallet(params: {
    walletId: string;
    amount: number;
    type: TransactionType;
    reference: string;
    destinationId?: string;
    metadata?: Record<string, any>;
  }): Promise<WalletTransaction> {
    const { data, error } = await supabase.rpc('atomic_wallet_debit', {
      p_wallet_id: params.walletId,
      p_amount: params.amount,
      p_type: params.type,
      p_reference: params.reference,
      p_metadata: { ...params.metadata, destination_id: params.destinationId }
    });
    if (error) {
      if (error.message.includes('Insufficient funds')) throw new InsufficientFundsError(error.message);
      throw new LedgerTransactionError(error.message);
    }
    return data as WalletTransaction;
  }

  async atomicP2PTransfer(params: {
    senderWalletId: string;
    recipientWalletId: string;
    amountMinor: number;
    reference: string;
  }): Promise<{ debitTxId: string; creditTxId: string }> {
    assertMinorUnits(params.amountMinor);
    const { data, error } = await supabase.rpc('atomic_p2p_transfer_minor', {
      p_sender_wallet_id: params.senderWalletId,
      p_recipient_wallet_id: params.recipientWalletId,
      p_amount_minor: String(params.amountMinor),
      p_reference: params.reference
    });
    if (error) {
      if (error.message.includes('Insufficient funds')) throw new InsufficientFundsError(error.message);
      throw new LedgerTransactionError(error.message);
    }
    return { debitTxId: data.debit_tx_id, creditTxId: data.credit_tx_id };
  }

  async atomicGroupTransfer(params: {
    groupId: string;
    recipientWalletId: string;
    amountMinor: number;
    reference: string;
    approvalRequestId: string;
  }): Promise<{ creditTxId: string; status: string }> {
    assertMinorUnits(params.amountMinor);
    const { data, error } = await supabase.rpc('atomic_group_transfer_minor', {
      p_group_id: params.groupId,
      p_recipient_wallet_id: params.recipientWalletId,
      p_amount_minor: String(params.amountMinor),
      p_reference: params.reference,
      p_approval_request_id: params.approvalRequestId
    });
    if (error) {
      if (error.message.includes('Insufficient group funds')) throw new InsufficientFundsError(error.message);
      throw new LedgerTransactionError(error.message);
    }
    return { creditTxId: data.credit_tx_id, status: data.status };
  }

  async getWalletBalanceSummary(walletId: string): Promise<WalletBalanceSummary> {
    const { data, error } = await supabase.rpc('wallet_balance_summary', { p_wallet_id: walletId });
    if (error) throw new LedgerTransactionError(error.message);
    return {
      currency: data.currency,
      ledgerBalanceMinor: Number(data.ledgerBalanceMinor),
      pendingDebitsMinor: Number(data.pendingDebitsMinor),
      pendingCreditsMinor: Number(data.pendingCreditsMinor),
      availableBalanceMinor: Number(data.availableBalanceMinor),
    };
  }

  async getGroupWalletBalanceSummary(groupId: string): Promise<WalletBalanceSummary> {
    const { data, error } = await supabase.rpc('group_wallet_balance_summary', { p_group_id: groupId });
    if (error) throw new LedgerTransactionError(error.message);
    return {
      currency: data.currency,
      ledgerBalanceMinor: Number(data.ledgerBalanceMinor),
      pendingDebitsMinor: Number(data.pendingDebitsMinor),
      pendingCreditsMinor: Number(data.pendingCreditsMinor),
      availableBalanceMinor: Number(data.availableBalanceMinor),
    };
  }

  async reserveWalletFunds(params: {
    walletId: string;
    amountMinor: number;
    sourceRecordId: string;
    idempotencyKey: string;
    correlationId: string;
    actorId: string;
    expiresAt: string;
  }): Promise<FundReservation> {
    assertMinorUnits(params.amountMinor);
    const { data, error } = await supabase.rpc('reserve_wallet_funds', {
      p_wallet_id: params.walletId,
      p_amount_minor: String(params.amountMinor),
      p_source_record_id: params.sourceRecordId,
      p_idempotency_key: params.idempotencyKey,
      p_correlation_id: params.correlationId,
      p_actor_id: params.actorId,
      p_expires_at: params.expiresAt,
    });
    if (error) {
      if (error.message.includes('Insufficient available funds')) throw new InsufficientFundsError(error.message);
      throw new LedgerTransactionError(error.message);
    }
    return data as FundReservation;
  }

  async consumeWalletReservation(reservationId: string, actorId: string): Promise<FundReservation> {
    const { data, error } = await supabase.rpc('consume_wallet_reservation', {
      p_reservation_id: reservationId,
      p_actor_id: actorId,
    });
    if (error) throw new LedgerTransactionError(error.message);
    return data as FundReservation;
  }

  async releaseWalletReservation(reservationId: string, actorId: string): Promise<FundReservation> {
    const { data, error } = await supabase.rpc('release_wallet_reservation', {
      p_reservation_id: reservationId,
      p_actor_id: actorId,
    });
    if (error) throw new LedgerTransactionError(error.message);
    return data as FundReservation;
  }

  async restoreWalletReservation(reservationId: string, actorId: string, reference: string): Promise<FundReservation> {
    const { data, error } = await supabase.rpc('restore_wallet_reservation', {
      p_reservation_id: reservationId,
      p_actor_id: actorId,
      p_reference: reference,
    });
    if (error) throw new LedgerTransactionError(error.message);
    return data as FundReservation;
  }
}

export const ledgerService = new LedgerService();
