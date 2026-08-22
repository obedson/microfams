import { RetentionSelectionRepository, RetentionSelectionWorker } from '../services/retentionSelectionWorker.js';

const run = (id: string) => ({ id, requested_by: 'actor-1', idempotency_key: `run-${id}`, request_hash: 'hash' });

describe('RetentionSelectionWorker', () => {
  it('selects planned dry runs and reports successful completion', async () => {
    const repository: jest.Mocked<RetentionSelectionRepository> = {
      listPlanned: jest.fn().mockResolvedValue([run('one'), run('two')]),
      select: jest.fn().mockResolvedValue({ status: 'completed' }),
    };
    await expect(new RetentionSelectionWorker(repository).runOnce(10)).resolves.toEqual({ scanned: 2, completed: 2, failed: 0 });
    expect(repository.select).toHaveBeenCalledTimes(2);
  });

  it('continues after one run fails and never mutates source records directly', async () => {
    const repository: jest.Mocked<RetentionSelectionRepository> = {
      listPlanned: jest.fn().mockResolvedValue([run('one'), run('two')]),
      select: jest.fn().mockRejectedValueOnce(new Error('hold lookup unavailable')).mockResolvedValueOnce({ status: 'completed' }),
    };
    await expect(new RetentionSelectionWorker(repository).runOnce()).resolves.toEqual({ scanned: 2, completed: 1, failed: 1 });
    expect(repository.listPlanned).toHaveBeenCalledWith(20);
  });
});
