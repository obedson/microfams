import { spawnSync } from 'node:child_process';

const acceptedExpoToolchainFindings = new Set([
  '@expo/cli',
  '@expo/metro',
  '@expo/metro-config',
  '@react-native/community-cli-plugin',
  '@react-native/virtualized-lists',
  'expo',
  'image-size',
  'metro',
  'metro-config',
  'metro-transform-worker',
  'react-native',
]);

const audit = spawnSync('npm', ['audit', '--omit=dev', '--json'], {
  encoding: 'utf8',
  maxBuffer: 20 * 1024 * 1024,
});

let report;
try {
  report = JSON.parse(audit.stdout);
} catch {
  console.error('npm audit did not return a valid JSON report.');
  if (audit.stderr) console.error(audit.stderr.trim());
  process.exit(1);
}

const actionable = Object.entries(report.vulnerabilities ?? {})
  .filter(([, finding]) => finding.severity === 'high' || finding.severity === 'critical');
const critical = actionable.filter(([, finding]) => finding.severity === 'critical');
const unexpected = actionable.filter(([name]) => !acceptedExpoToolchainFindings.has(name));

if (critical.length > 0 || unexpected.length > 0) {
  console.error('Unaccepted production dependency findings:');
  for (const [name, finding] of [...critical, ...unexpected]) {
    console.error(`- ${name}: ${finding.severity}`);
  }
  process.exit(1);
}

const accepted = actionable.map(([name]) => name).sort();
console.log(
  accepted.length === 0
    ? 'Mobile production dependency audit is clean.'
    : `Only documented Expo/Metro toolchain findings remain (${accepted.join(', ')}).`,
);
