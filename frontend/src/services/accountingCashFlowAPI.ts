import { apiClient } from '../api/client';
export type CashFlowDomain='operating'|'investing'|'financing'|'unclassified';
export interface CashMovement{journalEntryId:string;effectiveDate:string;sourceDomain:string;description:string;domain:CashFlowDomain;amountMinor:string}
export interface CashFlowReport{currency:string;from:string;to:string;cutoff:string;period:{name:string;status:string};movements:CashMovement[];operatingCashFlowMinor:string;investingCashFlowMinor:string;financingCashFlowMinor:string;unclassifiedCashFlowMinor:string;netChangeInCashMinor:string}
export const accountingCashFlowAPI={read:async(q:{currency:string;from:string;to:string;cutoff:string})=>(await apiClient.get<{cashFlow:CashFlowReport}>('/accounting/cash-flow',{params:q})).data.cashFlow};
