import { apiClient } from '../api/client';
export interface StatementLine{id:string;journalEntryId:string;effectiveDate:string;postedAt:string;description:string;sourceDomain:string;side:'debit'|'credit';amountMinor:string;memo?:string}
export interface MemberStatement{memberId:string;from:string;to:string;cutoff:string;account:{code:string;name:string;currency:string};openingBalanceMinor:string;pageOpeningBalanceMinor:string;closingBalanceMinor:string;total:number;lines:StatementLine[]}
export const accountingMemberStatementAPI={read:async(q:{memberId?:string;currency:string;from:string;to:string;cutoff:string;offset:number;limit:number})=>(await apiClient.get<{statement:MemberStatement}>('/accounting/member-statement',{params:q})).data.statement};
