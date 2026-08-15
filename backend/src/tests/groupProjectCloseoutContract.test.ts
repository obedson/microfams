import fs from 'fs';
import path from 'path';
import { groupProjectCloseoutController } from '../controllers/groupProjectCloseoutController.js';
const read=(p:string)=>fs.readFileSync(path.join(process.cwd(),p),'utf8');
describe('GT-08B4 group project closeout',()=>{
 const migration=read('migrations/install_group_project_foundation.sql'); const routes=read('src/routes/groupAdmin.ts');
 it('requires completed evidence and resolved residual disposition',()=>{expect(migration).toContain('GROUP_PROJECT_RESIDUAL_DISPOSITION_PENDING');expect(migration).toContain('GROUP_PROJECT_BUDGET_AMENDMENT_PENDING');expect(migration).toContain("p.state<>'completed'");});
 it('requires an approved independent close proposal',()=>{expect(migration).toContain("q.execution_payload->>'action'<>'close'");expect(migration).toContain('q.proposer_id');});
 it('records immutable closeout evidence without posting money',()=>{expect(migration).toContain('PROJECT_CLOSED');expect(migration).toContain('closed_at');expect(migration).not.toContain('post_wallet_journal(');});
 it('exposes a governance-gated close command',()=>{expect(routes).toContain('/:projectId/close');expect(groupProjectCloseoutController.close).toBeInstanceOf(Function);});
});
