import { jest } from '@jest/globals';
import { groupGovernanceController } from '../controllers/groupGovernanceController.js';
import { groupGovernanceService } from '../services/groupGovernanceService.js';

jest.mock('../services/groupGovernanceService.js', () => ({
  groupGovernanceService: {
    adoptInitialConstitution: jest.fn(),
    appointInitialOffice: jest.fn(),
    activate: jest.fn(),
    getSetup: jest.fn(),
    executeOfficeProposal: jest.fn(),
    delegateOffice: jest.fn(),
    endDelegation: jest.fn(),
    serviceExpiredOffices: jest.fn(),
    getOfficeLifecycle: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const organizationId = '00000000-0000-4000-8000-000000000201';
const groupId = '00000000-0000-4000-8000-000000000202';
const actorId = '00000000-0000-4000-8000-000000000203';
const memberId = '00000000-0000-4000-8000-000000000204';
const proposalId = '00000000-0000-4000-8000-000000000205';

const request = (overrides: Record<string, unknown> = {}) => ({
  tenant: { id: organizationId },
  user: { id: actorId },
  params: { id: groupId },
  body: {},
  header: (name: string) => name === 'Idempotency-Key' ? 'governance-command-001' : undefined,
  ...overrides,
});

describe('group governance setup API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('adopts normalized initial rules under resolved tenant and actor context', async () => {
    (groupGovernanceService.adoptInitialConstitution as jest.Mock)
      .mockResolvedValue({ constitutionId: memberId } as never);
    const res = response();
    await groupGovernanceController.adoptInitial(request({
      body: {
        name: 'Founding Constitution',
        rules: {
          minimumMembers: 3,
          ordinaryQuorumBps: 5000,
          ordinaryApprovalBps: 5001,
          specialQuorumBps: 6667,
          specialApprovalBps: 6667,
          voteChangeAllowed: false,
        },
        organizationId: 'attacker',
        actorId: 'attacker',
      },
    }) as any, res);
    expect(groupGovernanceService.adoptInitialConstitution).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      expect.objectContaining({
        name: 'Founding Constitution',
        idempotencyKey: 'governance-command-001',
      }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('appoints an office without accepting tenant or actor from the body', async () => {
    (groupGovernanceService.appointInitialOffice as jest.Mock)
      .mockResolvedValue({ assignmentId: memberId } as never);
    const res = response();
    await groupGovernanceController.appointInitialOffice(request({
      params: { id: groupId, officeKey: 'treasurer' },
      body: { memberId, organizationId: 'attacker', actorId: 'attacker' },
    }) as any, res);
    expect(groupGovernanceService.appointInitialOffice).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      expect.objectContaining({ officeKey: 'treasurer', memberId }),
    );
  });

  it('requires idempotency before activation reaches persistence', async () => {
    const res = response();
    await groupGovernanceController.activate(request({
      body: { expectedLifecycleVersion: 1 },
      header: () => undefined,
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupGovernanceService.activate).not.toHaveBeenCalled();
  });

  it('returns neutral not-found for a foreign or missing group setup', async () => {
    (groupGovernanceService.getSetup as jest.Mock).mockResolvedValue(null as never);
    const res = response();
    await groupGovernanceController.getSetup(request() as any, res);
    expect(res.status).toHaveBeenCalledWith(404);
    expect(res.json).toHaveBeenCalledWith({ error: 'Group not found' });
  });

  it('executes an approved office proposal in resolved tenant context', async () => {
    (groupGovernanceService.executeOfficeProposal as jest.Mock)
      .mockResolvedValue({ id: proposalId } as never);
    const res = response();
    await groupGovernanceController.executeOfficeProposal(request({
      params: { id: groupId, proposalId }, body: { expectedVersion: 3 },
    }) as any, res);
    expect(groupGovernanceService.executeOfficeProposal).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, proposalId,
      { expectedVersion: 3, idempotencyKey: 'governance-command-001' },
    );
  });

  it('creates a bounded temporary delegation without trusting actor input', async () => {
    (groupGovernanceService.delegateOffice as jest.Mock)
      .mockResolvedValue({ delegationId: proposalId } as never);
    const res = response();
    await groupGovernanceController.delegateOffice(request({
      params: { id: groupId, officeKey: 'chair' },
      body: {
        assignmentId: proposalId, delegateMemberId: memberId,
        delegationEndsAt: '2099-09-01T00:00:00Z', actorId: 'attacker',
      },
    }) as any, res);
    expect(groupGovernanceService.delegateOffice).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      expect.objectContaining({
        officeKey: 'chair', assignmentId: proposalId, delegateMemberId: memberId,
      }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('maps an active-office separation conflict to 409', async () => {
    (groupGovernanceService.executeOfficeProposal as jest.Mock)
      .mockRejectedValue(new Error('GROUP_OFFICE_SEPARATION_CONFLICT') as never);
    const res = response();
    await groupGovernanceController.executeOfficeProposal(request({
      params: { id: groupId, proposalId }, body: { expectedVersion: 3 },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
  });
});
