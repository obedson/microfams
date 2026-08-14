import { supabase } from '../../utils/supabase.js';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export interface CreateInvestmentAllocationPlanCommand { organizationId:string; actorId:string; productId:string; settlementCutoff:string; correlationId:string; idempotencyKey:string; }
export interface ApproveInvestmentAllocationPlanCommand { organizationId:string; actorId:string; planId:string; idempotencyKey:string; }
export interface RecognizeInvestmentRefundObligationsCommand { organizationId:string; actorId:string; planId:string; correlationId:string; idempotencyKey:string; }
export interface ExecuteInvestmentAllocationPlanCommand { organizationId:string; actorId:string; planId:string; correlationId:string; idempotencyKey:string; }
export interface InvestmentAllocationPlanGateway { create(command:CreateInvestmentAllocationPlanCommand):Promise<unknown>; approve(command:ApproveInvestmentAllocationPlanCommand):Promise<unknown>; recognizeRefunds(command:RecognizeInvestmentRefundObligationsCommand):Promise<unknown>; execute(command:ExecuteInvestmentAllocationPlanCommand):Promise<unknown>; }
export class InvestmentAllocationPlanValidationError extends Error { constructor(message:string){super(message);this.name='InvestmentAllocationPlanValidationError';} }
export class SupabaseInvestmentAllocationPlanGateway implements InvestmentAllocationPlanGateway {
  private async rpc(name:string,args:Record<string,unknown>){const {data,error}=await supabase.rpc(name,args);if(error||data===null)throw error??new Error('Investment allocation plan storage returned no result.');return data;}
  create(c:CreateInvestmentAllocationPlanCommand){return this.rpc('create_investment_allocation_plan',{p_organization:c.organizationId,p_actor:c.actorId,p_product:c.productId,p_settlement_cutoff:c.settlementCutoff,p_correlation:c.correlationId,p_idempotency_key:c.idempotencyKey});}
  approve(c:ApproveInvestmentAllocationPlanCommand){return this.rpc('approve_investment_allocation_plan',{p_organization:c.organizationId,p_actor:c.actorId,p_plan:c.planId,p_idempotency_key:c.idempotencyKey});}
  recognizeRefunds(c:RecognizeInvestmentRefundObligationsCommand){return this.rpc('recognize_investment_refund_obligations',{p_organization:c.organizationId,p_actor:c.actorId,p_plan:c.planId,p_correlation:c.correlationId,p_idempotency_key:c.idempotencyKey});}
  execute(c:ExecuteInvestmentAllocationPlanCommand){return this.rpc('execute_investment_allocation_plan',{p_organization:c.organizationId,p_actor:c.actorId,p_plan:c.planId,p_correlation:c.correlationId,p_idempotency_key:c.idempotencyKey});}
}
export class InvestmentAllocationPlanService {
  constructor(private readonly gateway:InvestmentAllocationPlanGateway=new SupabaseInvestmentAllocationPlanGateway()){}
  create(c:CreateInvestmentAllocationPlanCommand){this.identity(c.organizationId,c.actorId,c.productId,c.idempotencyKey);if(!UUID.test(c.correlationId)||Number.isNaN(Date.parse(c.settlementCutoff)))throw new InvestmentAllocationPlanValidationError('Allocation plan cutoff or correlation identity is invalid.');return this.gateway.create(c);}
  approve(c:ApproveInvestmentAllocationPlanCommand){this.identity(c.organizationId,c.actorId,c.planId,c.idempotencyKey);return this.gateway.approve(c);}
  recognizeRefunds(c:RecognizeInvestmentRefundObligationsCommand){this.identity(c.organizationId,c.actorId,c.planId,c.idempotencyKey);if(!UUID.test(c.correlationId))throw new InvestmentAllocationPlanValidationError('Refund recognition correlation identity is invalid.');return this.gateway.recognizeRefunds(c);}
  execute(c:ExecuteInvestmentAllocationPlanCommand){this.identity(c.organizationId,c.actorId,c.planId,c.idempotencyKey);if(!UUID.test(c.correlationId))throw new InvestmentAllocationPlanValidationError('Allocation execution correlation identity is invalid.');return this.gateway.execute(c);}
  private identity(org:string,actor:string,record:string,key:string){if(!UUID.test(org)||!UUID.test(actor)||!UUID.test(record)||typeof key!=='string'||key.length<8||key.length>160)throw new InvestmentAllocationPlanValidationError('Allocation plan command identity is invalid.');}
}
export const investmentAllocationPlanService=new InvestmentAllocationPlanService();
