import { Response } from 'express';
import { GroupDocumentAccessError,GroupDocumentAccessService,groupDocumentAccessService } from '../domains/groups/groupDocumentAccessService.js';
import { TenantRequest } from '../middleware/tenant.js';
export class GroupDocumentAccessController {
 constructor(private readonly service:GroupDocumentAccessService=groupDocumentAccessService){}
 issue=async(req:TenantRequest,res:Response)=>{try{const result=await this.service.issue({organizationId:req.tenant!.id,groupId:req.params.groupId,actorId:req.user!.id,versionId:req.params.versionId});res.setHeader('Cache-Control','no-store');return res.json({success:true,...result});}catch(error){if(error instanceof GroupDocumentAccessError)return res.status(error.status).json({success:false,error:error.code});return res.status(503).json({success:false,error:'GROUP_DOCUMENT_ACCESS_UNAVAILABLE'});}};
}
export const groupDocumentAccessController=new GroupDocumentAccessController();
