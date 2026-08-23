import { apiClient } from '../api/client';
export interface BudgetLine{accountId:string;code:string;name:string;budgetMinor:string;actualMinor:string;varianceMinor:string}
export interface BudgetReport{currency:string;from:string;to:string;cutoff:string;period:{name:string};budgets:Array<{budgetId:string;budgetKey:string;name:string;version:number;totalMinor:string;lines:BudgetLine[]}>}
export const accountingBudgetAPI={read:async(q:{currency:string;from:string;to:string;cutoff:string})=>(await apiClient.get<{report:BudgetReport}>('/accounting/budget-vs-actual',{params:q})).data.report};
