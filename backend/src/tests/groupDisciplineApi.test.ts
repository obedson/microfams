import { jest } from '@jest/globals';
import { groupDisciplineController } from '../controllers/groupDisciplineController.js';
import { groupDisciplineService } from '../services/groupDisciplineService.js';

jest.mock('../services/groupDisciplineService.js', () => ({
  groupDisciplineService: {
    create: jest.fn(), execute: jest.fn(), appeal: jest.fn(), decideAppeal: jest.fn(),
    listForMember: jest.fn(), get: jest.fn(),
  },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};
const organizationId = '00000000-0000-4000-8000-000000000701';
const groupId = '00000000-0000-4000-8000-000000000702';
const actorId = '00000000-0000-4000-8000-000000000703';
const memberId = '00000000-0000-4000-8000-000000000704';
const caseId = '00000000-0000-4000-8000-000000000705';
const appealId = '00000000-0000-4000-8000-000000000706';
const request = (overrides: Record<string, unknown> = {}) => ({
  tenant: { id: organizationId },
  user: { id: actorId },
  params: { id: groupId, memberId, caseId, appealId },
  query: {}, body: {},
  header: (name: string) => name === 'Idempotency-Key' ? 'discipline-command-001' : undefined,
  ...overrides,
});

describe('group discipline API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('creates a tenant-bound noticed case and strips caller identity fields', async () => {
    (groupDisciplineService.create as jest.Mock).mockResolvedValue({ caseId, proposalId: caseId } as never);
    const res = response();
    await groupDisciplineController.create(request({ body: {
      proposedAction: 'suspend', reasonCode: 'MATERIAL_POLICY_BREACH',
      publicNotice: 'The member may respond to the documented allegation before voting opens.',
      privateEvidenceRefs: ['evidence://discipline/1'],
      responseDueAt: new Date(Date.now() + 48 * 3_600_000).toISOString(),
      proposalClosesAt: new Date(Date.now() + 96 * 3_600_000).toISOString(),
      appealWindowDays: 30, organizationId: 'attacker', actorId: 'attacker',
    } }) as any, res);
    expect(groupDisciplineService.create).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, memberId,
      expect.objectContaining({ proposedAction: 'suspend', idempotencyKey: 'discipline-command-001' }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects notice periods shorter than twenty-four hours', async () => {
    const res = response();
    await groupDisciplineController.create(request({ body: {
      proposedAction: 'expel', reasonCode: 'MATERIAL_POLICY_BREACH',
      publicNotice: 'This notice is long enough but its response period is not.',
      privateEvidenceRefs: ['evidence://discipline/1'],
      responseDueAt: new Date(Date.now() + 2 * 3_600_000).toISOString(),
      proposalClosesAt: new Date(Date.now() + 96 * 3_600_000).toISOString(),
      appealWindowDays: 30,
    } }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupDisciplineService.create).not.toHaveBeenCalled();
  });

  it('binds an appeal to the authenticated appellant', async () => {
    (groupDisciplineService.appeal as jest.Mock).mockResolvedValue({ appealId } as never);
    const res = response();
    await groupDisciplineController.appeal(request({ body: {
      grounds: 'The decision omitted material evidence and requires independent review.',
      evidenceRefs: [], appellantId: 'attacker',
    } }) as any, res);
    expect(groupDisciplineService.appeal).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, caseId,
      expect.objectContaining({ idempotencyKey: 'discipline-command-001' }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('maps independent-review conflicts without leaking database details', async () => {
    (groupDisciplineService.decideAppeal as jest.Mock).mockRejectedValue(
      new Error('GROUP_DISCIPLINE_APPEAL_REVIEWER_CONFLICT') as never,
    );
    const res = response();
    await groupDisciplineController.decideAppeal(request({ body: {
      outcome: 'reinstate', reasonCode: 'APPEAL_EVIDENCE_ACCEPTED',
      decisionEvidenceRefs: ['evidence://review/1'],
    } }) as any, res);
    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json).toHaveBeenCalledWith({ error: 'GROUP_DISCIPLINE_APPEAL_REVIEWER_CONFLICT' });
  });
});
