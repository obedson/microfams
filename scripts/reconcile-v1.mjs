import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const workPlanPath = join(root, 'docs', 'WORK_PLAN.md');
const jsonPath = join(root, 'docs', 'V1_RECONCILIATION.json');
const markdownPath = join(root, 'docs', 'V1_RECONCILIATION.md');
const checkOnly = process.argv.includes('--check');

const read = path => readFileSync(path, 'utf8');
const canonicalText = text => text.replaceAll('\r\n', '\n');
const walk = directory => {
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? walk(path) : [path];
  });
};
const repoFiles = execFileSync('git', ['ls-files', '-z'], { cwd: root }).toString('utf8').split('\0').filter(Boolean).map(path => join(root, path));
const generatedArtifacts = new Set(['docs/V1_RECONCILIATION.json', 'docs/V1_RECONCILIATION.md', 'docs/V1_GAPS.md', 'docs/V1_RELEASE_READINESS.md']);
const searchableFiles = repoFiles.filter(path => /\.(md|sql|ts|tsx|js|jsx|mjs|yml|yaml)$/i.test(path) && !generatedArtifacts.has(relative(root, path).replaceAll('\\', '/')));
const contents = new Map(searchableFiles.map(path => [path, read(path).toLowerCase()]));
const rel = path => relative(root, path).replaceAll('\\', '/');
const corpusCache = new Map();
const corpusFor = roots => {
  const key = roots.join('|');
  if (!corpusCache.has(key)) corpusCache.set(key, searchableFiles.filter(path => roots.some(rootName => rel(path).startsWith(rootName))).map(path => ({ path: rel(path), haystack: `${rel(path).toLowerCase()} ${contents.get(path)}` })));
  return corpusCache.get(key);
};

const stop = new Set(['add','and','with','from','into','the','for','through','without','before','after','current','version','one','all','existing','required','complete','implement','implementation','approved','approval','evidence']);
const aliases = new Map([
  ['credit', ['loan']], ['loans', ['loan']], ['dividends', ['dividend']], ['investments', ['investment']],
  ['payments', ['payment']], ['payouts', ['payout']], ['groups', ['group']], ['statements', ['statement']],
  ['organizations', ['organization']], ['notifications', ['notification']], ['assets', ['asset']],
  ['courses', ['course']], ['warehouses', ['warehouse']], ['programmes', ['programme', 'program']],
]);
const tokensFor = text => {
  const base = (text.toLowerCase().match(/[a-z][a-z0-9_-]{2,}/g) ?? []).filter(token => !stop.has(token));
  const expanded = base.flatMap(token => [token, ...(aliases.get(token) ?? [])]);
  return [...new Set(expanded)].sort((a, b) => b.length - a.length).slice(0, 8);
};
const evidence = (item, roots, minimum = 1) => {
  const tokens = tokensFor(item);
  const matches = corpusFor(roots).map(file => {
    const score = tokens.filter(token => file.haystack.includes(token)).length;
    return { path: file.path, score };
  }).filter(match => match.score >= minimum).sort((a, b) => b.score - a.score || a.path.localeCompare(b.path));
  return matches.slice(0, 4).map(match => match.path);
};
const explicitId = text => text.match(/\b(?:FC|SAV|CRD|INV|ESC|BS|GT|AC|DIV)-\d+[A-Z0-9]*/)?.[0] ?? null;
const slug = text => text.toLowerCase().replace(/\[[^\]]+\]\([^\)]+\)/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48);

