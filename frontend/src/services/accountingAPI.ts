import { apiClient } from '../api/client';
export interface IncomeLine { accountId:string; code:string; name:string; accountClass:'revenue'|'expense'; amountMinor:string }
export interface IncomeStatement { currency:string; from:string; to:string; cutoff:string; period:{name:string;status:string}; revenue:IncomeLine[]; totalRevenueMinor:string; totalExpenseMinor:string; netIncomeMinor:string }
export const accountingAPI={ incomeStatement:async(query:{currency:string;from:string;to:string;cutoff:string})=>(await apiClient.get<{incomeStatement:IncomeStatement}>('/accounting/income-statement',{params:query})).data.incomeStatement };
