import fs from 'fs';
import path from 'path';
import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';
import { groupProjectController } from '../controllers/groupProjectController.js';
const read=(p:string)=>fs.readFileSync(path.join(process.cwd(),p),'utf8');
describe('GT-08A group project foundation contract',()=>{
 const migration=read('migrations/install_group_project_foundation.sql'); const routes=read('src/routes/groupAdmin.ts');
 it('stores governed projects and immutable budget evidence',()=>{expect(migration).toContain('group_projects');expect(migration).toContain('group_project_budget_versions');expect(migration).toContain('GROUP_PROJECT_ENGINE_REQUIRED');expect(migration).toContain('total_minor');});
 it('binds proposals and requires independent approval',()=>{expect(migration).toContain('proposal_type=\'project\'');expect(migration).toContain('q.proposer_id<>a');expect(migration).toContain('PROJECT_APPROVED');});
 it('activates without journal posting',()=>{expect(migration).toContain('PROJECT_ACTIVATED');expect(migration).not.toContain('post_wallet_journal(');});
 it('exposes governance-gated commands',()=>{expect(routes).toContain('/:id/projects');expect(routes).toContain("requireFeature('groups.governance.manage')");expect(FEATURE_FLAGS.has('groups.governance.manage')).toBe(true);expect(groupProjectController.create).toBeInstanceOf(Function);});
});
