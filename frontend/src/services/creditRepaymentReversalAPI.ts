import { apiClient } from '../api/client';
export const creditRepaymentReversalAPI={
 propose:async(a:string,c:string,r:string,body:Record<string,unknown>)=>(await apiClient.post('/credit/admin/applications/'+a+'/contracts/'+c+'/repayments/'+r+'/reversal',body)).data,
 decide:async(a:string,c:string,r:string,body:Record<string,unknown>)=>(await apiClient.post('/credit/admin/applications/'+a+'/contracts/'+c+'/repayment-reversals/'+r+'/decision',body)).data,
};
