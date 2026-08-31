import { randomBytes } from 'node:crypto';
import { supabase } from '../utils/supabase.js';
import { OrganizationRole } from '../types/tenant.js';
import {
  organizationInvitationCorrelationId,
  organizationInvitationTokenDigest,
} from '../domains/organizations/organizationInvitationRules.js';

interface CreateInvitationInput {
  organizationId: string;
  actorId: string;
  email: string;
  role: OrganizationRole;
  permissions: string[];
  expiresAt: string;
  idempotencyKey: string;
}

interface InvitationCommandResult {
  invitation_id: string;
  created: boolean;
}

export class OrganizationInvitationService {
  async create(input: CreateInvitationInput) {
    const token = randomBytes(32).toString('base64url');
    const correlationId = organizationInvitationCorrelationId(
      `${input.organizationId}:organization-invitation:${input.idempotencyKey}`,
    );
    const { data, error } = await supabase.rpc(
      'create_organization_membership_invitation',
      {
        p_organization_id: input.organizationId,
        p_actor_id: input.actorId,
        p_email: input.email,
        p_role: input.role,
        p_permissions: input.permissions,
        p_token_hash: organizationInvitationTokenDigest(token),
        p_expires_at: input.expiresAt,
        p_correlation_id: correlationId,
      },
    );
    if (error) throw error;

    const result = data as InvitationCommandResult;
    return {
      invitationId: result.invitation_id,
      token: result.created ? token : null,
      tokenAvailable: result.created,
    };
  }

  async accept(actorId: string, token: string) {
    const { data, error } = await supabase.rpc(
      'accept_organization_membership_invitation',
      {
        p_actor_id: actorId,
        p_token_hash: organizationInvitationTokenDigest(token),
      },
    );
    if (error) throw error;
    const result = data as {
      organization_id: string;
      membership_id: string;
      accepted: boolean;
    };
    return {
      organizationId: result.organization_id,
      membershipId: result.membership_id,
      accepted: result.accepted,
    };
  }

  async revoke(organizationId: string, actorId: string, invitationId: string) {
    const { data, error } = await supabase.rpc(
      'revoke_organization_membership_invitation',
      {
        p_organization_id: organizationId,
        p_actor_id: actorId,
        p_invitation_id: invitationId,
      },
    );
    if (error) throw error;
    return { invitationId: data as string };
  }

  async list(organizationId: string) {
    const { data, error } = await supabase
      .from('organization_invitations')
      .select('id, email, role, permissions, status, invited_by, expires_at, accepted_at, revoked_at, created_at')
      .eq('organization_id', organizationId)
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data;
  }
}

export const organizationInvitationService = new OrganizationInvitationService();
