import Joi from 'joi';
import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import lifecycle from '../services/groupProjectLifecycleService.js';
const context=(r:TenantRequest)=>({organizationId:r.tenant!.id,groupId:r.params.id,actorId:r.user!.id});
const fail=(s:Response,e:any)=>s.status(e.statusCode||((e.message??'').includes('PERMISSION')?403:409)).json({error:/^GROUP_[A-Z_]+$/.test(e.message??'')?e.message:'Group project lifecycle command failed.'});
const run=async(r:TenantRequest,s:Response,action:(p:string,reason:string)=>Promise<unknown>)=>{try{const p=Joi.string().uuid().validate(r.params.projectId);const reason=Joi.string().trim().min(3).max(2000).validate(r.body?.reason);if(p.error||reason.error)throw Object.assign(new Error('GROUP_PROJECT_LIFECYCLE_INPUT_INVALID'),{statusCode:400});return s.json({success:true,data:await action(p.value,reason.value)});}catch(e){return fail(s,e);}};
export const groupProjectLifecycleController={
 pause:(r:TenantRequest,s:Response)=>run(r,s,(p,q)=>lifecycle.pause(context(r),p,q)),
 resume:(r:TenantRequest,s:Response)=>run(r,s,(p,q)=>lifecycle.resume(context(r),p,q)),
};
