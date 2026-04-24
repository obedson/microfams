import { supabase } from '../utils/supabase.js';

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

class LedgerService {
  /**
   * Requirement 8.1, 8.2, 8.3: Credit a wallet atomically via Supabase RPC
   */
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

    if (error) {
      throw new LedgerTransactionError(error.message);
    }

    // Since RPC returns the ID, we might need to fetch the full record or just return the ID
    // For now, let's assume the RPC returns the full record or we fetch it if needed.
    // Usually, rpc returns whatever is returned by the SQL function.
    return data as WalletTransaction;
  }

  /**
   * Requirement 8.1, 8.2, 8.3: Debit a wallet atomically via Supabase RPC
   */
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
      if (error.message.includes('Insufficient funds')) {
        throw new InsufficientFundsError(error.message);
      }
      throw new LedgerTransactionError(error.message);
    }

    return data as WalletTransaction;
  }

  /**
   * Requirement 6.5, 6.7: Atomic P2P Transfer
   */
  async atomicP2PTransfer(params: {
    senderWalletId: string;
    recipientWalletId: string;
    amount: number;
    reference: string;
  }): Promise<{ debitTxId: string; creditTxId: string }> {
    const { data, error } = await supabase.rpc('atomic_p2p_transfer', {
      p_sender_wallet_id: params.senderWalletId,
      p_recipient_wallet_id: params.recipientWalletId,
      p_amount: params.amount,
      p_reference: params.reference
    });

    if (error) {
      if (error.message.includes('Insufficient funds')) {
        throw new InsufficientFundsError(error.message);
      }
      throw new LedgerTransactionError(error.message);
    }

    return {
      debitTxId: data.debit_tx_id,
      creditTxId: data.credit_tx_id
    };
  }

  /**
   * Requirement 4.4, 4.7: Atomic Group Transfer
   */
  async atomicGroupTransfer(params: {
    groupId: string;
    recipientWalletId: string;
    amount: number;
    reference: string;
    approvalRequestId: string;
  }): Promise<{ creditTxId: string; status: string }> {
    const { data, error } = await supabase.rpc('atomic_group_transfer', {
      p_group_id: params.groupId,
      p_recipient_wallet_id: params.recipientWalletId,
      p_amount: params.amount,
      p_reference: params.reference,
      p_approval_request_id: params.approvalRequestId
    });

    if (error) {
      if (error.message.includes('Insufficient group funds')) {
        throw new InsufficientFundsError(error.message);
      }
      throw new LedgerTransactionError(error.message);
    }

    return {
      creditTxId: data.credit_tx_id,
      status: data.status
    };
  }
}

export const ledgerService = new LedgerService();