let phase = 'Unassigned';
let phaseNumber = 'X';
const counters = new Map();
const items = [];
for (const [index, line] of read(workPlanPath).split(/\r?\n/).entries()) {
  const heading = line.match(/^## Phase (\d+)\s+(.+)$/);
  if (heading) { phaseNumber = heading[1]; phase = `Phase ${heading[1]} ${heading[2]}`; }
  const checkbox = line.match(/^(\s*)- \[([x ])\] (.+)$/);
  if (!checkbox) continue;
  const counter = (counters.get(phaseNumber) ?? 0) + 1;
  counters.set(phaseNumber, counter);
  const text = checkbox[3].replace(/;$/, '').trim();
  const rawId = explicitId(text) ?? `WP-P${phaseNumber}-${String(counter).padStart(3, '0')}`;
  const id = items.some(item => item.id === rawId) ? `${rawId}-${counter}` : rawId;
  const specEvidence = evidence(text, ['docs/specs/', '.kiro/specs/'], 1);
  const implementationEvidence = evidence(text, ['backend/migrations/', 'backend/src/domains/', 'backend/src/services/'], 2);
  const apiEvidence = evidence(text, ['backend/src/routes/', 'backend/src/controllers/'], 2);
  const clientEvidence = evidence(text, ['frontend/src/', 'mobile/'], 2);
  const testEvidence = evidence(text, ['backend/src/tests/', 'backend/tests/', 'frontend/src/', 'frontend/e2e/', 'mobile/'], 2).filter(path => /test|spec|e2e/i.test(path));
  const opsEvidence = evidence(text, ['docs/runbooks/', 'docs/'], 2).filter(path => /runbook|rollback|recovery|deployment|credentials|readiness/i.test(path));
  const isFoundation = ['0','1','8'].includes(phaseNumber);
  const clientRequired = !isFoundation && !/migration|schema|account purpose|audit export|reconciliation|worker|adapter|foundation/i.test(text);
  const apiRequired = !/specification|approve|migration|cutover|schema|runbook|ci|test|secret|architecture decision/i.test(text);
  const layers = {
    specification: specEvidence.length ? 'evidence_found' : 'missing',
    implementation: implementationEvidence.length ? 'evidence_found' : 'missing',
    api: apiRequired ? (apiEvidence.length ? 'evidence_found' : 'missing') : 'not_required',
    client: clientRequired ? (clientEvidence.length ? 'evidence_found' : 'missing') : 'not_required',
    tests: testEvidence.length ? 'evidence_found' : 'missing',
    operations: opsEvidence.length ? 'evidence_found' : 'missing',
  };
  const required = Object.values(layers).filter(value => value !== 'not_required');
  const evidenceComplete = required.every(value => value === 'evidence_found');
  const status = evidenceComplete && checkbox[2] === 'x' ? 'candidate_complete' : checkbox[2] === 'x' ? 'claimed_complete_evidence_gap' : implementationEvidence.length ? 'partial' : 'not_started';
  items.push({ id, phase, line: index + 1, depth: checkbox[1].length, workPlanChecked: checkbox[2] === 'x', item: text, status, layers, evidence: { specification: specEvidence, implementation: implementationEvidence, api: apiEvidence, client: clientEvidence, tests: testEvidence, operations: opsEvidence } });
}

const summary = {
  workPlanSha256: createHash('sha256').update(canonicalText(read(workPlanPath))).digest('hex'),
  total: items.length,
  checked: items.filter(item => item.workPlanChecked).length,
  candidateComplete: items.filter(item => item.status === 'candidate_complete').length,
  checkedWithEvidenceGaps: items.filter(item => item.status === 'claimed_complete_evidence_gap').length,
  partial: items.filter(item => item.status === 'partial').length,
  notStarted: items.filter(item => item.status === 'not_started').length,
};
const data = { schemaVersion: 1, summary, items };
const json = `${JSON.stringify(data, null, 2)}\n`;
const escapeCell = value => String(value).replaceAll('|', '\\|').replaceAll('\n', ' ');
const markdown = `# Version 1 Reconciliation\n\nGenerated by \`node scripts/reconcile-v1.mjs\`. Automated evidence discovery is conservative and does not constitute product-owner acceptance. \`candidate_complete\` means evidence files were found in every required layer; reviewers must still confirm behavior and approval.\n\n## Summary\n\n| Measure | Count |\n|---|---:|\n| Work-plan items | ${summary.total} |\n| Checked in work plan | ${summary.checked} |\n| Candidate complete | ${summary.candidateComplete} |\n| Checked with evidence gaps | ${summary.checkedWithEvidenceGaps} |\n| Partial | ${summary.partial} |\n| Not started | ${summary.notStarted} |\n\n## Evidence Matrix\n\n| ID | Phase | Work-plan item | Claimed | Status | Spec | Implementation | API | Client | Tests | Ops |\n|---|---|---|---:|---|---|---|---|---|---|---|\n${items.map(item => `| ${item.id} | ${escapeCell(item.phase)} | ${escapeCell(item.item)} | ${item.workPlanChecked ? 'yes' : 'no'} | ${item.status} | ${item.layers.specification} | ${item.layers.implementation} | ${item.layers.api} | ${item.layers.client} | ${item.layers.tests} | ${item.layers.operations} |`).join('\n')}\n\nExact evidence paths are stored in [V1_RECONCILIATION.json](V1_RECONCILIATION.json).\n`;

if (checkOnly) {
  const failures = [];
  if (!existsSync(jsonPath) || read(jsonPath) !== json) failures.push('docs/V1_RECONCILIATION.json is stale');
  if (!existsSync(markdownPath) || read(markdownPath) !== markdown) failures.push('docs/V1_RECONCILIATION.md is stale');
  const duplicateIds = items.filter((item, index) => items.findIndex(other => other.id === item.id) !== index).map(item => item.id);
  if (duplicateIds.length) failures.push(`duplicate reconciliation IDs: ${[...new Set(duplicateIds)].join(', ')}`);
  if (failures.length) { console.error(failures.join('\n')); process.exit(1); }
  console.log(`V1 reconciliation is current for ${items.length} work-plan items.`);
} else {
  writeFileSync(jsonPath, json);
  writeFileSync(markdownPath, markdown);
  console.log(`Reconciled ${items.length} work-plan items.`);
}
