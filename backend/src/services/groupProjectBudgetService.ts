import { randomUUID } from 'crypto';
import supabase from '../utils/supabase.js';
import { GroupTreasuryContext } from './groupTreasuryDisbursementService.js';
export interface ProjectBudgetAmendmentInput { proposalId:string; currency:string; totalMinor:number; budgetLines:unknown[]; }
export class GroupProjectBudgetService {
 async propose(c:GroupTreasuryContext,projectId:string,i:ProjectBudgetAmendmentInput){const {data,error}=await supabase.rpc('create_group_project_budget_amendment',{o:c.organizationId,g:c.groupId,a:c.actorId,project_id:projectId,proposal_id:i.proposalId,currency_code:i.currency,total:i.totalMinor,lines:i.budgetLines,corr:randomUUID()});if(error)throw error;return{budgetVersionId:data,state:'draft'};}
 async approve(c:GroupTreasuryContext,projectId:string,budgetId:string){const {data,error}=await supabase.rpc('approve_group_project_budget_amendment',{o:c.organizationId,g:c.groupId,a:c.actorId,project_id:projectId,budget_id:budgetId,corr:randomUUID()});if(error)throw error;return{budgetVersionId:data,state:'approved'};}
}
export default new GroupProjectBudgetService();
