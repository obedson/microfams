import { randomBytes } from 'crypto';
import supabase from '../utils/supabase.js';
import { invitationCorrelationId, invitationTokenDigest } from '../domains/groups/invitationRules.js';

export class GroupInvitationService {
  async create(input: { organizationId:string; groupId:string; actorId:string;
    intendedUserId:string; expiresAt:string; idempotencyKey:string }) {
    const token = randomBytes(32).toString('base64url');
    const { data, error } = await supabase.rpc('create_group_membership_invitation', {
      p_organization_id:input.organizationId,p_group_id:input.groupId,
      p_actor_id:input.actorId,p_intended_user_id:input.intendedUserId,
      p_token_digest:invitationTokenDigest(token),p_expires_at:input.expiresAt,
      p_correlation_id:invitationCorrelationId(`${input.organizationId}:invite:${input.idempotencyKey}`),
    });
    if (error) throw error;
    const result=data as {invitation_id:string;created:boolean};
    return { invitationId:result.invitation_id, token:result.created?token:null, tokenAvailable:result.created };
  }
  async accept(input:{organizationId:string;groupId:string;actorId:string;token:string;idempotencyKey:string}) {
    const { data,error }=await supabase.rpc('accept_group_membership_invitation',{
      p_organization_id:input.organizationId,p_group_id:input.groupId,p_actor_id:input.actorId,
      p_token_digest:invitationTokenDigest(input.token),
      p_correlation_id:invitationCorrelationId(`${input.organizationId}:accept:${input.idempotencyKey}`),
    });
    if(error) throw error;
    return { membershipId:data };
  }
  async revoke(input:{organizationId:string;groupId:string;actorId:string;invitationId:string;reasonCode:string;idempotencyKey:string}) {
    const {data,error}=await supabase.rpc('revoke_group_membership_invitation',{
      p_organization_id:input.organizationId,p_group_id:input.groupId,p_actor_id:input.actorId,
      p_invitation_id:input.invitationId,p_reason_code:input.reasonCode,
      p_correlation_id:invitationCorrelationId(`${input.organizationId}:revoke:${input.idempotencyKey}`),
    });
    if(error) throw error;
    return {invitationId:data};
  }
  async list(organizationId:string,groupId:string,actorId:string) {
    const [tenantResult,groupResult,memberResult]=await Promise.all([
      supabase.from('organization_memberships').select('role, permissions').eq('organization_id',organizationId).eq('user_id',actorId).eq('status','active').maybeSingle(),
      supabase.from('groups').select('creator_id').eq('organization_id',organizationId).eq('id',groupId).maybeSingle(),
      supabase.from('group_members').select('role').eq('organization_id',organizationId).eq('group_id',groupId).eq('user_id',actorId).eq('status','active').maybeSingle(),
    ]);
    const lookupError=tenantResult.error??groupResult.error??memberResult.error;if(lookupError)throw lookupError;
    const tenant=tenantResult.data;const group=groupResult.data;const member=memberResult.data;
    if(!group)return [];
    if(!(tenant?.role==='owner'||tenant?.permissions?.includes('groups.membership.manage'))||!(tenant?.role==='owner'||group.creator_id===actorId||member?.role==='owner'))throw new Error('GROUP_MEMBERSHIP_PERMISSION_DENIED');
    const {data,error}=await supabase.from('group_membership_invitations')
      .select('id, intended_user_id, state, expires_at, invited_by, accepted_at, revoked_at, created_at')
      .eq('organization_id',organizationId).eq('group_id',groupId).order('created_at',{ascending:false});
    if(error) throw error;
    return data;
  }
}
export const groupInvitationService=new GroupInvitationService();
