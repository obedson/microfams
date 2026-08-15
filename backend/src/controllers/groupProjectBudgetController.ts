import Joi from 'joi';
import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import budgetService from '../services/groupProjectBudgetService.js';
const context=(r:TenantRequest)=>({organizationId:r.tenant!.id,groupId:r.params.id,actorId:r.user!.id});
const uuid=(v:unknown,code:string)=>{const x=Joi.string().uuid().validate(v);if(x.error)throw Object.assign(new Error(code),{statusCode:400});return x.value;};
const fail=(s:Response,e:any)=>s.status(e.statusCode||((e.message??'').includes('PERMISSION')?403:409)).json({error:/^GROUP_[A-Z_]+$/.test(e.message??'')?e.message:'Group project budget command failed.'});
const schema=Joi.object({proposalId:Joi.string().uuid().required(),currency:Joi.string().pattern(/^[A-Z]{3}$/).required(),totalMinor:Joi.number().integer().min(0).required(),budgetLines:Joi.array().min(1).required()});
export const groupProjectBudgetController={
 async propose(r:TenantRequest,s:Response){try{const v=schema.validate(r.body,{abortEarly:false,stripUnknown:true});if(v.error)throw Object.assign(new Error(v.error.message),{statusCode:400});return s.status(201).json({success:true,data:await budgetService.propose(context(r),uuid(r.params.projectId,'GROUP_PROJECT_ID_INVALID'),v.value)});}catch(e){return fail(s,e);}},
 async approve(r:TenantRequest,s:Response){try{return s.json({success:true,data:await budgetService.approve(context(r),uuid(r.params.projectId,'GROUP_PROJECT_ID_INVALID'),uuid(r.params.budgetVersionId,'GROUP_PROJECT_BUDGET_ID_INVALID'))});}catch(e){return fail(s,e);}},
};
