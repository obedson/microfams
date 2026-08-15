import fs from 'fs';
import path from 'path';
import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';
import { groupTreasuryStatementController } from '../controllers/groupTreasuryStatementController.js';

const read=(relative:string)=>fs.readFileSync(path.join(process.cwd(),relative),'utf8');
describe('GT-07A group treasury statement contract',()=>{
  const migration=read('migrations/install_group_treasury_statements.sql');
  const routes=read('src/routes/groupAdmin.ts');
  it('derives balances only from posted journal lines at a cutoff',()=>{
    expect(migration).toContain('journal_lines line JOIN journal_entries entry');
    expect(migration).toContain('entry.posted_at<=p_cutoff');
    expect(migration).not.toContain('group_fund_balance');
  });
  it('reconstructs reservations and available value at the same cutoff',()=>{
    expect(migration).toContain('reservation.created_at<=p_cutoff');
    expect(migration).toContain('GREATEST(closing_minor-reserved_minor,0)');
  });
  it('returns aggregate ownership classifications without member identifiers',()=>{
    expect(migration).toContain('fundClassificationMinor');
    expect(migration).toContain('allocation.ownership');
    expect(migration).not.toContain("'userId'");
  });
  it('requires active paid membership and tenant ownership',()=>{
    expect(migration).toContain('GROUP_TREASURY_STATEMENT_NOT_AUTHORIZED');
    expect(migration).toContain('organization_id=p_organization_id');
  });
  it('uses the servicing-safe treasury flag',()=>{
    expect(routes).toContain("treasury/statement");
    expect(routes).toContain("requireFeature('groups.treasury.service_existing')");
    expect(FEATURE_FLAGS.has('groups.treasury.service_existing')).toBe(true);
    expect(groupTreasuryStatementController.read).toBeInstanceOf(Function);
  });
});
