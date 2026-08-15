import { randomUUID } from 'crypto';
import supabase from '../utils/supabase.js';
import { GroupTreasuryContext } from './groupTreasuryDisbursementService.js';
export class GroupProjectLifecycleService {
 async transition(name:string,c:GroupTreasuryContext,projectId:string,reason:string){const {data,error}=await supabase.rpc(name,{o:c.organizationId,g:c.groupId,a:c.actorId,project_id:projectId,reason,corr:randomUUID()});if(error)throw error;return{projectId:data};}
 pause(c:GroupTreasuryContext,p:string,r:string){return this.transition('pause_group_project',c,p,r);}
 resume(c:GroupTreasuryContext,p:string,r:string){return this.transition('resume_group_project',c,p,r);}
}
export default new GroupProjectLifecycleService();
