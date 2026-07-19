// Validate every Power BI project file that declares a Microsoft Fabric JSON
// `$schema` against that schema. ajv fetches each declared schema and its `$ref`
// closure over HTTP (relative refs resolve against each schema's absolute `$id`),
// so every file is checked against the exact schema version it pins — the gate
// never drifts as the report/model gain pages or bump schema versions.
//
// Usage: node .github/powerbi/validate-pbir.mjs [rootDir]   (default: powerbi)
import { readFile, readdir } from 'node:fs/promises';
import { join, extname } from 'node:path';
import Ajv from 'ajv';

const FABRIC_PREFIX = 'https://developer.microsoft.com/json-schemas/fabric/';
const ROOT = process.argv[2] ?? 'powerbi';
const EXTS = new Set(['.json', '.pbir', '.pbip', '.pbism']);

async function walk(dir, out = []) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    // `.pbi/` holds per-machine Power BI Desktop local settings — gitignored, so
    // absent from the CI checkout, and it can declare unpublished `$schema`
    // versions that 404. Never a validation target; skip it so a local run
    // mirrors CI.
    if (entry.isDirectory()) {
      if (entry.name === '.pbi') continue;
      await walk(p, out);
    } else if (EXTS.has(extname(entry.name))) out.push(p);
  }
  return out;
}

// ajv only calls loadSchema for refs it hasn't already registered, so this cache
// dedupes concurrent $ref loads across the per-file compiles.
const FETCH_TIMEOUT_MS = 15_000;
const fetchCache = new Map();
const loadSchema = (uri) => {
  if (!fetchCache.has(uri)) {
    fetchCache.set(uri, (async () => {
      const res = await fetch(uri, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
      if (!res.ok) throw new Error(`fetch ${uri} -> HTTP ${res.status}`);
      return res.json();
    })());
  }
  return fetchCache.get(uri);
};

const ajv = new Ajv({ strict: false, allErrors: true, loadSchema });
const validators = new Map();
const validatorFor = async (schemaUrl) => {
  if (!validators.has(schemaUrl)) {
    validators.set(schemaUrl, await ajv.compileAsync(await loadSchema(schemaUrl)));
  }
  return validators.get(schemaUrl);
};

const files = await walk(ROOT);
let checked = 0;
let failed = 0;
for (const file of files.sort()) {
  let data;
  try {
    data = JSON.parse(await readFile(file, 'utf8'));
  } catch (err) {
    // Every collected extension must be valid JSON — a parse failure is a broken
    // report/model file, so fail the gate rather than silently skipping it.
    failed++;
    console.error(`✗ ${file}`);
    console.error(`    invalid JSON: ${err.message}`);
    continue;
  }
  const schemaUrl = data?.$schema;
  // Exact prefix (not substring) so only Microsoft's Fabric schema host is fetched.
  if (typeof schemaUrl !== 'string' || !schemaUrl.startsWith(FABRIC_PREFIX)) continue;
  const validate = await validatorFor(schemaUrl);
  checked++;
  if (validate(data)) {
    console.log(`✓ ${file}`);
  } else {
    failed++;
    console.error(`✗ ${file}`);
    for (const err of validate.errors) {
      console.error(`    ${err.instancePath || '/'} ${err.message}`);
    }
  }
}

console.log(`\nPBIR schema validation: ${checked} file(s) checked, ${failed} failed.`);
if (checked === 0) {
  console.error('No Fabric-schema files found to validate — check the root path.');
  process.exit(1);
}
process.exit(failed ? 1 : 0);
