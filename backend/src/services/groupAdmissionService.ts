import { createHash } from 'crypto';
import { paymentService } from '../domains/financial/paymentService.js';
import supabase from '../utils/supabase.js';

export interface GroupAdmissionContext { organizationId: string; groupId: string; actorId: string }
const uuid = (value: string) => {
  const digest = createHash('sha256').update(value).digest('hex');
  return `${digest.slice(0,8)}-${digest.slice(8,12)}-4${digest.slice(13,16)}-a${digest.slice(17,20)}-${digest.slice(20,32)}`;
};
const commandId = (c: GroupAdmissionContext, command: string, key: string) => uuid(`${c.organizationId}:${c.groupId}:${c.actorId}:${command}:${key}`);

export class GroupAdmissionService {
  async adoptInitialRequirements(context: GroupAdmissionContext,input:{entryFeeAmountMinor:number;currency:string;requiredIdentityTier:'none'|'nin_verified';eligibilityRules:Record<string,unknown>;idempotencyKey:string}) {
    const {data,error}=await supabase.rpc('adopt_initial_group_entry_requirements',{p_organization_id:context.organizationId,p_group_id:context.groupId,p_actor_id:context.actorId,p_entry_fee_amount_minor:input.entryFeeAmountMinor,p_currency:input.currency,p_required_identity_tier:input.requiredIdentityTier,p_eligibility_rules:input.eligibilityRules,p_correlation_id:commandId(context,'entry-requirements:initial',input.idempotencyKey)});
    if(error) throw error;return {entryRequirementVersionId:data};
  }

  async executeAdmission(context:GroupAdmissionContext,memberId:string,input:{proposalId:string;expectedMembershipVersion:number;idempotencyKey:string}) {
    const {data,error}=await supabase.rpc('execute_group_membership_admission',{p_organization_id:context.organizationId,p_group_id:context.groupId,p_actor_id:context.actorId,p_membership_id:memberId,p_proposal_id:input.proposalId,p_expected_membership_version:input.expectedMembershipVersion,p_correlation_id:commandId(context,`membership:${memberId}:admit`,input.idempotencyKey)});
    if(error) throw error;return this.publicMembership(data);
  }

  async initializeEntryPayment(context:GroupAdmissionContext,memberId:string,email:string,idempotencyKey:string) {
    const {data:member,error}=await supabase.from('group_members').select('id,user_id,status,payment_status,entry_requirement_version_id').eq('id',memberId).eq('organization_id',context.organizationId).eq('group_id',context.groupId).maybeSingle();
    if(error) throw error;if(!member||member.user_id!==context.actorId) return null;
    if(!(member.status==='pending_payment'||(member.status==='active'&&member.payment_status==='failed'))) throw new Error('GROUP_MEMBERSHIP_PAYMENT_NOT_DUE');
    const {data:rule,error:ruleError}=await supabase.from('group_entry_requirement_versions').select('entry_fee_amount_minor,currency,required_identity_tier').eq('id',member.entry_requirement_version_id).eq('organization_id',context.organizationId).eq('group_id',context.groupId).maybeSingle();
    if(ruleError) throw ruleError;if(!rule||Number(rule.entry_fee_amount_minor)<=0) throw new Error('GROUP_MEMBERSHIP_PAYMENT_NOT_DUE');
    const reference=`MEM-${member.id.slice(0,8)}-${createHash('sha256').update(idempotencyKey).digest('hex').slice(0,16)}`;
    return paymentService.createAndInitialize({organizationId:context.organizationId,sourceType:'group_membership',sourceId:member.id,payerId:context.actorId,actorId:context.actorId,correlationId:commandId(context,`membership:${memberId}:payment`,idempotencyKey),internalReference:reference,idempotencyKey:`group-membership:${idempotencyKey}`,amountMinor:Number(rule.entry_fee_amount_minor),customerEmail:email,callbackUrl:`${process.env.FRONTEND_URL||'http://localhost:3000'}/payment?type=group&id=${member.id}&groupId=${context.groupId}`,metadata:{group_id:context.groupId,membership_id:member.id,entry_requirement_version_id:member.entry_requirement_version_id}});
  }

  private async access(context:GroupAdmissionContext,memberUserId?:string){
    if(memberUserId===context.actorId) return true;
    const {data}=await supabase.from('organization_memberships').select('role,permissions').eq('organization_id',context.organizationId).eq('user_id',context.actorId).eq('status','active').maybeSingle();
    return data?.role==='owner'||(data?.permissions??[]).some((p:string)=>['groups.membership.manage','groups.governance.manage','groups.audit.read'].includes(p));
  }

  async getStatus(context:GroupAdmissionContext,memberId:string){
    const {data:member,error}=await supabase.from('group_members').select('id,user_id,status,state_version,payment_status,payment_reference,amount_paid,paid_at,entry_requirement_version_id,admission_proposal_id,admission_decided_at,status_reason_code').eq('id',memberId).eq('organization_id',context.organizationId).eq('group_id',context.groupId).maybeSingle();
    if(error) throw error;if(!member||!await this.access(context,member.user_id)) return null;
    const [ruleResult,paymentResult]=await Promise.all([supabase.from('group_entry_requirement_versions').select('id,version,entry_fee_amount_minor,currency,required_identity_tier,approval_route,capacity_limit,effective_from').eq('id',member.entry_requirement_version_id).maybeSingle(),supabase.from('payments').select('id,internal_reference,state,amount_minor,currency,created_at,terminal_at').eq('organization_id',context.organizationId).eq('source_type','group_membership').eq('source_id',member.id).order('created_at',{ascending:false}).limit(10)]);
    if(ruleResult.error) throw ruleResult.error;if(paymentResult.error) throw paymentResult.error;
    return {membership:this.publicMembership(member),entryRequirement:ruleResult.data,payments:paymentResult.data??[]};
  }

  async getCurrentRequirements(context:GroupAdmissionContext){
    const {data:group,error}=await supabase.from('groups').select('id,creator_id').eq('id',context.groupId).eq('organization_id',context.organizationId).maybeSingle();if(error) throw error;if(!group) return null;
    const {data:membership}=await supabase.from('group_members').select('id').eq('organization_id',context.organizationId).eq('group_id',context.groupId).eq('user_id',context.actorId).eq('status','active').maybeSingle();
    if(!membership&&!await this.access(context)) return null;
    const {data,error:ruleError}=await supabase.from('group_entry_requirement_versions').select('id,version,entry_fee_amount_minor,currency,required_identity_tier,eligibility_rules,approval_route,capacity_limit,effective_from').eq('organization_id',context.organizationId).eq('group_id',context.groupId).eq('state','effective').maybeSingle();if(ruleError) throw ruleError;return data;
  }

  private publicMembership(row:any){return {id:row.id,userId:row.user_id,status:row.status,stateVersion:row.state_version,paymentStatus:row.payment_status,paymentReference:row.payment_reference,amountPaid:row.amount_paid,paidAt:row.paid_at,entryRequirementVersionId:row.entry_requirement_version_id,admissionProposalId:row.admission_proposal_id,admissionDecidedAt:row.admission_decided_at,statusReasonCode:row.status_reason_code};}
}
export const groupAdmissionService=new GroupAdmissionService();
