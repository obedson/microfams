import { randomUUID } from 'crypto';
import supabase from '../utils/supabase.js';
import { GroupTreasuryContext } from './groupTreasuryDisbursementService.js';
export class GroupProjectCloseoutService {
 async close(c:GroupTreasuryContext,p:string,proposalId:string,reason:string){const {data,error}=await supabase.rpc('close_group_project',{o:c.organizationId,g:c.groupId,a:c.actorId,project_id:p,proposal_id:proposalId,reason,corr:randomUUID()});if(error)throw error;return{projectId:data,state:'closed'};}
}
export default new GroupProjectCloseoutService();
