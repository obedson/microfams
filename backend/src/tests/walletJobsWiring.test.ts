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
});
