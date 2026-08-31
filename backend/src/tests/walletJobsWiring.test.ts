import fs from 'fs';
import path from 'path';

describe('wallet job durable scheduler wiring', () => {
  const source = fs.readFileSync(
    path.resolve(process.cwd(), 'src/jobs/walletJobs.ts'),
    'utf8',
  );

  it('runs payout reconciliation through the durable worker', () => {
    expect(source).toContain('await payoutReconciliationWorker.runOnce()');
    expect(source).not.toContain('checkPendingWithdrawals');
    expect(source).not.toContain(".from('payouts')");
  });

  it('runs NUBAN retries through the durable worker', () => {
    expect(source).toContain('await nubanRetryWorker.runOnce()');
    expect(source).not.toContain('retryNubanProvisioning');
    expect(source).not.toContain(".from('group_virtual_accounts')");
  });

  it('does not schedule the prohibited grace-period redistribution path', () => {
    expect(source).not.toContain('checkGracePeriodExpiries');
    expect(source).not.toContain('handleGracePeriodExpiry');
    expect(source).not.toContain("cron.schedule('0 2 * * *'");
    expect(source).not.toContain(".from('users')");
  });
});
