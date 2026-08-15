import { randomUUID } from 'crypto';
import supabase from '../utils/supabase.js';
import { GroupTreasuryContext } from './groupTreasuryDisbursementService.js';
export interface ProjectCompletionInput { deliverables:unknown[]; residualFundDisposition:Record<string,unknown>; assetsCreatedOrAcquired:unknown[]; finalReconciliation:Record<string,unknown>; evidenceRefs:unknown[]; }
export class GroupProjectCompletionService {
 async complete(c:GroupTreasuryContext,p:string,i:ProjectCompletionInput){const {data,error}=await supabase.rpc('complete_group_project',{o:c.organizationId,g:c.groupId,a:c.actorId,project_id:p,deliverables:i.deliverables,residual:i.residualFundDisposition,assets:i.assetsCreatedOrAcquired,reconciliation:i.finalReconciliation,evidence:i.evidenceRefs,corr:randomUUID()});if(error)throw error;return{completionId:data,state:'completed'};}
}
export default new GroupProjectCompletionService();
