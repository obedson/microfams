import fs from 'fs';
import path from 'path';
const read=(p:string)=>fs.readFileSync(path.join(process.cwd(),p),'utf8');
describe('GT-08B5 project restricted-fund execution guards',()=>{
 const migration=read('migrations/install_group_project_foundation.sql');
 it('locks project spend to an active project and approved budget',()=>{expect(migration).toContain('GROUP_PROJECT_SPEND_REQUIRES_ACTIVE_PROJECT');expect(migration).toContain('GROUP_PROJECT_SPEND_BUDGET_INVALID');expect(migration).toContain('GROUP_PROJECT_SPEND_EXCEEDS_APPROVED_BUDGET');});
 it('enforces cumulative treasury-budget restriction rules',()=>{expect(migration).toContain('GROUP_PROJECT_RESTRICTED_FUND_RULE_VIOLATION');expect(migration).toContain('budget_id=NEW.budget_id');expect(migration).toContain('restricted_spent+NEW.amount_minor<=rule_cap');});
 it('uses an insert trigger at the treasury boundary',()=>{expect(migration).toContain('enforce_group_project_restricted_disbursement');expect(migration).toContain('BEFORE INSERT ON group_treasury_disbursements');});
});
