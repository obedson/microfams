import fs from 'node:fs';
import path from 'node:path';
const read=(file:string)=>fs.readFileSync(path.resolve(process.cwd(),file),'utf8');
describe('inventory API contract',()=>{it('keeps inventory routes tenant-scoped and role-protected',()=>{const routes=read('src/routes/inventory.ts');expect(routes).toContain('authenticateToken');expect(routes).toContain('resolveTenant');expect(routes).toContain("requireFeature('farm_erp.operations')");expect(routes).toContain("router.post('/:id/movements'");expect(routes).toContain("requireTenantRole(['owner', 'admin', 'program_manager'])");});});
