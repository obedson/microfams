import fs from 'fs';
import path from 'path';
import { groupProjectLifecycleController } from '../controllers/groupProjectLifecycleController.js';
const read=(p:string)=>fs.readFileSync(path.join(process.cwd(),p),'utf8');
describe('GT-08B2 group project pause and resume',()=>{
 const migration=read('migrations/install_group_project_foundation.sql'); const routes=read('src/routes/groupAdmin.ts');
 it('permits only active to paused and paused to active',()=>{expect(migration).toContain("p.state<>'active'");expect(migration).toContain("p.state<>'paused'");});
 it('requires reasoned append-only evidence',()=>{expect(migration).toContain('PROJECT_PAUSED');expect(migration).toContain('PROJECT_RESUMED');expect(migration).toContain("jsonb_build_object('reason'");});
 it('does not alter project budgets or post money',()=>{expect(migration).not.toContain('post_wallet_journal(');});
 it('exposes governance-gated lifecycle commands',()=>{expect(routes).toContain('/:projectId/pause');expect(routes).toContain('/:projectId/resume');expect(groupProjectLifecycleController.pause).toBeInstanceOf(Function);});
});
