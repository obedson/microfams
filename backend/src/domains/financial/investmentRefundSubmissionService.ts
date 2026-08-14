import crypto from 'crypto';
import { supabase } from '../../utils/supabase.js';
import { configuredPaymentAdapter } from './paymentAdapters.js';
import { PaymentAdapter, ProviderRefundResult } from './paymentTypes.js';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export interface SubmitInvestmentRefundCommand { organizationId:string;actorId:string;obligationId:string;correlationId:string;idempotencyKey:string; }
interface PreparedAttempt { id:string;state:string;provider_name:string;provider_environment:'deterministic'|'sandbox'|'live'; }
interface RefundObligation { id:string;amount_minor:number|string;currency:'NGN'; }
interface PreparedSubmission { replayed:boolean;attempt:PreparedAttempt;obligation:RefundObligation;provider_payment_reference:string; }
interface CompleteSubmissionCommand { organizationId:string;actorId:string;attemptId:string;state:'submitted'|'processing'|'unknown'|'failed'|'manual_review';providerReportedState?:ProviderRefundResult['status'];providerReference?:string;reportedAmountMinor?:number;reportedCurrency?:string;failureCode?:string;failureReason?:string;resultHash:string; }
export interface InvestmentRefundSubmissionGateway { begin(command:SubmitInvestmentRefundCommand):Promise<PreparedSubmission>;complete(command:CompleteSubmissionCommand):Promise<unknown>; }
export class SupabaseInvestmentRefundSubmissionGateway implements InvestmentRefundSubmissionGateway {
 private async rpc(name:string,args:Record<string,unknown>){const {data,error}=await supabase.rpc(name,args);if(error||data===null)throw error??new Error('Investment refund submission storage returned no result.');return data;}
 begin(c:SubmitInvestmentRefundCommand){return this.rpc('begin_investment_refund_submission',{p_organization:c.organizationId,p_actor:c.actorId,p_obligation:c.obligationId,p_correlation:c.correlationId,p_idempotency_key:c.idempotencyKey}) as Promise<PreparedSubmission>;}
 complete(c:CompleteSubmissionCommand){return this.rpc('complete_investment_refund_submission',{p_organization:c.organizationId,p_actor:c.actorId,p_attempt:c.attemptId,p_state:c.state,p_provider_reported_state:c.providerReportedState??null,p_provider_reference:c.providerReference??null,p_reported_amount_minor:c.reportedAmountMinor??null,p_reported_currency:c.reportedCurrency??null,p_failure_code:c.failureCode??null,p_failure_reason:c.failureReason??null,p_result_hash:c.resultHash});}
}
export class InvestmentRefundSubmissionValidationError extends Error { constructor(message:string){super(message);this.name='InvestmentRefundSubmissionValidationError';} }
const resultHash=(facts:Record<string,unknown>)=>crypto.createHash('sha256').update(JSON.stringify(facts)).digest('hex');
export class InvestmentRefundSubmissionService {
 constructor(private readonly gateway:InvestmentRefundSubmissionGateway=new SupabaseInvestmentRefundSubmissionGateway(),private readonly adapterFactory:()=>PaymentAdapter=configuredPaymentAdapter){}
 async submit(command:SubmitInvestmentRefundCommand){
  this.validate(command);const prepared=await this.gateway.begin(command);if(prepared.replayed||prepared.attempt.state!=='prepared')return {attempt:prepared.attempt,obligation:prepared.obligation};
  const amountMinor=Number(prepared.obligation.amount_minor);if(!Number.isSafeInteger(amountMinor)||amountMinor<=0||prepared.obligation.currency!=='NGN')throw new InvestmentRefundSubmissionValidationError('Stored investment refund money is invalid.');
  if(prepared.attempt.provider_environment==='live')return this.complete(command,prepared,{state:'manual_review',failureCode:'live_submission_not_activated',failureReason:'Live investment refund submission is not enabled in this release.'});
  let adapter:PaymentAdapter;try{adapter=this.adapterFactory();}catch{return this.complete(command,prepared,{state:'manual_review',failureCode:'provider_configuration_incomplete',failureReason:'The original provider is not configured for submission.'});}
  if(adapter.name!==prepared.attempt.provider_name||adapter.environment!==prepared.attempt.provider_environment)return this.complete(command,prepared,{state:'manual_review',failureCode:'original_provider_unavailable',failureReason:'The configured adapter does not match the original settlement provider.'});
  let result:ProviderRefundResult;
  try{result=await adapter.refund({internalReference:'investment-refund-'+prepared.attempt.id,providerPaymentReference:prepared.provider_payment_reference,amountMinor,currency:'NGN',reason:'Approved investment oversubscription refund'});}
  catch{return this.complete(command,prepared,{state:'unknown',failureCode:'provider_response_ambiguous',failureReason:'The provider submission result is unknown and requires recovery.'});}
  if(!Number.isSafeInteger(result.amountMinor)||result.amountMinor!==amountMinor||result.currency!==prepared.obligation.currency)return this.complete(command,prepared,{state:'manual_review',providerReportedState:result.status,providerReference:result.providerReference,reportedAmountMinor:result.amountMinor,reportedCurrency:result.currency,failureCode:'provider_money_mismatch',failureReason:'The provider result did not match the approved refund obligation.'});
  const state=result.status==='failed'||result.status==='cancelled'?'failed':result.status==='submitted'?'submitted':'processing';
  return this.complete(command,prepared,{state,providerReportedState:result.status,providerReference:result.providerReference,reportedAmountMinor:result.amountMinor,reportedCurrency:result.currency,failureCode:result.failureCode,failureReason:result.failureReason});
 }
 private complete(command:SubmitInvestmentRefundCommand,prepared:PreparedSubmission,outcome:Omit<CompleteSubmissionCommand,'organizationId'|'actorId'|'attemptId'|'resultHash'>){
  const facts={state:outcome.state,providerReportedState:outcome.providerReportedState??null,providerReference:outcome.providerReference??null,reportedAmountMinor:outcome.reportedAmountMinor??null,reportedCurrency:outcome.reportedCurrency??null,failureCode:outcome.failureCode??null,failureReason:outcome.failureReason??null};
  return this.gateway.complete({organizationId:command.organizationId,actorId:command.actorId,attemptId:prepared.attempt.id,...outcome,resultHash:resultHash(facts)});
 }
 private validate(c:SubmitInvestmentRefundCommand){if(!UUID.test(c.organizationId)||!UUID.test(c.actorId)||!UUID.test(c.obligationId)||!UUID.test(c.correlationId)||typeof c.idempotencyKey!=='string'||c.idempotencyKey.length<8||c.idempotencyKey.length>160)throw new InvestmentRefundSubmissionValidationError('Investment refund submission identity is invalid.');}
}
export const investmentRefundSubmissionService=new InvestmentRefundSubmissionService();
