import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { AccountingReportValidationError } from '../domains/financial/accountingIncomeStatementService.js';
import { AccountingCashFlowService, accountingCashFlowService } from '../domains/financial/accountingCashFlowService.js';

export class AccountingCashFlowController {
  constructor(private readonly service:AccountingCashFlowService=accountingCashFlowService) {}
  cashFlow=async(req:TenantRequest,res:Response)=>{try{return res.json({cashFlow:await this.service.read({organizationId:req.tenant!.id,actorId:req.user!.id,currency:String(req.query.currency||'').toUpperCase(),from:String(req.query.from||''),to:String(req.query.to||''),cutoff:String(req.query.cutoff||'')})});}catch(error){if(error instanceof AccountingReportValidationError)return res.status(400).json({error:error.message});return res.status(409).json({error:'CASH_FLOW_UNAVAILABLE'});}}
}
export const accountingCashFlowController = new AccountingCashFlowController();
