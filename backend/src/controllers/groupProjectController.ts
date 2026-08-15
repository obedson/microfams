import Joi from 'joi';
import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import projectService from '../services/groupProjectService.js';
const context=(r:TenantRequest)=>({organizationId:r.tenant!.id,groupId:r.params.id,actorId:r.user!.id});
const pid=(r:TenantRequest)=>{const v=Joi.string().uuid().validate(r.params.projectId);if(v.error)throw Object.assign(new Error('GROUP_PROJECT_ID_INVALID'),{statusCode:400});return r.params.projectId;};
const fail=(s:Response,e:any)=>s.status(e.statusCode||((e.message??'').includes('PERMISSION')?403:409)).json({error:/^GROUP_[A-Z_]+$/.test(e.message??'')?e.message:'Group project command failed.'});
const schema=Joi.object({projectKey:Joi.string().pattern(/^[a-z][a-z0-9_]{2,63}$/).required(),title:Joi.string().min(3).max(200).required(),purpose:Joi.string().min(10).max(5000).required(),ownerUserId:Joi.string().uuid().required(),responsibleCommitteeId:Joi.string().uuid().allow(null),startsOn:Joi.date().iso().required(),endsOn:Joi.date().iso().required(),fundingSources:Joi.array().required(),restrictedFundRules:Joi.array().default([]),outcomeMeasures:Joi.array().default([]),currency:Joi.string().pattern(/^[A-Z]{3}$/).required(),totalMinor:Joi.number().integer().min(0).required(),budgetLines:Joi.array().min(1).required(),milestones:Joi.array().default([]),idempotencyKey:Joi.string().min(8).max(128).required()});
const body=(r:TenantRequest)=>{const v=schema.validate(r.body,{abortEarly:false,stripUnknown:true});if(v.error)throw Object.assign(new Error(v.error.message),{statusCode:400});return v.value;};
export const groupProjectController={
 async list(r:TenantRequest,s:Response){try{return s.json({success:true,data:await projectService.list(context(r))});}catch(e){return fail(s,e);}},
 async create(r:TenantRequest,s:Response){try{return s.status(201).json({success:true,data:await projectService.create(context(r),body(r))});}catch(e){return fail(s,e);}},
 async submit(r:TenantRequest,s:Response){try{const q=Joi.string().uuid().validate(r.body?.proposalId).value;if(!q)throw Object.assign(new Error('GROUP_PROJECT_PROPOSAL_REQUIRED'),{statusCode:400});return s.json({success:true,data:await projectService.submit(context(r),pid(r),q)});}catch(e){return fail(s,e);}},
 async approve(r:TenantRequest,s:Response){try{return s.json({success:true,data:await projectService.approve(context(r),pid(r))});}catch(e){return fail(s,e);}},
 async activate(r:TenantRequest,s:Response){try{return s.json({success:true,data:await projectService.activate(context(r),pid(r))});}catch(e){return fail(s,e);}},
};
