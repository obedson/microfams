import { supabase } from '../../utils/supabase.js';

export interface EscrowContractGateway {
  create(input: Record<string, unknown>): Promise<unknown>;
  activate(input: Record<string, unknown>): Promise<unknown>;
  fund(input: Record<string, unknown>): Promise<unknown>;
}

export class SupabaseEscrowContractGateway implements EscrowContractGateway {
  async create(input: Record<string, unknown>) {
    const { data, error } = await supabase.rpc('create_escrow_contract_draft', input);
    if (error || data === null) throw error ?? new Error('Escrow contract creation failed');
    return data;
  }

  async activate(input: Record<string, unknown>) {
    const { data, error } = await supabase.rpc('activate_escrow_contract', input);
    if (error || data === null) throw error ?? new Error('Escrow contract activation failed');
    return data;
  }

  async fund(input: Record<string, unknown>) {
    const { data, error } = await supabase.rpc('fund_escrow_contract_from_wallet', input);
    if (error || data === null) throw error ?? new Error('Escrow contract funding failed');
    return data;
  }
}

export class EscrowContractService {
  constructor(private readonly gateway: EscrowContractGateway = new SupabaseEscrowContractGateway()) {}

  create(input: Record<string, unknown>) {
    if (!Number.isSafeInteger(input.p_amount_minor) || Number(input.p_amount_minor) <= 0) throw new Error('ESCROW_AMOUNT_INVALID');
    if (typeof input.p_currency !== 'string' || !/^[A-Z]{3}$/.test(input.p_currency)) throw new Error('ESCROW_CURRENCY_INVALID');
    if (typeof input.p_idempotency_key !== 'string' || input.p_idempotency_key.length < 8) throw new Error('ESCROW_IDEMPOTENCY_INVALID');
    return this.gateway.create(input);
  }

  activate(input: Record<string, unknown>) {
    if (typeof input.p_idempotency_key !== 'string' || input.p_idempotency_key.length < 8) throw new Error('ESCROW_IDEMPOTENCY_INVALID');
    return this.gateway.activate(input);
  }

  fund(input: Record<string, unknown>) {
    if (typeof input.p_contract !== 'string' || input.p_contract.length === 0) throw new Error('ESCROW_CONTRACT_INVALID');
    if (typeof input.p_idempotency_key !== 'string' || input.p_idempotency_key.length < 8 || input.p_idempotency_key.length > 160) throw new Error('ESCROW_IDEMPOTENCY_INVALID');
    if (typeof input.p_correlation_id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(input.p_correlation_id)) throw new Error('ESCROW_CORRELATION_INVALID');
    return this.gateway.fund(input);
  }
}

export const escrowContractService = new EscrowContractService();
