import { Response } from 'express';
import Joi from 'joi';
import { ApproveInvestmentAllocationPlanCommand,CreateInvestmentAllocationPlanCommand,InvestmentAllocationPlanService,InvestmentAllocationPlanValidationError,RecognizeInvestmentRefundObligationsCommand,investmentAllocationPlanService } from '../domains/financial/investmentAllocationPlanService.js';
import { TenantRequest } from '../middleware/tenant.js';
const createSchema=Joi.object({settlementCutoff:Joi.date().iso().required(),correlationId:Joi.string().uuid().required(),idempotencyKey:Joi.string().min(8).max(160).required()});
const approveSchema=Joi.object({idempotencyKey:Joi.string().min(8).max(160).required()});
const recognizeRefundsSchema=Joi.object({correlationId:Joi.string().uuid().required(),idempotencyKey:Joi.string().min(8).max(160).required()});
export class InvestmentAllocationPlanController {
  constructor(private readonly service:InvestmentAllocationPlanService=investmentAllocationPlanService){}
  create=async(req:TenantRequest,res:Response)=>{const v=this.validate<CreateInvestmentAllocationPlanCommand>(createSchema,req.body,res);if(!v)return;try{return res.status(201).json(await this.service.create({...v,organizationId:req.tenant!.id,actorId:req.user!.id,productId:req.params.productId}));}catch(e){return this.error(e,res);}};
  approve=async(req:TenantRequest,res:Response)=>{const v=this.validate<ApproveInvestmentAllocationPlanCommand>(approveSchema,req.body,res);if(!v)return;try{return res.json(await this.service.approve({...v,organizationId:req.tenant!.id,actorId:req.user!.id,planId:req.params.planId}));}catch(e){return this.error(e,res);}};
  recognizeRefunds=async(req:TenantRequest,res:Response)=>{const v=this.validate<RecognizeInvestmentRefundObligationsCommand>(recognizeRefundsSchema,req.body,res);if(!v)return;try{return res.status(201).json(await this.service.recognizeRefunds({...v,organizationId:req.tenant!.id,actorId:req.user!.id,planId:req.params.planId}));}catch(e){return this.error(e,res);}};
  private validate<T>(schema:Joi.ObjectSchema,body:unknown,res:Response):T|undefined{const {error,value}=schema.validate(body,{abortEarly:false,stripUnknown:true});if(!error)return value as T;res.status(400).json({success:false,error:'INVALID_INVESTMENT_ALLOCATION_COMMAND',details:error.details.map(d=>d.message)});return undefined;}
  private error(e:unknown,res:Response){if(e instanceof InvestmentAllocationPlanValidationError)return res.status(400).json({success:false,error:'INVALID_INVESTMENT_ALLOCATION_COMMAND',message:e.message});return res.status(409).json({success:false,error:'INVESTMENT_ALLOCATION_REJECTED',message:'The allocation plan command could not be completed in its current state.'});}
}
export const investmentAllocationPlanController=new InvestmentAllocationPlanController();
