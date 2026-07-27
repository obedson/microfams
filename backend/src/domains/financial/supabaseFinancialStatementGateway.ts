import { supabase } from '../../utils/supabase.js';
import { FinancialStatementGateway, StatementQuery } from './statementTypes.js';

export class StatementAccessError extends Error {
  constructor() {
    super('Statement account was not found or is not available to this actor.');
    this.name = 'StatementAccessError';
  }
}

export class SupabaseFinancialStatementGateway implements FinancialStatementGateway {
  async assertOwnerAccess(query: StatementQuery, actorId: string): Promise<void> {
    if (query.ownerType === 'user') {
      if (query.ownerId !== actorId) throw new StatementAccessError();
      return;
    }
    const { data } = await supabase.from('group_members')
      .select('id')
      .eq('group_id', query.ownerId)
      .eq('user_id', actorId)
      .eq('organization_id', query.organizationId)
      .eq('status', 'active')
      .maybeSingle();
    if (!data) throw new StatementAccessError();
  }

  async read(query: StatementQuery) {
    const { data, error } = await supabase.rpc('read_financial_statement', {
      p_organization_id: query.organizationId,
      p_owner_type: query.ownerType,
      p_owner_id: query.ownerId,
      p_currency: query.currency,
      p_from: query.from,
      p_to: query.to,
      p_cutoff: query.cutoff,
      p_offset: (query.page - 1) * query.limit,
      p_limit: query.limit,
    });
    if (error || !data) throw new StatementAccessError();
    return {
      account: data.account,
      openingBalanceMinor: data.openingBalanceMinor,
      pageOpeningBalanceMinor: data.pageOpeningBalanceMinor,
      closingBalanceMinor: data.closingBalanceMinor,
      lines: data.lines,
      total: data.total,
    };
  }
}
