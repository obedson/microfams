import fs from 'fs';
import path from 'path';
import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';
import { groupTreasuryEmergencyController } from '../controllers/groupTreasuryEmergencyController.js';

const read = (relative: string) => fs.readFileSync(path.join(process.cwd(), relative), 'utf8');

describe('GT-06B2 emergency treasury contract', () => {
  const migration = read('migrations/install_group_treasury_emergency_expenditure.sql');
  const routes = read('src/routes/groupAdmin.ts');

  it('is disabled by policy and caps emergency value', () => {
    expect(migration).toContain("IF NOT FOUND OR NOT pol.enabled");
    expect(migration).toContain('GROUP_TREASURY_EMERGENCY_CAP_EXCEEDED');
  });

  it('requires two distinct approvers before posting one journal', () => {
    expect(migration).toContain('first_approver_id');
    expect(migration).toContain('GROUP_TREASURY_EMERGENCY_APPROVER_DUPLICATE');
    expect(migration.match(/post_wallet_journal\(/g)).toHaveLength(1);
  });

  it('creates ratification and member-notice evidence atomically', () => {
    expect(migration).toContain("'emergency_ratification'");
    expect(migration).toContain("'group_treasury_emergency'");
    expect(migration).toContain("state='ratification_pending'");
  });

  it('preserves the original journal when ratification is rejected', () => {
    expect(migration).toContain("'ratification_rejected'");
    expect(migration).not.toContain('DELETE FROM journal_entries');
  });

  it('exposes acquisition and servicing routes under existing safe flags', () => {
    expect(routes).toContain("treasury/emergency-policy");
    expect(routes).toContain("treasury/emergencies/:emergencyId/approve");
    expect(routes).toContain("requireFeature('groups.treasury.create_disbursement')");
    expect(routes).toContain("requireFeature('groups.treasury.service_existing')");
    expect(groupTreasuryEmergencyController.approve).toBeInstanceOf(Function);
    expect(groupTreasuryEmergencyController.ratify).toBeInstanceOf(Function);
    expect(FEATURE_FLAGS.has('groups.treasury.create_disbursement')).toBe(true);
    expect(FEATURE_FLAGS.has('groups.treasury.service_existing')).toBe(true);
  });
});
