import {
  SavingsFeatureEvaluator,
  SavingsStandingOrderRepository,
  SavingsStandingOrderWorker,
} from '../domains/financial/savingsStandingOrderWorker.js';

const now = new Date('2026-08-10T10:00:00.000Z');
const due = [
  { id: '00000000-0000-4000-8000-000000000201', organizationId: '00000000-0000-4000-8000-000000000101', jurisdiction: 'NG' },
  { id: '00000000-0000-4000-8000-000000000202', organizationId: '00000000-0000-4000-8000-000000000102', jurisdiction: 'NG' },
];

describe('SavingsStandingOrderWorker', () => {
  it('services only tenants whose existing-obligation flag is enabled', async () => {
    const repository: jest.Mocked<SavingsStandingOrderRepository> = {
      listDue: jest.fn().mockResolvedValue(due),
      service: jest.fn().mockResolvedValue({ state: 'succeeded' }),
    };
    const flags: jest.Mocked<SavingsFeatureEvaluator> = {
      evaluate: jest.fn()
        .mockResolvedValueOnce({ key: 'financial.savings.service_existing', enabled: true, config: {}, source: 'default', reason: 'enabled' })
        .mockResolvedValueOnce({ key: 'financial.savings.service_existing', enabled: false, config: {}, source: 'emergency_stop', reason: 'stopped' }),
    };
    const worker = new SavingsStandingOrderWorker(repository, flags, () => now, 'worker-test');

    await expect(worker.runOnce()).resolves.toEqual({ due: 2, serviced: 1, skipped: 1, errors: 0 });
    expect(repository.service).toHaveBeenCalledWith(due[0].organizationId, due[0].id, 'worker-test', now.toISOString());
    expect(repository.service).toHaveBeenCalledTimes(1);
  });

  it('isolates one servicing error and continues the batch', async () => {
    const repository: jest.Mocked<SavingsStandingOrderRepository> = {
      listDue: jest.fn().mockResolvedValue(due),
      service: jest.fn().mockRejectedValueOnce(new Error('transient')).mockResolvedValueOnce({ state: 'succeeded' }),
    };
    const flags: jest.Mocked<SavingsFeatureEvaluator> = {
      evaluate: jest.fn().mockResolvedValue({
        key: 'financial.savings.service_existing', enabled: true, config: {}, source: 'default', reason: 'enabled',
      }),
    };
    const worker = new SavingsStandingOrderWorker(repository, flags, () => now, 'worker-test');

    await expect(worker.runOnce()).resolves.toEqual({ due: 2, serviced: 1, skipped: 0, errors: 1 });
    expect(repository.service).toHaveBeenCalledTimes(2);
  });
});
