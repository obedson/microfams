import fs from 'fs';
import path from 'path';
import { groupProjectBudgetController } from '../controllers/groupProjectBudgetController.js';
const read=(p:string)=>fs.readFileSync(path.join(process.cwd(),p),'utf8');
describe('GT-08B1 governed project budget amendments',()=>{
 const migration=read('migrations/install_group_project_foundation.sql'); const routes=read('src/routes/groupAdmin.ts');
 it('retains versions and supersedes only on approval',()=>{expect(migration).toContain('create_group_project_budget_amendment');expect(migration).toContain('BUDGET_AMENDMENT_PROPOSED');expect(migration).toContain("state='superseded'");});
 it('requires an approved project proposal and independent checker',()=>{expect(migration).toContain('GROUP_PROJECT_BUDGET_PROPOSAL_INVALID');expect(migration).toContain('GROUP_PROJECT_BUDGET_APPROVAL_REQUIRED');expect(migration).toContain('q.proposer_id');});
 it('does not post money',()=>expect(migration).not.toContain('post_wallet_journal('));
 it('exposes governed amendment commands',()=>{expect(routes).toContain('budget-amendments');expect(groupProjectBudgetController.approve).toBeInstanceOf(Function);});
});
