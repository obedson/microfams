import fs from 'node:fs';
import path from 'node:path';
const read = (file: string) => fs.readFileSync(path.resolve(process.cwd(), file), 'utf8');
describe('reconciliation resolution API contract', () => {
  it('exposes tenant-authenticated maker-checker servicing routes', () => {
    const routes = read('src/routes/reconciliation.ts');
    expect(routes).toContain('authenticateToken');
    expect(routes).toContain('resolveTenant');
    expect(routes).toContain('financial.reconciliation.manual');
    expect(routes).toContain('financial.reconciliation.approve');
    expect(routes).toContain('financial.accounting.read');
    expect(routes).toContain('reconciliationController.startInvestigation');
    expect(routes).toContain('reconciliationController.requestResolution');
    expect(routes).toContain('reconciliationController.decideResolution');
  });
});
