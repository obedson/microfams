import { Response } from 'express';
import Joi from 'joi';
import { TenantRequest } from '../middleware/tenant.js';
import { groupInvitationService } from '../services/groupInvitationService.js';

const commandKey=(req:TenantRequest)=>{const value=req.header('Idempotency-Key');if(!value||!/^[A-Za-z0-9._:-]{8,128}$/.test(value))throw Object.assign(new Error('IDEMPOTENCY_KEY_REQUIRED'),{statusCode:400});return value;};
const known=/^(GROUP_|INVITEE_|IDEMPOTENCY_)[A-Z_]+$/;
const fail=(res:Response,error:any)=>{const code=known.test(error?.message)?error.message:'GROUP_INVITATION_COMMAND_FAILED';const status=error?.statusCode??(code.includes('NOT_FOUND')?404:code.includes('PERMISSION')?403:code.includes('INVALID')||code.includes('KEY_REQUIRED')?400:409);return res.status(status).json({error:code});};
const context=(req:TenantRequest)=>({organizationId:req.tenant!.id,groupId:req.params.id,actorId:req.user!.id});

export const groupInvitationController={
  async create(req:TenantRequest,res:Response){const {error,value}=Joi.object({intendedUserId:Joi.string().uuid().required(),expiresAt:Joi.date().iso().greater('now').required()}).validate(req.body,{stripUnknown:true});if(error)return res.status(400).json({error:error.message});try{const data=await groupInvitationService.create({...context(req),intendedUserId:value.intendedUserId,expiresAt:new Date(value.expiresAt).toISOString(),idempotencyKey:commandKey(req)});res.set('Cache-Control','no-store');return res.status(201).json({success:true,data});}catch(e){return fail(res,e);}},
  async accept(req:TenantRequest,res:Response){const {error,value}=Joi.object({token:Joi.string().min(32).max(256).required()}).validate(req.body,{stripUnknown:true});if(error)return res.status(400).json({error:error.message});try{return res.json({success:true,data:await groupInvitationService.accept({...context(req),token:value.token,idempotencyKey:commandKey(req)})});}catch(e){return fail(res,e);}},
  async revoke(req:TenantRequest,res:Response){const {error,value}=Joi.object({reasonCode:Joi.string().uppercase().pattern(/^[A-Z][A-Z0-9_]{2,63}$/).required()}).validate(req.body,{stripUnknown:true});if(error)return res.status(400).json({error:error.message});try{return res.json({success:true,data:await groupInvitationService.revoke({...context(req),invitationId:req.params.invitationId,reasonCode:value.reasonCode,idempotencyKey:commandKey(req)})});}catch(e){return fail(res,e);}},
  async list(req:TenantRequest,res:Response){try{return res.json({success:true,data:await groupInvitationService.list(req.tenant!.id,req.params.id,req.user!.id)});}catch(e){return fail(res,e);}},
};
