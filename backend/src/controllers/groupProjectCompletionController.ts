import Joi from 'joi';
import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import completionService from '../services/groupProjectCompletionService.js';
const context=(r:TenantRequest)=>({organizationId:r.tenant!.id,groupId:r.params.id,actorId:r.user!.id});
const fail=(s:Response,e:any)=>s.status(e.statusCode||((e.message??'').includes('PERMISSION')?403:409)).json({error:/^GROUP_[A-Z_]+$/.test(e.message??'')?e.message:'Group project completion failed.'});
const schema=Joi.object({deliverables:Joi.array().min(1).required(),residualFundDisposition:Joi.object().required(),assetsCreatedOrAcquired:Joi.array().required(),finalReconciliation:Joi.object().required(),evidenceRefs:Joi.array().min(1).required()});
export const groupProjectCompletionController={async complete(r:TenantRequest,s:Response){try{const p=Joi.string().uuid().validate(r.params.projectId);const v=schema.validate(r.body,{abortEarly:false,stripUnknown:true});if(p.error||v.error)throw Object.assign(new Error('GROUP_PROJECT_COMPLETION_INPUT_INVALID'),{statusCode:400});return s.json({success:true,data:await completionService.complete(context(r),p.value,v.value)});}catch(e){return fail(s,e);}}};
