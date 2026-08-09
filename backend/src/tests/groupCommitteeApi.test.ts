import { jest } from '@jest/globals';
import { groupCommitteeController } from '../controllers/groupCommitteeController.js';
import { groupCommitteeService } from '../services/groupCommitteeService.js';

jest.mock('../services/groupCommitteeService.js', () => ({
  groupCommitteeService: {
    executeCommitteeProposal: jest.fn(),
    addMember: jest.fn(),
    endMembership: jest.fn(),
    scheduleMeeting: jest.fn(),
    recordAttendance: jest.fn(),
    holdMeeting: jest.fn(),
    cancelMeeting: jest.fn(),
    draftMinutes: jest.fn(),
    approveMinutes: jest.fn(),
    getCommitteeOverview: jest.fn(),
    getMeetingRecord: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const organizationId = '00000000-0000-4000-8000-000000000301';
const groupId = '00000000-0000-4000-8000-000000000302';
const actorId = '00000000-0000-4000-8000-000000000303';
const memberId = '00000000-0000-4000-8000-000000000304';
const committeeId = '00000000-0000-4000-8000-000000000305';
const meetingId = '00000000-0000-4000-8000-000000000306';
const minutesId = '00000000-0000-4000-8000-000000000307';

const request = (overrides: Record<string, unknown> = {}) => ({
  tenant: { id: organizationId },
  user: { id: actorId },
  params: { id: groupId },
  body: {},
  header: (name: string) => name === 'Idempotency-Key' ? 'committee-command-001' : undefined,
  ...overrides,
});

describe('group committee and meeting API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('executes an approved committee mandate proposal in resolved tenant context', async () => {
    (groupCommitteeService.executeCommitteeProposal as jest.Mock)
      .mockResolvedValue({ id: committeeId, state: 'executed' } as never);
    const res = response();
    await groupCommitteeController.executeCommitteeProposal(request({
      params: { id: groupId, proposalId: committeeId },
      body: { expectedVersion: 3, organizationId: 'attacker', actorId: 'attacker' },
    }) as any, res);
    expect(groupCommitteeService.executeCommitteeProposal).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, committeeId,
      { expectedVersion: 3, idempotencyKey: 'committee-command-001' },
    );
  });

  it('maps a stale committee proposal version to 409', async () => {
    (groupCommitteeService.executeCommitteeProposal as jest.Mock)
      .mockRejectedValue(new Error('GROUP_PROPOSAL_VERSION_CONFLICT') as never);
    const res = response();
    await groupCommitteeController.executeCommitteeProposal(request({
      params: { id: groupId, proposalId: committeeId },
      body: { expectedVersion: 2 },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
  });

  it('requires idempotency before a committee proposal execution reaches persistence', async () => {
    const res = response();
    await groupCommitteeController.executeCommitteeProposal(request({
      params: { id: groupId, proposalId: committeeId },
      body: { expectedVersion: 3 },
      header: () => undefined,
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupCommitteeService.executeCommitteeProposal).not.toHaveBeenCalled();
  });

  it('adds a committee member without trusting body-supplied context', async () => {
    (groupCommitteeService.addMember as jest.Mock)
      .mockResolvedValue({ membershipId: memberId } as never);
    const res = response();
    await groupCommitteeController.addMember(request({
      params: { id: groupId, committeeId },
      body: { memberId, committeeRole: 'chair', organizationId: 'attacker' },
    }) as any, res);
    expect(groupCommitteeService.addMember).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      expect.objectContaining({ committeeId, memberId, committeeRole: 'chair' }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('maps a second sitting chair to 409', async () => {
    (groupCommitteeService.addMember as jest.Mock)
      .mockRejectedValue(new Error('GROUP_COMMITTEE_CHAIR_ALREADY_SERVING') as never);
    const res = response();
    await groupCommitteeController.addMember(request({
      params: { id: groupId, committeeId },
      body: { memberId, committeeRole: 'chair' },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
  });

  it('schedules a meeting and normalizes the scheduled timestamp', async () => {
    (groupCommitteeService.scheduleMeeting as jest.Mock)
      .mockResolvedValue({ meetingId } as never);
    const res = response();
    await groupCommitteeController.scheduleMeeting(request({
      body: {
        meetingType: 'general',
        title: 'Annual general meeting',
        scheduledAt: '2099-09-01T10:00:00Z',
        requiredNoticeHours: 48,
        quorumNumerator: 1,
        quorumDenominator: 2,
      },
    }) as any, res);
    expect(groupCommitteeService.scheduleMeeting).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      expect.objectContaining({
        meetingType: 'general',
        scheduledAt: '2099-09-01T10:00:00.000Z',
        quorumNumerator: 1,
        quorumDenominator: 2,
      }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('maps a short notice window to 409', async () => {
    (groupCommitteeService.scheduleMeeting as jest.Mock)
      .mockRejectedValue(new Error('GROUP_MEETING_NOTICE_TOO_SHORT') as never);
    const res = response();
    await groupCommitteeController.scheduleMeeting(request({
      body: {
        meetingType: 'general',
        title: 'Rushed meeting',
        scheduledAt: '2099-09-01T10:00:00Z',
        requiredNoticeHours: 48,
        quorumNumerator: 1,
        quorumDenominator: 2,
      },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
  });

  it('holds a meeting using the caller supplied state version', async () => {
    (groupCommitteeService.holdMeeting as jest.Mock)
      .mockResolvedValue({ id: meetingId, quorum_met: true } as never);
    const res = response();
    await groupCommitteeController.holdMeeting(request({
      params: { id: groupId, meetingId },
      body: { expectedVersion: 1 },
    }) as any, res);
    expect(groupCommitteeService.holdMeeting).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      { meetingId, expectedVersion: 1, idempotencyKey: 'committee-command-001' },
    );
  });

  it('maps a stale meeting version to 409', async () => {
    (groupCommitteeService.holdMeeting as jest.Mock)
      .mockRejectedValue(new Error('GROUP_MEETING_VERSION_CONFLICT') as never);
    const res = response();
    await groupCommitteeController.holdMeeting(request({
      params: { id: groupId, meetingId },
      body: { expectedVersion: 1 },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
  });

  it('drafts minutes with an optional correction target', async () => {
    (groupCommitteeService.draftMinutes as jest.Mock)
      .mockResolvedValue({ minutesId } as never);
    const res = response();
    await groupCommitteeController.draftMinutes(request({
      params: { id: groupId, meetingId },
      body: { content: 'Resolved to proceed.', correctsMinutesId: minutesId },
    }) as any, res);
    expect(groupCommitteeService.draftMinutes).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      expect.objectContaining({ meetingId, correctsMinutesId: minutesId }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('maps a non-draft minute approval to 409', async () => {
    (groupCommitteeService.approveMinutes as jest.Mock).mockRejectedValue(
      new Error('GROUP_MEETING_MINUTES_NOT_DRAFT') as never,
    );
    const res = response();
    await groupCommitteeController.approveMinutes(request({
      params: { id: groupId, minutesId },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
  });

  it('returns neutral not-found for a foreign or missing meeting', async () => {
    (groupCommitteeService.getMeetingRecord as jest.Mock).mockResolvedValue(null as never);
    const res = response();
    await groupCommitteeController.getMeeting(request({
      params: { id: groupId, meetingId },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(404);
    expect(res.json).toHaveBeenCalledWith({ error: 'GROUP_MEETING_NOT_FOUND' });
  });

  it('rejects a malformed meeting identifier before persistence', async () => {
    const res = response();
    await groupCommitteeController.getMeeting(request({
      params: { id: groupId, meetingId: 'not-a-uuid' },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupCommitteeService.getMeetingRecord).not.toHaveBeenCalled();
  });
});
