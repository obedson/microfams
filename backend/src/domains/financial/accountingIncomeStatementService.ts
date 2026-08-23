import { supabase } from '../../utils/supabase.js';

export interface IncomeStatementQuery { organizationId:string; actorId:string; currency:string; from:string; to:string; cutoff:string }
export class AccountingReportValidationError extends Error {}
export class AccountingIncomeStatementService {
  async read(query: IncomeStatementQuery) {
    if (!/^[A-Z]{3}$/.test(query.currency) || !/^\d{4}-\d{2}-\d{2}$/.test(query.from) || !/^\d{4}-\d{2}-\d{2}$/.test(query.to) || query.from > query.to || Number.isNaN(Date.parse(query.cutoff))) throw new AccountingReportValidationError('Income statement query is invalid.');
    const { data, error } = await supabase.rpc('read_accounting_income_statement', { p_organization:query.organizationId, p_actor:query.actorId, p_currency:query.currency, p_from:query.from, p_to:query.to, p_cutoff:query.cutoff });
    if (error) throw error;
    return data;
  }
}
export const accountingIncomeStatementService = new AccountingIncomeStatementService();
