// Tenant-scoped API contracts for maker-checker reconciliation resolution and write-off.
import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { reconciliationService } from '../domains/financial/reconciliationService.js';
const uuid=Joi.string().uuid().required();
const investigation=Joi.object({reason:Joi.string().trim().min(12).max(500).required()});
const resolution=Joi.object({resolutionType:Joi.string().valid('matched_evidence','provider_correction','compensating_adjustment','writeoff').required(),resolutionReason:Joi.string().trim().min(12).max(500).required(),evidenceReference:Joi.string().trim().min(1).max(200).required(),compensatingJournalEntryId:Joi.string().uuid().optional(),idempotencyKey:Joi.string().trim().min(8).max(160).required()});
const decision=Joi.object({approve:Joi.boolean().required(),decisionReason:Joi.string().trim().min(12).max(500).required()});
export const reconciliationController={
 startInvestigation:async(req:TenantRequest,res:Response)=>{const {error,value}=investigation.validate(req.body,{stripUnknown:true});if(error)return res.status(400).json({success:false,error:'INVALID_RECONCILIATION_INVESTIGATION'});try{return res.status(201).json({success:true,data:await reconciliationService.startExceptionInvestigation({exceptionId:req.params.exceptionId,actorId:req.user!.id,reason:value.reason}),correlation_id:req.correlationId});}catch{return res.status(409).json({success:false,error:'RECONCILIATION_INVESTIGATION_REJECTED',correlation_id:req.correlationId});}},
 requestResolution:async(req:TenantRequest,res:Response)=>{const {error,value}=resolution.validate(req.body,{stripUnknown:true});if(error)return res.status(400).json({success:false,error:'INVALID_RECONCILIATION_RESOLUTION'});try{return res.status(201).json({success:true,data:await reconciliationService.requestExceptionResolution({exceptionId:req.params.exceptionId,actorId:req.user!.id,...value}),correlation_id:req.correlationId});}catch{return res.status(409).json({success:false,error:'RECONCILIATION_RESOLUTION_REJECTED',correlation_id:req.correlationId});}},
 decideResolution:async(req:TenantRequest,res:Response)=>{const {error,value}=decision.validate(req.body,{stripUnknown:true});if(error)return res.status(400).json({success:false,error:'INVALID_RECONCILIATION_DECISION'});try{return res.status(200).json({success:true,data:await reconciliationService.decideExceptionResolution({resolutionRequestId:req.params.requestId,actorId:req.user!.id,...value}),correlation_id:req.correlationId});}catch{return res.status(409).json({success:false,error:'RECONCILIATION_DECISION_REJECTED',correlation_id:req.correlationId});}},
};
