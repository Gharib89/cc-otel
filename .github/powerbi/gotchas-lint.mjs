// Statically checkable PBIR traps from the pbir-gotchas skill, enforced as a
// gate ("standards enforced by config, not prose" — CLAUDE.md). Each rule cites
// its gotcha number; the judgment/runtime-only traps stay in the skill.
//
// Pure Node (no deps). Usage: node .github/powerbi/gotchas-lint.mjs [reportDir]
//   default reportDir: powerbi/cc-otel-report.Report
// Exit: 0 clean · 1 violations found · 2 walk/parse infrastructure failure
import { readFile, readdir } from 'node:fs/promises';
import { join, basename, dirname, sep } from 'node:path';

const ROOT = process.argv[2] ?? 'powerbi/cc-otel-report.Report';
const NAME_RE = /^[a-zA-Z0-9_-]+$/;
const BUTTON_STATE_IDS = new Set(['default', 'hover', 'selected', 'disabled', 'pressed']);
// G11: theme visualStyles don't cascade across these chart subtypes.
const SUBTYPE_OF = {
  clusteredBarChart: 'barChart',
  clusteredColumnChart: 'columnChart',
  pivotTable: 'matrix',
};

const violations = [];
const flag = (file, rule, msg) => violations.push({ file, rule, msg });

async function walk(dir, out = []) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === '.pbi') continue;
      // G7: PBIR folder names are [a-zA-Z0-9_-]+ (Desktop's convention).
      if (!NAME_RE.test(entry.name)) flag(p, 'G7', `folder name violates [a-zA-Z0-9_-]+`);
      await walk(p, out);
    } else if (entry.name.endsWith('.json')) out.push(p);
  }
  return out;
}

const literalOf = (prop) => prop?.expr?.Literal?.Value;

// G22 model awareness: parse the sibling SemanticModel's TMDL into a per-table
// {columns, measures} catalog so we can tell a real measure from a column that
// was wrongly wrapped as one. Returns null when no model is found beside ROOT
// (the rule then no-ops — it can't run without the model).
const tmdlName = (raw) => raw.replace(/^'(.*)'$/, '$1');
async function loadModelCatalog(root) {
  let siblings;
  try {
    siblings = await readdir(dirname(root), { withFileTypes: true });
  } catch {
    return null;
  }
  const model = siblings.find((e) => e.isDirectory() && e.name.endsWith('.SemanticModel'));
  if (!model) return null;
  const tablesDir = join(dirname(root), model.name, 'definition', 'tables');
  let tmdlFiles;
  try {
    tmdlFiles = (await readdir(tablesDir)).filter((n) => n.endsWith('.tmdl'));
  } catch {
    return null;
  }
  const catalog = new Map(); // entity -> { columns: Set, measures: Set }
  for (const name of tmdlFiles) {
    const text = await readFile(join(tablesDir, name), 'utf8');
    let entry = null;
    for (const line of text.split('\n')) {
      const table = line.match(/^table\s+(?:'([^']+)'|(\S+))/);
      if (table) {
        entry = { columns: new Set(), measures: new Set() };
        catalog.set(tmdlName(table[1] ?? table[2]), entry);
        continue;
      }
      if (!entry) continue;
      const col = line.match(/^\s+column\s+(?:'([^']+)'|([^\s=]+))/);
      if (col) { entry.columns.add(tmdlName(col[1] ?? col[2])); continue; }
      const meas = line.match(/^\s+measure\s+(?:'([^']+)'|([^\s=]+))/);
      if (meas) entry.measures.add(tmdlName(meas[1] ?? meas[2]));
    }
  }
  return catalog;
}

// G22: a numeric column wrapped as { "Measure": {...} } (implicit-aggregation
// form) is a hard field error on live data in tableEx — invisible to the static
// legs and to Desktop until it hits real rows. Any Measure field whose Property
// is a known column (and not a measure) of its entity is the trap.
function checkImplicitMeasure(file, node, catalog) {
  if (Array.isArray(node)) {
    for (const item of node) checkImplicitMeasure(file, item, catalog);
    return;
  }
  if (!node || typeof node !== 'object') return;
  const m = node.Measure;
  const entity = m?.Expression?.SourceRef?.Entity;
  const prop = m?.Property;
  if (entity && prop) {
    const t = catalog.get(entity);
    if (t && t.columns.has(prop) && !t.measures.has(prop)) {
      flag(file, 'G22', `${entity}.${prop} is a column projected as a Measure — a runtime field error; use { "Column": {...} } (or an Aggregation wrapper for implicit agg)`);
    }
  }
  for (const value of Object.values(node)) checkImplicitMeasure(file, value, catalog);
}

// G1: "Drillthrough" is a pageBinding type, never a filter type.
function checkFilters(file, data) {
  for (const f of data?.filterConfig?.filters ?? []) {
    if (f?.type === 'Drillthrough') {
      flag(file, 'G1', `filter type "Drillthrough" is invalid — drillthrough filters use type "Passthrough"`);
    }
  }
}

