import { apiClient } from '../api/client';
export interface BalanceLine{accountId:string;code:string;name:string;accountClass:'asset'|'liability'|'equity';amountMinor:string}
export interface BalanceSheet{currency:string;from:string;to:string;cutoff:string;period:{name:string;status:string};accounts:BalanceLine[];totalAssetsMinor:string;totalLiabilitiesMinor:string;totalEquityMinor:string;currentPeriodNetIncomeMinor:string;totalLiabilitiesAndEquityMinor:string}
export const accountingBalanceAPI={read:async(q:{currency:string;from:string;to:string;cutoff:string})=>(await apiClient.get<{balanceSheet:BalanceSheet}>('/accounting/balance-sheet',{params:q})).data.balanceSheet};
