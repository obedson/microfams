import fs from 'node:fs';
import path from 'node:path';
const read = (file: string) => fs.readFileSync(path.resolve(process.cwd(), file), 'utf8');
describe('institutional programme API contract', () => { it('exposes cohort and benefit routes with role enforcement', () => { const routes = read('src/routes/programmes.ts'); expect(routes).toContain("router.get('/:id/cohorts'"); expect(routes).toContain("router.post('/:id/cohorts'"); expect(routes).toContain("router.get('/:id/benefits'"); expect(routes).toContain("router.post('/:id/benefits'"); expect(routes).toContain("requireTenantRole(['owner', 'admin', 'program_manager'])"); }); });
