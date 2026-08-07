import { jest } from '@jest/globals';
import { groupContributionCycleController } from '../controllers/groupContributionCycleController.js';
import { groupContributionCycleService } from '../services/groupContributionCycleService.js';

jest.mock('../services/groupContributionCycleService.js', () => ({
  groupContributionCycleService: {
    openCycle: jest.fn(),
    adjustObligation: jest.fn(),
    transitionCycle: jest.fn(),
    closeCycle: jest.fn(),
    cancelCycle: jest.fn(),
    listCycles: jest.fn(),
    getCycle: jest.fn(),
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
const productId = '00000000-0000-4000-8000-000000000404';
const cycleId = '00000000-0000-4000-8000-000000000405';
const obligationId = '00000000-0000-4000-8000-000000000406';

const request = (overrides: Record<string, unknown> = {}) => ({
  tenant: { id: organizationId },
  user: { id: actorId, email: 'member@example.test' },
  params: { id: groupId },
  body: {},
  query: {},
  header: (name: string) => name === 'Idempotency-Key' ? 'cycle-command-001' : undefined,
  ...overrides,
});

const openBody = {
  productId,
  periodKey: '2026-09',
  periodStart: '2026-09-01',
  periodEnd: '2026-09-30',
  dueDate: '2026-09-25',
  timezone: 'Africa/Lagos',
};

describe('group contribution cycle API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('opens a cycle in resolved tenant context, ignoring body-supplied identity', async () => {
    (groupContributionCycleService.openCycle as jest.Mock)
      .mockResolvedValue({ cycleId } as never);
    const res = response();
    await groupContributionCycleController.openCycle(request({
      body: { ...openBody, organizationId: 'attacker', actorId: 'attacker' },
    }) as any, res);
    expect(groupContributionCycleService.openCycle).toHaveBeenCalledWith(
      { organizationId, groupId, actorId },
      expect.objectContaining({ productId, periodKey: '2026-09' }),
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('refuses a cycle that falls due before its period begins', async () => {
    const res = response();
    await groupContributionCycleController.openCycle(request({
      body: { ...openBody, dueDate: '2026-08-01' },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupContributionCycleService.openCycle).not.toHaveBeenCalled();
  });

  it('requires idempotency before a cycle reaches persistence', async () => {
    const res = response();
    await groupContributionCycleController.openCycle(request({
      body: openBody, header: () => undefined,
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupContributionCycleService.openCycle).not.toHaveBeenCalled();
  });

  it('refuses an obligation adjustment with no reason', async () => {
    const res = response();
    await groupContributionCycleController.adjustObligation(request({
      params: { id: groupId, obligationId },
      body: { adjustmentKind: 'waiver', deltaMinor: -250_000 },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupContributionCycleService.adjustObligation).not.toHaveBeenCalled();
  });

  it('refuses a zero-delta adjustment that would record nothing', async () => {
    const res = response();
    await groupContributionCycleController.adjustObligation(request({
      params: { id: groupId, obligationId },
      body: {
        adjustmentKind: 'reduction', deltaMinor: 0,
        reasonCode: 'HARDSHIP', reason: 'No change at all',
      },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupContributionCycleService.adjustObligation).not.toHaveBeenCalled();
  });

  it('passes a fully evidenced adjustment through', async () => {
    (groupContributionCycleService.adjustObligation as jest.Mock)
      .mockResolvedValue({ adjustmentId: obligationId } as never);
    const res = response();
    await groupContributionCycleController.adjustObligation(request({
      params: { id: groupId, obligationId },
      body: {
        adjustmentKind: 'waiver', deltaMinor: -250_000,
        reasonCode: 'HARDSHIP', reason: 'Committee approved a hardship waiver.',
      },
    }) as any, res);
    expect(groupContributionCycleService.adjustObligation).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, obligationId,
      expect.objectContaining({
        adjustmentKind: 'waiver', deltaMinor: -250_000, reasonCode: 'HARDSHIP',
      }),
    );
  });

  it('defaults exception acknowledgement to false when closing', async () => {
    (groupContributionCycleService.closeCycle as jest.Mock)
      .mockResolvedValue({ exceptionReport: {} } as never);
    const res = response();
    await groupContributionCycleController.closeCycle(request({
      params: { id: groupId, cycleId },
      body: { reasonCode: 'PERIOD_COMPLETE' },
    }) as any, res);
    expect(groupContributionCycleService.closeCycle).toHaveBeenCalledWith(
      { organizationId, groupId, actorId }, cycleId,
      expect.objectContaining({
        reasonCode: 'PERIOD_COMPLETE', acknowledgeExceptions: false,
      }),
    );
  });

  it('maps unacknowledged close exceptions to 409 rather than reporting success', async () => {
    (groupContributionCycleService.closeCycle as jest.Mock).mockRejectedValue(
      new Error('GROUP_CONTRIBUTION_CYCLE_EXCEPTIONS_UNACKNOWLEDGED') as never,
    );
    const res = response();
    await groupContributionCycleController.closeCycle(request({
      params: { id: groupId, cycleId },
      body: { reasonCode: 'PERIOD_COMPLETE' },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith({
      error: 'GROUP_CONTRIBUTION_CYCLE_EXCEPTIONS_UNACKNOWLEDGED',
    });
  });

  it('maps a mid-cycle rule supersede to 409', async () => {
    (groupContributionCycleService.openCycle as jest.Mock)
      .mockRejectedValue(new Error('GROUP_CONTRIBUTION_CYCLE_ALREADY_BILLING') as never);
    const res = response();
    await groupContributionCycleController.openCycle(request({ body: openBody }) as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
  });

  it('allows only the documented cycle transitions through the API', async () => {
    const res = response();
    await groupContributionCycleController.transitionCycle(request({
      params: { id: groupId, cycleId }, body: { toState: 'closed' },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupContributionCycleService.transitionCycle).not.toHaveBeenCalled();
  });

  it('rejects a malformed cycle id before reaching the service', async () => {
    const res = response();
    await groupContributionCycleController.getCycle(request({
      params: { id: groupId, cycleId: 'not-a-uuid' },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(groupContributionCycleService.getCycle).not.toHaveBeenCalled();
  });

  it('returns neutral not-found when the caller may not read the cycle', async () => {
    (groupContributionCycleService.getCycle as jest.Mock).mockResolvedValue(null as never);
    const res = response();
    await groupContributionCycleController.getCycle(request({
      params: { id: groupId, cycleId },
    }) as any, res);
    expect(res.status).toHaveBeenCalledWith(404);
  });

  it('bounds the cycle list page size', async () => {
    (groupContributionCycleService.listCycles as jest.Mock)
      .mockResolvedValue({ cycles: [] } as never);
    const res = response();
    await groupContributionCycleController.listCycles(request({
      query: { limit: '5000' },
    }) as any, res);
    expect(groupContributionCycleService.listCycles)
      .toHaveBeenCalledWith({ organizationId, groupId, actorId }, null, 100);
  });
});
