import { randomUUID } from 'crypto';
import supabase from '../utils/supabase.js';
import { GroupTreasuryContext } from './groupTreasuryDisbursementService.js';
export interface GroupProjectInput { projectKey:string; title:string; purpose:string; ownerUserId:string; responsibleCommitteeId?:string|null; startsOn:string; endsOn:string; fundingSources:unknown[]; restrictedFundRules?:unknown[]; outcomeMeasures?:unknown[]; currency:string; totalMinor:number; budgetLines:unknown[]; milestones?:unknown[]; idempotencyKey:string; }
const correlation=()=>randomUUID();
export class GroupProjectService {
 async list(c:GroupTreasuryContext){const {data,error}=await supabase.from('group_projects').select('*').eq('organization_id',c.organizationId).eq('group_id',c.groupId).order('created_at',{ascending:false});if(error)throw error;return data??[];}
 async create(c:GroupTreasuryContext,i:GroupProjectInput){const {data,error}=await supabase.rpc('create_group_project',{o:c.organizationId,g:c.groupId,a:c.actorId,k:i.projectKey,t:i.title,purpose_text:i.purpose,owner_id:i.ownerUserId,committee_id:i.responsibleCommitteeId??null,start_date:i.startsOn,end_date:i.endsOn,sources:i.fundingSources,rules:i.restrictedFundRules??[],outcomes:i.outcomeMeasures??[],currency_code:i.currency,total:i.totalMinor,lines:i.budgetLines,milestones:i.milestones??[],idem:i.idempotencyKey,corr:correlation()});if(error)throw error;return{projectId:data,state:'draft'};}
 private async command(name:string,c:GroupTreasuryContext,p:string,q?:string){const {data,error}=await supabase.rpc(name,{o:c.organizationId,g:c.groupId,a:c.actorId,project_id:p,...(q?{proposal_id:q}:{}),corr:correlation()});if(error)throw error;return{projectId:data};}
 submit(c:GroupTreasuryContext,p:string,q:string){return this.command('submit_group_project',c,p,q);} approve(c:GroupTreasuryContext,p:string){return this.command('approve_group_project',c,p);} activate(c:GroupTreasuryContext,p:string){return this.command('activate_group_project',c,p);}
}
export default new GroupProjectService();
