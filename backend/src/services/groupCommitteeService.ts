import { createHash } from 'crypto';
import supabase from '../utils/supabase.js';
import {
  GroupAttendanceStatus,
  GroupCommitteeRole,
  GroupMeetingType,
  normalizeCommitteePermissions,
  normalizeSpendingCeiling,
} from '../domains/groups/committeeRules.js';

export interface GroupCommitteeContext {
  organizationId: string;
  groupId: string;
  actorId: string;
}

const correlationId = (context: GroupCommitteeContext, command: string, key: string) => {
  const digest = createHash('sha256')
    .update(`${context.organizationId}:${context.groupId}:${context.actorId}:${command}:${key}`)
    .digest('hex');
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-4${digest.slice(13, 16)}-a${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
};

export class GroupCommitteeService {
  async createCommittee(
    context: GroupCommitteeContext,
    input: {
      committeeKey: string;
      displayName: string;
      mandate: string;
      delegatedPermissions?: unknown;
      spendingCeilingMinorUnits?: number | null;
      spendingCeilingCurrency?: string | null;
      reportingDuties?: string | null;
      termEndsAt?: string | null;
      idempotencyKey: string;
    },
  ) {
    const ceiling = normalizeSpendingCeiling(
      input.spendingCeilingMinorUnits, input.spendingCeilingCurrency,
    );
    const { data, error } = await supabase.rpc('create_group_committee', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_committee_key: input.committeeKey,
      p_display_name: input.displayName,
      p_mandate: input.mandate,
      p_delegated_permissions: normalizeCommitteePermissions(input.delegatedPermissions),
      p_spending_ceiling_minor_units: ceiling.minorUnits,
      p_spending_ceiling_currency: ceiling.currency,
      p_reporting_duties: input.reportingDuties ?? null,
      p_term_ends_at: input.termEndsAt ?? null,
      p_correlation_id: correlationId(
        context, `committee:${input.committeeKey}`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { committeeId: data };
  }

  async addMember(
    context: GroupCommitteeContext,
    input: {
      committeeId: string;
      memberId: string;
      committeeRole: GroupCommitteeRole;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('add_group_committee_member', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_committee_id: input.committeeId,
      p_member_id: input.memberId,
      p_committee_role: input.committeeRole,
      p_correlation_id: correlationId(
        context, `committee:${input.committeeId}:add-member`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { membershipId: data };
  }

  async endMembership(
    context: GroupCommitteeContext,
    input: { membershipId: string; reasonCode: string; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('end_group_committee_membership', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_membership_id: input.membershipId,
      p_reason_code: input.reasonCode,
      p_correlation_id: correlationId(
        context, `committee-membership:${input.membershipId}:end`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { membershipId: data };
  }

  async dissolveCommittee(
    context: GroupCommitteeContext,
    input: { committeeId: string; reasonCode: string; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('dissolve_group_committee', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_committee_id: input.committeeId,
      p_reason_code: input.reasonCode,
      p_correlation_id: correlationId(
        context, `committee:${input.committeeId}:dissolve`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { committeeId: data };
  }

  async scheduleMeeting(
    context: GroupCommitteeContext,
    input: {
      meetingType: GroupMeetingType;
      committeeId?: string | null;
      title: string;
      agenda?: unknown[];
      scheduledAt: string;
      requiredNoticeHours: number;
      emergencyReason?: string | null;
      location?: string | null;
      quorumNumerator: number;
      quorumDenominator: number;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('schedule_group_meeting', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_meeting_type: input.meetingType,
      p_committee_id: input.committeeId ?? null,
      p_title: input.title,
      p_agenda: input.agenda ?? [],
      p_scheduled_at: input.scheduledAt,
      p_required_notice_hours: input.requiredNoticeHours,
      p_emergency_reason: input.emergencyReason ?? null,
      p_location: input.location ?? null,
      p_quorum_numerator: input.quorumNumerator,
      p_quorum_denominator: input.quorumDenominator,
      p_correlation_id: correlationId(context, 'meeting:schedule', input.idempotencyKey),
    });
    if (error) throw error;
    return { meetingId: data };
  }

  async recordAttendance(
    context: GroupCommitteeContext,
    input: {
      meetingId: string;
      memberId: string;
      attendanceStatus: GroupAttendanceStatus;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('record_group_meeting_attendance', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_meeting_id: input.meetingId,
      p_member_id: input.memberId,
      p_attendance_status: input.attendanceStatus,
      p_correlation_id: correlationId(
        context, `meeting:${input.meetingId}:attendance:${input.memberId}`,
        input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { attendanceId: data };
  }

  async holdMeeting(
    context: GroupCommitteeContext,
    input: { meetingId: string; expectedVersion: number; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('hold_group_meeting', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_meeting_id: input.meetingId,
      p_expected_version: input.expectedVersion,
      p_correlation_id: correlationId(
        context, `meeting:${input.meetingId}:hold`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return data;
  }

  async cancelMeeting(
    context: GroupCommitteeContext,
    input: {
      meetingId: string; expectedVersion: number; reasonCode: string;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('cancel_group_meeting', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_meeting_id: input.meetingId,
      p_expected_version: input.expectedVersion,
      p_reason_code: input.reasonCode,
      p_correlation_id: correlationId(
        context, `meeting:${input.meetingId}:cancel`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { meetingId: data };
  }

  async draftMinutes(
    context: GroupCommitteeContext,
    input: {
      meetingId: string;
      content: string;
      resolutions?: unknown[];
      correctsMinutesId?: string | null;
      idempotencyKey: string;
    },
  ) {
    const { data, error } = await supabase.rpc('draft_group_meeting_minutes', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_meeting_id: input.meetingId,
      p_content: input.content,
      p_resolutions: input.resolutions ?? [],
      p_corrects_minutes_id: input.correctsMinutesId ?? null,
      p_correlation_id: correlationId(
        context, `meeting:${input.meetingId}:minutes-draft`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { minutesId: data };
  }

  async approveMinutes(
    context: GroupCommitteeContext,
    input: { minutesId: string; idempotencyKey: string },
  ) {
    const { data, error } = await supabase.rpc('approve_group_meeting_minutes', {
      p_organization_id: context.organizationId,
      p_group_id: context.groupId,
      p_actor_id: context.actorId,
      p_minutes_id: input.minutesId,
      p_correlation_id: correlationId(
        context, `minutes:${input.minutesId}:approve`, input.idempotencyKey,
      ),
    });
    if (error) throw error;
    return { minutesId: data };
  }

  async getCommitteeOverview(context: GroupCommitteeContext) {
    const [committeesResult, membersResult] = await Promise.all([
      supabase.from('group_committees').select(
        'id,committee_key,display_name,mandate,delegated_permissions,'
        + 'spending_ceiling_minor_units,spending_ceiling_currency,reporting_duties,'
        + 'term_starts_at,term_ends_at,state,dissolved_at,dissolution_reason_code,created_at',
      ).eq('organization_id', context.organizationId).eq('group_id', context.groupId)
        .order('created_at', { ascending: false }).limit(200),
      supabase.from('group_committee_members').select(
        'id,committee_id,member_id,user_id,committee_role,starts_at,ends_at,end_reason_code',
      ).eq('organization_id', context.organizationId).eq('group_id', context.groupId)
        .order('starts_at', { ascending: false }).limit(500),
    ]);
    const error = committeesResult.error ?? membersResult.error;
    if (error) throw error;
    const members = membersResult.data ?? [];
    return {
      committees: (committeesResult.data ?? []).map((committee: any) => ({
        ...committee,
        currentMembers: members.filter(
          (member: any) => member.committee_id === committee.id && member.ends_at === null,
        ),
      })),
      membershipHistory: members,
    };
  }

  async getMeetingRecord(context: GroupCommitteeContext, meetingId: string) {
    const { data: meeting, error: meetingError } = await supabase
      .from('group_meetings').select(
        'id,committee_id,meeting_type,title,agenda,scheduled_at,notice_issued_at,'
        + 'required_notice_hours,emergency_reason,location,quorum_numerator,'
        + 'quorum_denominator,eligible_attendee_count,state,quorum_met,held_at,'
        + 'cancelled_at,cancellation_reason_code,state_version,created_at',
      ).eq('organization_id', context.organizationId).eq('group_id', context.groupId)
      .eq('id', meetingId).maybeSingle();
    if (meetingError) throw meetingError;
    if (!meeting) return null;
    const [attendanceResult, minutesResult] = await Promise.all([
      supabase.from('group_meeting_attendance').select(
        'id,member_id,user_id,attendance_status,recorded_at',
      ).eq('organization_id', context.organizationId).eq('meeting_id', meetingId).limit(500),
      supabase.from('group_meeting_minutes').select(
        'id,version,minutes_kind,corrects_minutes_id,content,resolutions,state,'
        + 'approved_by,approved_at,created_by,created_at',
      ).eq('organization_id', context.organizationId).eq('meeting_id', meetingId)
        .order('version', { ascending: false }).limit(100),
    ]);
    const error = attendanceResult.error ?? minutesResult.error;
    if (error) throw error;
    return {
      meeting,
      attendance: attendanceResult.data ?? [],
      minutes: minutesResult.data ?? [],
    };
  }
}

export const groupCommitteeService = new GroupCommitteeService();
