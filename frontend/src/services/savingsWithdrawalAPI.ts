import { apiClient } from '../api/client';
export interface SavingsWithdrawal { id:string; enrolment_id:string; requested_minor:number; net_payout_minor:number; currency:string; state:string; is_early:boolean; early_withdrawal_rule:string; }
const key=(scope:string)=>scope+':'+Date.now()+':'+Math.random().toString(36).slice(2);
export const savingsWithdrawalAPI={
 list:async(id:string)=>(await apiClient.get<{withdrawals:SavingsWithdrawal[]}>('/savings/enrolments/'+id+'/withdrawals')).data.withdrawals,
 reviews:async()=>(await apiClient.get<{withdrawals:SavingsWithdrawal[]}>('/savings/withdrawal-reviews')).data.withdrawals,
 request:async(id:string,amountMinor:number)=>(await apiClient.post<{withdrawal:SavingsWithdrawal}>('/savings/enrolments/'+id+'/withdrawals',{amountMinor,idempotencyKey:key('savings-withdrawal:'+id)})).data.withdrawal,
 approve:async(id:string)=>(await apiClient.post<{withdrawal:SavingsWithdrawal}>('/savings/withdrawals/'+id+'/approve',{idempotencyKey:key('savings-withdrawal-approve:'+id)})).data.withdrawal,
 reject:async(id:string,reason:string)=>(await apiClient.post<{withdrawal:SavingsWithdrawal}>('/savings/withdrawals/'+id+'/reject',{reason,idempotencyKey:key('savings-withdrawal-reject:'+id)})).data.withdrawal,
 cancel:async(id:string,reason:string)=>(await apiClient.post<{withdrawal:SavingsWithdrawal}>('/savings/withdrawals/'+id+'/cancel',{reason,idempotencyKey:key('savings-withdrawal-cancel:'+id)})).data.withdrawal,
};
