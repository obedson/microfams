import { supabase } from '../../utils/supabase.js';
import { AccountingReportValidationError } from './accountingIncomeStatementService.js';
export interface BalanceSheetQuery { organizationId:string; actorId:string; currency:string; from:string; to:string; cutoff:string }
export class AccountingBalanceSheetService { async read(q:BalanceSheetQuery){if(!/^[A-Z]{3}$/.test(q.currency)||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(q.from)||!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(q.to)||q.from>q.to||Number.isNaN(Date.parse(q.cutoff)))throw new AccountingReportValidationError('Balance sheet query is invalid.');const{data,error}=await supabase.rpc('read_accounting_balance_sheet',{p_organization:q.organizationId,p_actor:q.actorId,p_currency:q.currency,p_from:q.from,p_to:q.to,p_cutoff:q.cutoff});if(error)throw error;return data;} }
export const accountingBalanceSheetService=new AccountingBalanceSheetService();
