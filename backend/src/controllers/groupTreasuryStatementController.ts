import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import statementService from '../services/groupTreasuryStatementService.js';

export const groupTreasuryStatementController={
  async read(req:TenantRequest,res:Response) {
    try {
      const data=await statementService.read({
        organizationId:req.tenant!.id,groupId:req.params.id,actorId:req.user!.id,
      },{
        currency:typeof req.query.currency==='string'?req.query.currency:undefined,
        from:typeof req.query.from==='string'?req.query.from:undefined,
        to:typeof req.query.to==='string'?req.query.to:undefined,
        cutoff:typeof req.query.cutoff==='string'?req.query.cutoff:undefined,
        page:req.query.page?Number(req.query.page):undefined,
        limit:req.query.limit?Number(req.query.limit):undefined,
      });
      return res.json({success:true,data});
    } catch(error:any) {
      const message=String(error.message??'');
      const status=error.statusCode??(message.includes('NOT_AUTHORIZED')?403:message.includes('NOT_FOUND')?404:message.includes('INVALID')?400:500);
      return res.status(status).json({error:/^GROUP_[A-Z_]+$/.test(message)?message:'Group treasury statement failed.'});
    }
  },
};
