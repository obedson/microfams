import { jest } from '@jest/globals';
import { groupProposalController } from '../controllers/groupProposalController.js';
import { groupProposalService } from '../services/groupProposalService.js';

jest.mock('../services/groupProposalService.js', () => ({
  groupProposalService: {
    create: jest.fn(), open: jest.fn(), vote: jest.fn(), close: jest.fn(),
    cancel: jest.fn(), list: jest.fn(), get: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const organizationId = '00000000-0000-4000-8000-000000000401';
const groupId = '00000000-0000-4000-8000-000000000402';
const actorId = '00000000-0000-4000-8000-000000000403';
const proposalId = '00000000-0000-4000-8000-000000000404';
const request = (overrides: Record<string, unknown> = {}) => ({
  tenant: { id: organizationId },
  user: { id: actorId },
  params: { id: groupId, proposalId },
  query: {},
  body: {},
  header: (name: string) => name === 'Idempotency-Key' ? 'proposal-command-001' : undefined,
  ...overrides,
});

describe('group proposal API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('creates only under resolved tenant, group, and actor context', async () => {
    (groupProposalService.create as jest.Mock).mockResolvedValue({ proposalId } as never);
    const res = response();
    await groupProposalController.create(request({
      body: {
        proposalType: 'ordinary',
        publicSummary: 'Purchase shared drying equipment for the group.',
        privateEvidenceRefs: ['evidence://quote/1'],
        executionPayload: { asset: 'dryer' },
        conflictUserIds: [],
        opensAt: '2026-08-03T10:00:00Z',
        closesAt: '2026-08-04T10:00:00Z',
        organizationId: 'attacker',
        actorId: 'attacker',
      },
    }) as any, res);
    expect(groupProposalService.create).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      expect.objectContaining({ proposalType: 'ordinary', idempotencyKey: 'proposal-command-001' }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('binds a vote to the authenticated voter and rejects missing idempotency', async () => {
    const res = response();
    await groupProposalController.vote(request({
      body: { choice: 'approve', actorId: 'attacker' },
      header: () => undefined,
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupProposalService.vote).not.toHaveBeenCalled();
  });

  it('casts a validated final vote against the route proposal', async () => {
    (groupProposalService.vote as jest.Mock).mockResolvedValue({ voteId: actorId } as never);
    const res = response();
    await groupProposalController.vote(request({ body: { choice: 'abstain' } }) as any, res);
    expect(groupProposalService.vote).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, proposalId,
      { choice: 'abstain', idempotencyKey: 'proposal-command-001' },
    );
  });

  it('returns a neutral not-found response for an inaccessible proposal', async () => {
    (groupProposalService.get as jest.Mock).mockResolvedValue(null as never);
    const res = response();
    await groupProposalController.get(request() as any, res);
    expect(res.status).toHaveBeenCalledWith(404);
    expect(res.json).toHaveBeenCalledWith({ error: 'Group proposal not found' });
  });

  it('maps optimistic concurrency failures to conflict', async () => {
    (groupProposalService.close as jest.Mock).mockRejectedValue(
      new Error('GROUP_PROPOSAL_VERSION_CONFLICT') as never,
    );
    const res = response();
    await groupProposalController.close(request({ body: { expectedVersion: 1 } }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
  });
});
