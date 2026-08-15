import Joi from 'joi';
import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import closeoutService from '../services/groupProjectCloseoutService.js';
const context=(r:TenantRequest)=>({organizationId:r.tenant!.id,groupId:r.params.id,actorId:r.user!.id});
const fail=(s:Response,e:any)=>s.status(e.statusCode||((e.message??'').includes('PERMISSION')?403:409)).json({error:/^GROUP_[A-Z_]+$/.test(e.message??'')?e.message:'Group project closeout failed.'});
const schema=Joi.object({proposalId:Joi.string().uuid().required(),reason:Joi.string().trim().min(3).max(2000).required()});
export const groupProjectCloseoutController={async close(r:TenantRequest,s:Response){try{const p=Joi.string().uuid().validate(r.params.projectId);const v=schema.validate(r.body,{abortEarly:false,stripUnknown:true});if(p.error||v.error)throw Object.assign(new Error('GROUP_PROJECT_CLOSEOUT_INPUT_INVALID'),{statusCode:400});return s.json({success:true,data:await closeoutService.close(context(r),p.value,v.value.proposalId,v.value.reason)});}catch(e){return fail(s,e);}}};
