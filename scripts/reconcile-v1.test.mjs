import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = path => readFileSync(resolve(root, path), 'utf8');

test('V1 reconciliation is current and every linked evidence path exists', () => {
  execFileSync(process.execPath, ['scripts/reconcile-v1.mjs', '--check'], {
    cwd: root,
    stdio: 'pipe',
  });

  const report = JSON.parse(read('docs/V1_RECONCILIATION.json'));
  const markdown = read('docs/V1_RECONCILIATION.md');
  const workPlan = read('docs/WORK_PLAN.md').replaceAll('\r\n', '\n');
  const validStatuses = new Set([
    'candidate_complete',
    'claimed_complete_evidence_gap',
    'partial',
    'not_started',
  ]);

  assert.equal(report.schemaVersion, 1);
  assert.equal(report.items.length, report.summary.total);
  assert.equal(
    report.summary.workPlanSha256,
    createHash('sha256').update(workPlan).digest('hex'),
  );

  const ids = report.items.map(item => item.id);
  assert.equal(new Set(ids).size, ids.length, 'work-plan IDs must be unique');

  const organizationApiContract = report.items.find(item => item.id === 'WP-P2-006');
  assert.ok(organizationApiContract, 'organization verification evidence item must exist');
  assert.equal(organizationApiContract.status, 'partial');
  assert.equal(organizationApiContract.workPlanChecked, false);
  assert.equal(organizationApiContract.layers.api, 'evidence_found');
  assert.ok(organizationApiContract.evidence.api.includes('backend/src/routes/organizations.ts'));
  assert.ok(organizationApiContract.evidence.api.includes('backend/src/controllers/organizationController.ts'));
  assert.ok(organizationApiContract.evidence.tests.includes('backend/src/tests/organizationVerificationRouteApi.test.ts'));
  assert.equal(
    report.items.filter(item => Object.values(item.evidence).flat().includes('backend/src/tests/organizationVerificationRouteApi.test.ts')).length,
    1,
    'verified organization route evidence must not be attributed to unrelated work-plan items',
  );

  const bvnApiContract = report.items.find(item => item.id === 'WP-P2-007');
  assert.ok(bvnApiContract, 'progressive BVN evidence item must exist');
  assert.equal(bvnApiContract.status, 'candidate_complete');
  assert.equal(bvnApiContract.layers.api, 'evidence_found');
  assert.ok(bvnApiContract.evidence.api.includes('backend/src/routes/profile.ts'));
  assert.ok(bvnApiContract.evidence.api.includes('backend/src/controllers/profileController.ts'));
  assert.ok(bvnApiContract.evidence.tests.includes('backend/src/tests/profileBvnRouteApi.test.ts'));
  assert.equal(
    report.items.filter(item => Object.values(item.evidence).flat().includes('backend/src/tests/profileBvnRouteApi.test.ts')).length,
    1,
    'verified BVN route evidence must not be attributed to unrelated work-plan items',
  );

  for (const item of report.items) {
    assert.ok(validStatuses.has(item.status), `invalid status for ${item.id}`);
    assert.ok(markdown.includes(`| ${item.id} |`), `${item.id} is missing from the Markdown report`);

    if (item.status === 'candidate_complete') {
      assert.equal(item.workPlanChecked, true, `${item.id} cannot be a candidate while unchecked`);
    }
    if (item.workPlanChecked) {
      assert.notEqual(item.status, 'partial', `${item.id} hides a checked completion claim`);
      assert.notEqual(item.status, 'not_started', `${item.id} hides a checked completion claim`);
    }

    for (const evidencePath of Object.values(item.evidence).flat()) {
      const absolute = resolve(root, evidencePath);
      assert.ok(!relative(root, absolute).startsWith('..'), `${item.id} evidence escapes the repository`);
      assert.ok(existsSync(absolute), `${item.id} evidence is missing: ${evidencePath}`);
    }
  }
});
