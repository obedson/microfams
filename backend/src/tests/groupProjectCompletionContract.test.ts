import fs from 'fs';
import path from 'path';
import { groupProjectCompletionController } from '../controllers/groupProjectCompletionController.js';
const read=(p:string)=>fs.readFileSync(path.join(process.cwd(),p),'utf8');
describe('GT-08B3 project completion evidence',()=>{
 const migration=read('migrations/install_group_project_foundation.sql'); const routes=read('src/routes/groupAdmin.ts');
 it('records deliverables, residual disposition, assets, and reconciliation',()=>{expect(migration).toContain('group_project_completions');expect(migration).toContain('residual_fund_disposition');expect(migration).toContain('final_reconciliation');});
 it('requires balanced final reconciliation and evidence',()=>{expect(migration).toContain('GROUP_PROJECT_RECONCILIATION_INCOMPLETE');expect(migration).toContain('GROUP_PROJECT_RECONCILIATION_UNBALANCED');expect(migration).toContain('GROUP_PROJECT_COMPLETION_INVALID');});
 it('completes without journal posting',()=>{expect(migration).toContain('PROJECT_COMPLETED');expect(migration).not.toContain('post_wallet_journal(');});
 it('exposes a governance-gated command',()=>{expect(routes).toContain('/:projectId/complete');expect(groupProjectCompletionController.complete).toBeInstanceOf(Function);});
});
