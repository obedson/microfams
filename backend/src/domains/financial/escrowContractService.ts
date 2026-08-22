import { supabase } from '../../utils/supabase.js';

export interface EscrowContractGateway {
  create(input: Record<string, unknown>): Promise<unknown>;
  activate(input: Record<string, unknown>): Promise<unknown>;
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
}

export const escrowContractService = new EscrowContractService();
