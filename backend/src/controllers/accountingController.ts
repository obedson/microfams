import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { AccountingIncomeStatementService, AccountingReportValidationError, accountingIncomeStatementService } from '../domains/financial/accountingIncomeStatementService.js';
export class AccountingController {
  constructor(private readonly service:AccountingIncomeStatementService=accountingIncomeStatementService) {}
  incomeStatement=async(req:TenantRequest,res:Response)=>{ try { const result=await this.service.read({ organizationId:req.tenant!.id, actorId:req.user!.id, currency:String(req.query.currency||'').toUpperCase(), from:String(req.query.from||''), to:String(req.query.to||''), cutoff:String(req.query.cutoff||'') }); return res.json({ incomeStatement:result }); } catch(error) { if(error instanceof AccountingReportValidationError) return res.status(400).json({error:error.message}); return res.status(409).json({error:'INCOME_STATEMENT_UNAVAILABLE'}); } };
}
export const accountingController=new AccountingController();