function checkVisual(file, data, catalog) {
  const v = data?.visual;
  if (!v) return;
  const type = v.visualType;
  const objects = v.objects ?? {};
  const vco = v.visualContainerObjects ?? {};

  checkFilters(file, data);
  if (catalog) checkImplicitMeasure(file, v.query, catalog);

  // G4/G16: visualLink placement — only actionButton/pageNavigator carry it,
  // and only under visualContainerObjects.
  if (objects.visualLink) {
    flag(file, 'G4', `visualLink under objects — it must live under visualContainerObjects`);
  }
  if (type === 'textbox' && (vco.visualLink || objects.visualLink)) {
    flag(file, 'G16', `textbox has no visualLink — use actionButton or pageNavigator for nav`);
  }

  // G10: a card renders exactly one Values projection.
  if (type === 'card') {
    const projections = v.query?.queryState?.Values?.projections ?? [];
    if (projections.length > 1) {
      flag(file, 'G10', `card has ${projections.length} Values projections — use multiRowCard or split into two cards`);
    }
    // G19: wordWrap is its own formatting object, not a labels property.
    for (const entry of objects.labels ?? []) {
      if (entry?.properties && 'wordWrap' in entry.properties) {
        flag(file, 'G19', `wordWrap inside labels — it is its own formatting object ("wordWrap": [...])`);
      }
    }
  }

  // G13: shape fill doesn't render — panels use actionButton fill, thin bars
  // use visualContainerObjects.background (G17).
  if (type === 'shape') {
    for (const entry of objects.fill ?? []) {
      const props = entry?.properties ?? {};
      if ('fillColor' in props || literalOf(props.show) === 'true') {
        flag(file, 'G13', `shape objects.fill doesn't render — use actionButton fill (>=10px panels) or visualContainerObjects.background (thin bars)`);
      }
    }
  }

  if (type === 'actionButton') {
    const height = data?.position?.height;
    // The two-entry show/selector contract covers the per-state styling cards
    // (skill gotcha 14); cards like `shape` hold card-level props selector-less.
    const STATED_CARDS = new Set(['text', 'fill', 'outline', 'icon']);
    for (const [card, entries] of Object.entries(objects)) {
      if (!STATED_CARDS.has(card) || !Array.isArray(entries)) continue;
      for (const entry of entries) {
        const props = entry?.properties ?? {};
        const keys = Object.keys(props);
        const hasShow = keys.includes('show');
        const styleKeys = keys.filter((k) => k !== 'show');
        const selectorId = entry?.selector?.id;
        // G14: `show` is a card-level switch (no selector); styling needs
        // selector.id = a valid state. Both directions fail silently at render.
        if (hasShow && selectorId !== undefined) {
          flag(file, 'G14', `${card}: "show" inside a selector entry disables the whole formatting bag — move it to its own selector-less entry`);
        }
        if (styleKeys.length > 0 && selectorId === undefined) {
          flag(file, 'G14', `${card}: styling (${styleKeys.join(', ')}) without selector.id — it is silently ignored; add "selector": {"id": "default"}`);
        }
        if (selectorId !== undefined && !BUTTON_STATE_IDS.has(selectorId)) {
          flag(file, 'G14', `${card}: selector id "${selectorId}" is not a button state (${[...BUTTON_STATE_IDS].join(', ')})`);
        }
        // G17: actionButton fill renders nothing below ~4px height.
        if (card === 'fill' && typeof height === 'number' && height < 4
            && ('fillColor' in props || literalOf(props.show) === 'true')) {
          flag(file, 'G17', `actionButton fill at height ${height}px renders nothing below ~4px — use shape + visualContainerObjects.background`);
        }
      }
    }
  }
}

// G11 + G18 over a theme's visualStyles; needs the set of visual types the
// report actually uses (G11 only fires when the unstyled subtype is in use).
function checkTheme(file, data, usedTypes) {
  const styles = data?.visualStyles ?? {};
  for (const [subtype, parent] of Object.entries(SUBTYPE_OF)) {
    if (styles[parent] && !styles[subtype] && usedTypes.has(subtype)) {
      flag(file, 'G11', `visualStyles.${parent} doesn't cascade to ${subtype} (used by the report) — mirror the style into visualStyles.${subtype}`);
    }
  }
  for (const [type, selectors] of Object.entries(styles)) {
    for (const cards of Object.values(selectors ?? {})) {
      for (const [cardName, entries] of Object.entries(cards ?? {})) {
        if (!Array.isArray(entries)) continue;
        for (const entry of entries) {
          for (const [prop, value] of Object.entries(entry ?? {})) {
            // G18: colors are {solid: {color: ...}} objects, not bare hex.
            if (typeof value === 'string' && /^#[0-9a-fA-F]{3,8}$/.test(value)) {
              flag(file, 'G18', `visualStyles.${type} ${cardName}.${prop}: bare "${value}" — colors are objects ({"solid":{"color":"${value}"}})`);
            }
            // G18: fontFace is textClasses-only; visualStyles cards use fontFamily.
            if (prop === 'fontFace') {
              flag(file, 'G18', `visualStyles.${type} ${cardName}.fontFace — use fontFamily (fontFace is only valid in textClasses)`);
            }
          }
        }
      }
    }
  }
}

let files;
try {
  files = await walk(ROOT);
} catch (err) {
  console.error(`cannot walk ${ROOT}: ${err.message}`);
  process.exit(2);
}

const parsed = [];
for (const file of files.sort()) {
  try {
    parsed.push([file, JSON.parse(await readFile(file, 'utf8'))]);
  } catch {
    continue; // broken JSON is the ajv leg's finding, not this one's
  }
}

const usedTypes = new Set(
  parsed.map(([, d]) => d?.visual?.visualType).filter(Boolean),
);

const catalog = await loadModelCatalog(ROOT);

for (const [file, data] of parsed) {
  const name = basename(file);
  if (name === 'visual.json') checkVisual(file, data, catalog);
  else if (name === 'page.json') checkFilters(file, data);
  else if (data?.visualStyles || data?.textClasses) checkTheme(file, data, usedTypes);
}

for (const v of violations) {
  console.error(`x ${v.file.split(sep).join('/')}`);
  console.error(`    [${v.rule}] ${v.msg}`);
}
console.log(`\npbir-gotchas lint: ${parsed.length} file(s) checked, ${violations.length} violation(s).`);
process.exit(violations.length ? 1 : 0);
