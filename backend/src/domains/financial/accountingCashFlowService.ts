import { supabase } from '../../utils/supabase.js';
import { AccountingReportValidationError } from './accountingIncomeStatementService.js';

export interface CashFlowQuery { organizationId:string; actorId:string; currency:string; from:string; to:string; cutoff:string }
export class AccountingCashFlowService {
  async read(query: CashFlowQuery) {
    if (!/^[A-Z]{3}$/.test(query.currency) || !/^\d{4}-\d{2}-\d{2}$/.test(query.from) || !/^\d{4}-\d{2}-\d{2}$/.test(query.to) || query.from > query.to || Number.isNaN(Date.parse(query.cutoff))) throw new AccountingReportValidationError('Cash-flow query is invalid.');
    const { data, error } = await supabase.rpc('read_accounting_cash_flow', { p_organization:query.organizationId, p_actor:query.actorId, p_currency:query.currency, p_from:query.from, p_to:query.to, p_cutoff:query.cutoff });
    if (error) throw error;
    return data;
  }
}
export const accountingCashFlowService = new AccountingCashFlowService();
