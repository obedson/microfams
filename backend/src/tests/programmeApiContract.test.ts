import fs from 'node:fs';
import path from 'node:path';
const read = (file: string) => fs.readFileSync(path.resolve(process.cwd(), file), 'utf8');
describe('institutional programme API contract', () => {
  it('exposes cohort, benefit, and governed reporting-scope routes', () => {
    const routes = read('src/routes/programmes.ts');
    expect(routes).toContain("router.get('/:id/cohorts'");
    expect(routes).toContain("router.post('/:id/benefits'");
    expect(routes).toContain("router.get('/reporting-scopes'");
    expect(routes).toContain("router.post('/:id/reporting-scopes'");
    expect(routes).toContain("router.post('/reporting-scopes/:scopeId/decision'");
    expect(routes).toContain("router.post('/reporting-scopes/:scopeId/revoke'");
    expect(routes).toContain("requireTenantRole(['owner', 'admin', 'program_manager'])");
  });
});
