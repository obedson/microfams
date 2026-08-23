import { apiClient } from '../api/client';

export interface LoanProductVersion {
  id: string; version: number; lender_type: string; lender_name: string; eligible_borrower_types: string[];
  purposes: string[]; minimum_principal_minor: number; maximum_principal_minor: number;
  minimum_tenor_days: number; maximum_tenor_days: number; repayment_frequency: string;
  interest_method: string; nominal_annual_rate_basis_points: number; apr_basis_points: number;
  effective_annual_cost_basis_points: number; fees: Array<{code:string;label:string;calculation:string;amountMinor?:number;rateBasisPoints?:number;timing:string}>;
  grace_period_days: number; disclosure_version: string; disclosure_content_hash: string;
}
export interface ActiveLoanProduct { product:{id:string;code:string;name:string;currency:string;state:string}; version:LoanProductVersion }
export const creditProductsAPI={ listActive:async()=>(await apiClient.get<{products:ActiveLoanProduct[]}>('/credit/products')).data.products };
