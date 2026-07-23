// Fails the gate on real PII persisted into a page.json filter
// ("standards enforced by config, not prose" -- CLAUDE.md). Power BI Desktop
// re-serializes the last-used drillthrough value into the on-disk Passthrough
// filter, so a real email or session-id UUID keeps landing in git on every save
// (issue #183). The canonical drill wiring carries no persisted `filter` block
// at all, so a clean report has nothing to match. Scans every persisted filter
// literal (not just the drillthrough one) so a re-persist under any `howCreated`
// is caught too -- the report has no other page-level filter literals.
//
// Pure Node (no deps). Usage: node .github/powerbi/drill-pii-lint.mjs [reportDir]
//   default reportDir: powerbi/cc-otel-report.Report
// Exit: 0 clean · 1 PII found · 2 walk/parse infrastructure failure
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';

const ROOT = process.argv[2] ?? 'powerbi/cc-otel-report.Report';

const EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const UUID_RE = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/;

const violations = [];

async function walk(dir, out = []) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === '.pbi') continue;
      await walk(p, out);
    } else if (entry.name === 'page.json') {
      out.push(p);
    }
  }
  return out;
}

// Every `Literal.Value` string reachable inside a filter object.
function collectLiterals(node, acc) {
  if (Array.isArray(node)) {
    for (const item of node) collectLiterals(item, acc);
  } else if (node && typeof node === 'object') {
    if (node.Literal && typeof node.Literal.Value === 'string') acc.push(node.Literal.Value);
    for (const v of Object.values(node)) collectLiterals(v, acc);
  }
  return acc;
}

function checkPage(file, data) {
  const filters = data?.filterConfig?.filters;
  if (!Array.isArray(filters)) return;
  for (const f of filters) {
    for (const value of collectLiterals(f, [])) {
      if (EMAIL_RE.test(value)) {
        violations.push({ file, filter: f.name, value, kind: 'email' });
      } else if (UUID_RE.test(value)) {
        violations.push({ file, filter: f.name, value, kind: 'session-id UUID' });
      }
    }
  }
}

let files;
try {
  files = await walk(ROOT);
} catch (e) {
  console.error(`[TOOL] cannot walk ${ROOT}: ${e.message}`);
  process.exit(2);
}

for (const file of files) {
  let data;
  try {
    data = JSON.parse(await readFile(file, 'utf8'));
  } catch (e) {
    console.error(`[TOOL] cannot parse ${file}: ${e.message}`);
    process.exit(2);
  }
  checkPage(file, data);
}

if (violations.length) {
  for (const v of violations) {
    console.error(`::error file=${v.file}::filter "${v.filter}" persists real ${v.kind}: ${v.value} -- reset the filter value (issue #183)`);
  }
  console.error(`\ndrill-pii-lint: ${violations.length} PII value(s) found in persisted page filters`);
  process.exit(1);
}

console.log(`drill-pii-lint: clean (${files.length} page.json scanned)`);
process.exit(0);
