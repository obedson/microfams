import { readFileSync } from 'fs';
import { join } from 'path';

describe('production contribution job wiring', () => {
  it('does not start the legacy non-atomic contribution schedulers', () => {
    const indexSource = readFileSync(join(process.cwd(), 'src/index.ts'), 'utf8');

    expect(indexSource).not.toContain("from './jobs/contributionJobs.js'");
    expect(indexSource).not.toContain('startCronJobs()');
    expect(indexSource).toContain('startBookingJobs()');
    expect(indexSource).toContain('startWalletJobs()');
    expect(indexSource).toContain('startSavingsJobs()');
  });
});
