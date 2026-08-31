import {
  DurableIdentityChallengeExpiryJob,
  IdentityChallengeExpiryRunner,
} from '../jobs/durableIdentityChallengeExpiryJob.js';
import { DurableJobExecutionRepository } from '../services/durableJobExecutionService.js';

const executions = (): jest.Mocked<DurableJobExecutionRepository> => ({
  claim: jest.fn(),
  complete: jest.fn(),
  fail: jest.fn(),
});
const runner = (): jest.Mocked<IdentityChallengeExpiryRunner> => ({
  runOnce: jest.fn(),
});

describe('DurableIdentityChallengeExpiryJob', () => {
  const now = new Date('2026-08-31T15:00:42.000Z');

  it('does not service challenges without the lease', async () => {
    const repo = executions();
    const expiry = runner();
    repo.claim.mockResolvedValue(null);
    await expect(new DurableIdentityChallengeExpiryJob(
      repo, expiry, () => now, 'identity-expiry-test',
    ).runOnce()).resolves.toEqual({ claimed: false, expired: 0 });
    expect(expiry.runOnce).not.toHaveBeenCalled();
  });

  it('completes the leased execution with aggregate evidence', async () => {
    const repo = executions();
    const expiry = runner();
    repo.claim.mockResolvedValue({ id: 'execution-1', attempt_count: 1, max_attempts: 5 });
    expiry.runOnce.mockResolvedValue({ expired: 4 });
    await expect(new DurableIdentityChallengeExpiryJob(
      repo, expiry, () => now, 'identity-expiry-test',
    ).runOnce(20)).resolves.toEqual({ claimed: true, expired: 4 });
    expect(repo.complete).toHaveBeenCalledWith(expect.objectContaining({
      executionId: 'execution-1',
      result: { expired: 4 },
    }));
  });

  it('persists retry or dead-letter evidence after failure', async () => {
    const repo = executions();
    const expiry = runner();
    repo.claim.mockResolvedValue({ id: 'execution-2', attempt_count: 5, max_attempts: 5 });
    expiry.runOnce.mockRejectedValue(new Error('opaque-token-must-not-be-logged'));
    await expect(new DurableIdentityChallengeExpiryJob(
      repo, expiry, () => now, 'identity-expiry-test',
    ).runOnce()).rejects.toThrow('opaque-token-must-not-be-logged');
    expect(repo.fail).toHaveBeenCalledWith(expect.objectContaining({
      failureCode: 'IDENTITY_CHALLENGE_EXPIRY_JOB_FAILED',
    }));
  });
});
