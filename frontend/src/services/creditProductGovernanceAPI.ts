import { apiClient } from '../api/client';
export interface GovernedLoanProductVersion { id:string;version:number;state:'draft'|'pending_approval'|'active'|'retired';lender_name:string;disclosure_version:string;disclosure_content_hash:string;[key:string]:unknown }
export interface GovernedLoanProduct { product:{id:string;code:string;name:string;currency:string;state:string;current_version:number};versions:GovernedLoanProductVersion[] }
export type LoanProductCommand=Record<string,unknown>&{idempotencyKey:string};
export const creditProductGovernanceAPI={
  list:async()=>(await apiClient.get<{products:GovernedLoanProduct[]}>('/credit/products/governed')).data.products,
  create:async(command:LoanProductCommand)=>(await apiClient.post('/credit/products',command)).data,
  revise:async(productId:string,command:LoanProductCommand)=>(await apiClient.post(`/credit/products/${productId}/versions`,command)).data,
  submit:async(productId:string,version:number,idempotencyKey:string)=>(await apiClient.post(`/credit/products/${productId}/submit`,{version,idempotencyKey})).data,
  approve:async(productId:string,version:number,idempotencyKey:string)=>(await apiClient.post(`/credit/products/${productId}/approve`,{version,idempotencyKey})).data,
};
