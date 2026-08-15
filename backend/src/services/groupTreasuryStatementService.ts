import supabase from '../utils/supabase.js';
import { GroupTreasuryContext } from './groupTreasuryDisbursementService.js';

const DATE=/^\d{4}-\d{2}-\d{2}$/;
export interface GroupTreasuryStatementQuery {
  currency?: string; from?: string; to?: string; cutoff?: string; page?: number; limit?: number;
}
export class GroupTreasuryStatementService {
  constructor(private readonly now=()=>new Date()) {}
  async read(context: GroupTreasuryContext,input: GroupTreasuryStatementQuery) {
    const now=this.now(); const today=now.toISOString().slice(0,10);
    const from=input.from ?? today.slice(0,7)+'-01'; const to=input.to ?? today;
    const cutoff=input.cutoff ?? now.toISOString(); const cutoffDate=new Date(cutoff);
    const currency=input.currency ?? 'NGN'; const page=input.page ?? 1; const limit=input.limit ?? 25;
    if(!DATE.test(from)||!DATE.test(to)||from>to||!/^[A-Z]{3}$/.test(currency)
      ||Number.isNaN(cutoffDate.getTime())||cutoffDate>now||!Number.isSafeInteger(page)
      ||page<1||!Number.isSafeInteger(limit)||limit<1||limit>100) {
      throw Object.assign(new Error('GROUP_TREASURY_STATEMENT_INVALID'),{statusCode:400});
    }
    const {data,error}=await supabase.rpc('read_group_treasury_statement',{
      p_organization_id:context.organizationId,p_group_id:context.groupId,
      p_actor_id:context.actorId,p_currency:currency,p_from:from,p_to:to,
      p_cutoff:cutoffDate.toISOString(),p_offset:(page-1)*limit,p_limit:limit,
    });
    if(error) throw error;
    return {...data,pagination:{page,limit,total:data.total,totalPages:Math.ceil(data.total/limit)}};
  }
}
export default new GroupTreasuryStatementService();
