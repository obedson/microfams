import{apiClient}from'../api/client';export const dividendEntitlementAPI={calculate:(body:any)=>(apiClient.post<{distributionId:string}>('/accounting/dividends/entitlements',body)).then(r=>r.data)};
