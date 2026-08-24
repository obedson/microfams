import { apiClient } from '../api/client';
export interface SavingsCertification{id:string;providerCode:string;environment:string;jurisdiction:string;currency:string;version:number;configurationFingerprint:string;status:string}
const key=(s:string)=>s+':'+Date.now();
export const savingsProviderCertificationAPI={
 list:async()=>(await apiClient.get<{certifications:SavingsCertification[]}>('/savings/provider-certifications')).data.certifications,
 create:async(input:Record<string,unknown>)=>(await apiClient.post('/savings/provider-certifications',{...input,idempotencyKey:key('cert-create')})).data,
 scenario:async(id:string,input:Record<string,unknown>)=>(await apiClient.post('/savings/provider-certifications/'+id+'/scenarios',{...input,idempotencyKey:key('cert-scenario')})).data,
 submit:async(id:string,reason:string)=>(await apiClient.post('/savings/provider-certifications/'+id+'/submit',{reason,idempotencyKey:key('cert-submit')})).data,
 decide:async(id:string,approve:boolean,reason:string)=>(await apiClient.post('/savings/provider-certifications/'+id+'/decide',{approve,reason,idempotencyKey:key('cert-decide')})).data,
 readiness:async(q:Record<string,string>)=>(await apiClient.get('/savings/provider-readiness',{params:q})).data.readiness};
