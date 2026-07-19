# Rendering an on-disk PBIP/PBIR report to an image for an automated visual-verify loop

**Ticket:** #106 (wayfinder research). **Date:** 2026-07-19.
**Method:** every claim traced to a PRIMARY source — Microsoft Learn (via the
Learn MCP `microsoft_docs_search`/`microsoft_docs_fetch`) for the Desktop Bridge,
`exportToFile`, PBIP/PBIR docs, and Desktop command-line switches; the npm
registry API for the `@microsoft/powerbi-desktop-bridge-cli` README + published
version/date; `gh api` for the pbi-cli repo (`MinaSaad1/pbi-cli`, branch
`master`: README, `power-bi-report/SKILL.md`, `preview/renderer.py`) and pbi-tools
README; and the POC tools on disk at `../archive/cc-otel-azure/tools/`. **VERIFIED**
= read at the owning source this pass; **UNVERIFIED** = not confirmed at a primary
source, or a source-vs-source conflict is flagged.

---

## TL;DR — the answers

1. **There is a first-party, purpose-built path.** Microsoft ships the **Power BI
   Desktop Bridge** (preview) and a CLI, **`@microsoft/powerbi-desktop-bridge-cli`**
   (npm, latest **0.1.2**, published **2026-07-08**), whose stated purpose is
   *"agent workflows that edit PBIR/PBIP files, reload the open report in Desktop,
   capture screenshots, and verify rendered output."* It exposes
   `open`, `reload`, `screenshot <page-id>`, and `screenshot-all` — the last two
   emit **PNG** at Desktop fidelity. Microsoft's own **Report Authoring skill**
   (cross-tool-compatible with **Claude Code** by name) uses exactly this bridge
   as its "live Desktop verification" step. **This is the recommended path.**
   (VERIFIED)

2. **It requires Power BI Desktop running on the Windows box.** The bridge is an
   IPC named-pipe server *inside the Desktop process* — local only, no remote, no
   headless-without-Desktop. So the loop is: Desktop open (once) → edit PBIR on
   disk → `reload` → `screenshot-all`. That is fully **CLI-drivable and
   non-interactive once Desktop is up**, but Desktop must be installed and a
   report opened first. (VERIFIED)

3. **Fresh data is the one thing the loop cannot get without a human.** Our model
   is **Import mode with no cached data** (`cache.abf` is gitignored). The bridge
   has **no refresh method** — it reloads *definitions*, not data. A data refresh
   against Azure Postgres/SQL happens only inside Desktop and needs data-source
   **credentials entered once in Desktop (HITL)** plus a refresh trigger. So the
   screenshot loop verifies **layout / visual structure / formatting / theme**
   headless, and verifies **data-bound rendering only after a one-time manual
   Desktop credential+refresh** (thereafter the local `cache.abf` carries data
   across reopens). This is a genuine, LOUD prerequisite — see the final section.

4. **The cloud path (`exportToFile`) is out of scope and doesn't fit.** It renders
   true PNG/PDF/PPTX server-side, but **only for a report already published to a
   workspace backed by Premium / Embedded / Fabric capacity** (explicitly **not
   PPU** for image), and PNG needs a tenant admin setting that is **off by
   default**. No workspace, capacity, or licensing is provisioned (per ticket
   ground truth), so this path imposes exactly the Service/Fabric costs the parent
   map rules out. Keep it as a documented fallback for the day a Fabric workspace
   exists, not the loop. (VERIFIED)

5. **The schematic renderers are a cheap pre-check, not verification.** `pbi-cli
   report preview` and the POC's PBIR-Inspector produce **wireframe/bounding-box
   diagrams** of the layout (visual type + position + bindings), explicitly *"Not
   pixel-perfect Power BI rendering."* Useful as an instant, Desktop-free layout
   sanity check in the AFK authoring loop; useless for verifying what a chart
   actually looks like. (VERIFIED)

---

## The path grid (every path, even to rule it out)

| Path | On-disk only? | Needs live/fresh data? | Local vs cloud | Auth & licensing | Fidelity | Claude-Code automatable? |
|---|---|---|---|---|---|---|
| **1. Desktop Bridge CLI** (`screenshot`/`screenshot-all`) | No — needs Desktop **running** with the report open; PBIR edited on disk | Renders whatever Desktop shows; blank data unless model refreshed (HITL creds once) | **Windows-local** | None for the bridge (local named pipe); refresh needs Desktop data-source creds | **Desktop-true PNG** (this *is* Desktop rendering) | **Yes** — non-interactive once Desktop is up; JSON to stdout, built for agents |
| 1b. Desktop alone + generic window screenshot / UI automation | Needs Desktop running | Same as above | Windows-local | Same | Desktop-true, but brittle (window state, dialogs) | Possible but fragile — the Bridge CLI supersedes it; no reason to hand-roll |
| **2. pbi-tools** | Yes | n/a | Local | n/a | **No render at all** (extract/compile/deploy/watch) | N/A — cannot produce an image |
| **3. pbi-cli `report preview`** | **Yes** (pure file read) | No | Local | none (`[preview]` extra) | **Schematic HTML/SVG wireframe** — "Not pixel-perfect" | Yes, but it's a live browser server; screenshotting it verifies layout, not visuals |
| **4. Fabric/PBI REST `exportToFile`** | **No** — report must be **published** | Uses the workspace model's data (server-side) | **Cloud** | **Premium/Embedded/Fabric capacity; not PPU for image; PNG tenant setting off by default; SP or user auth** | **True render** (PNG/PDF/PPTX) | Yes (async REST + poll) **but** requires the whole Service/capacity/licensing stack we don't have |
| **5. Deneb / offline visual engine** | — | — | — | — | — | **No offline path** — Deneb is a Vega/Vega-Lite custom visual that renders *inside a Power BI visual host*; there is no standalone offline renderer for a whole PBIR page. (UNVERIFIED at a single owning source; no primary source describes an offline whole-report Deneb render) |
| **6. PBIR-Inspector / third-party renderers** | Yes | No | Local | none | **Schematic** (rules validator; any "visualize" output is a layout diagram, not a data render) | Yes for validation; not a fidelity render |

---

## 1. Power BI Desktop Bridge CLI — the recommended engine (VERIFIED)

**What it is.** A local server running *inside the Power BI Desktop process*,
speaking JSON-RPC 2.0 over a Windows **named pipe** (`pbi-desktop-bridge-{pid}`).
Transport is **local only — remote access is not supported**. Each open Desktop
window has its own pipe; only one operation runs at a time per instance.
(Learn: *What is the Power BI Desktop Bridge? (Preview)*.)

**The CLI.** `@microsoft/powerbi-desktop-bridge-cli`, npm **latest 0.1.2**,
published **2026-07-08T19:27:39Z**, description: *"CLI for Power BI Desktop Bridge
automation: discover running Desktop instances, reload PBIR reports, and capture
page screenshots over the named-pipe bridge. Public preview."* Install:
`npm install -g @microsoft/powerbi-desktop-bridge-cli`.

**Commands** (from the npm README, VERIFIED):

| Command | Purpose |
|---|---|
| `powerbi-desktop open <path.pbip\|path.pbix>` | Launch Desktop with a report |
| `powerbi-desktop status [--pid <pid>]` | List bridge instances, current files, unsaved-change state, PBIR pages |
| `powerbi-desktop manifest --pid <pid>` | Print the bridge method manifest |
| `powerbi-desktop reload --pid <pid>` | Reload the instance's current PBIP/PBIR **definition** |
| `powerbi-desktop screenshot <page-id> --pid <pid> [--scale <1-3>]` | Capture one page as PNG (CLI default scale **2**) |
| `powerbi-desktop screenshot-all --pid <pid> --output-dir <dir> [--scale <1-3>]` | Capture **every** page in the current PBIR `pages.json` |

Automation-friendly by design: *"Commands write machine-readable JSON to stdout.
Progress and diagnostics go to stderr so stdout can be piped safely."* Use
`--wait-seconds` right after a reload while the report is still rendering. Run
reload/screenshot **serially per PID**; `status` can run concurrently.

**Underlying bridge methods** (Learn, VERIFIED): `bridge.manifest`,
`application.state.get/v1` (current file + `hasUnsavedChanges`),
`report.snapshot.capture/v1` (params `pageId`, optional `scale` 1.0–3.0; returns
base64 PNG + `pageDisplayName`), `file.reload/v1` (param `reloadModelDefinition`,
default true).

**Prerequisites** (Learn, VERIFIED):
- **Power BI Desktop installed** on the Windows machine.
- Preview feature **"Enable external tool access to Power BI Desktop through
  secure local APIs"** — **on by default** (File > Options and Settings > Options
  > Preview Features).
- The bridge/skill work only with **PBIP** files, and **the PBIR file on disk is
  the source of truth** — unsaved Desktop edits are ignored by an agent that
  reads PBIR (Learn: Report Authoring skill, *Considerations*).

**Fresh-data reality (decisive).** `report.snapshot.capture` screenshots *what
Desktop is currently rendering*. `file.reload` re-applies **definitions**, not a
data refresh — there is **no refresh verb in the bridge or CLI**. Our Import
model has no cached data on a clean checkout (`cache.abf` gitignored), so a first
open renders visual **chrome/layout/format/theme** but empty data regions. To get
data you must, **in Desktop**: (a) enter Azure Postgres/SQL data-source
credentials once (one-time, HITL, cached per machine), and (b) trigger a refresh.
After that, `cache.abf` persists data locally across reopens. **The bridge cannot
produce a data-populated screenshot on a fresh machine without that one-time human
step.** (Learn Desktop Bridge methods + PBIP `.gitignore` = `cache.abf`,
VERIFIED.)

**First-party precedent.** Learn's **Report Authoring skill**
(`powerbi-report-authoring`, in `microsoft/skills-for-fabric`) lists its verify
step as *"Use the Power BI Desktop bridge to reload Desktop and capture
screenshots"* and states the skill is *"optimized for GitHub Copilot CLI with
cross-tool compatibility for VS Code Copilot, **Claude Code**, Cursor, Codex/Jules,
and Windsurf."* i.e. Microsoft designed this exact loop for an agent like ours.
Both the bridge and the skill are **preview**.

---

## 2. pbi-tools — no image render (VERIFIED)

pbi-tools is *"a command-line tool bringing source-control features to Power BI"*
— **extract / compile / deploy / watch**. Its README has **no** mention of
render, screenshot, image, or preview. Confirmed *not* a rendering path; it does
not belong in the loop.

---

## 3. pbi-cli `report preview` — schematic only (VERIFIED)

`pbi report preview` (needs `pip install pbi-cli-tool[preview]`) *"Opens a browser
showing all pages with visual placeholders, types, positions, and data bindings.
The preview auto-refreshes when files change."* The renderer's own docstring:
*"PBIR JSON to HTML/SVG renderer. Renders a simplified structural preview... **Not
pixel-perfect Power BI rendering** — shows layout, visual types, and field
bindings for validation before opening in Desktop."* Visuals are drawn as colored
bounding boxes keyed by type.

**Verdict:** a fast, Desktop-free **layout/wiring sanity check** that fits the AFK
authoring loop (catches overlaps, wrong positions, missing bindings) — but it
renders *no data and no real visual*, so it cannot verify what a chart looks like.
Complementary to, not a substitute for, the Desktop Bridge screenshot.

---

## 4. Fabric / Power BI REST `exportToFile` — the cloud fallback, out of scope now (VERIFIED)

The `exportToFile` API renders a **published** Power BI report server-side to
**.pptx / .pdf / .png** (multi-page PNG returns a `.zip`, one PNG per page,
page names from Get Pages). Asynchronous: trigger → poll `getExportToFileStatus`
→ `getFileOfExportToFile` (URL valid 24 h).

**Hard prerequisites (Learn, VERIFIED):**
- Report must **reside in a workspace backed by Premium, Embedded, or Fabric
  capacity**. **Not supported for PPU** (for image export).
- Admin **tenant settings**: *"Export reports as PowerPoint presentations or PDF
  documents"* is on by default; **"Export reports as image files"** (required for
  **PNG**) is **disabled by default**.
- Auth via a **user/master user or a service principal**.
- Use the *Rendering* events API so export waits until visuals finish rendering.

**Verdict:** true-fidelity and fully unattended **once the report is published to a
capacity-backed workspace** — but that entire stack (workspace + Premium/Embedded/
Fabric capacity + tenant-setting change + SP) is **not provisioned** and is the
exact Service/Fabric cost the parent map excludes. **Fallback only**, to revisit
if/when the report is published to a real Fabric workspace. If chosen, it would
give fresh data automatically (it renders the workspace model, which can be on a
refresh schedule) — the one scenario that solves the fresh-data problem headless,
at the price of the whole cloud footprint.

---

## 5. Deneb / offline visual render (UNVERIFIED — no offline whole-report path)

Deneb is a **Vega / Vega-Lite custom visual that runs inside the Power BI visual
host**; it renders only within a Desktop/Service visual container. No primary
source describes a standalone engine that renders a PBIR page (or a Deneb visual)
to an image **without** Power BI. Vega-Lite has its own CLI renderers, but that
would mean re-implementing each visual's spec by hand — not a report-fidelity path
and not worth pursuing. Ruled out for the loop.

---

## 6. PBIR-Inspector & the POC tools on disk (VERIFIED on disk; repo UNVERIFIED this pass)

The POC vendored (`../archive/cc-otel-azure/tools/`):
- **`pbi-inspector/`** — PBIR-Inspector, a **rules-based validator** (`Base-rules.json`,
  `Reid-rules.json` in JsonLogic `pbiEntries`/`pbixEntryPath` form; `win-x64-CLI.zip`).
  Same family as fab-inspector: it checks the PBIR JSON against declarative rules
  and writes a `TestRun_*.json` report. Any layout "visualize" output it has is a
  **schematic diagram**, not a data render. *(The `NatVanG/PBIR-Inspector` repo
  returned 404 via `gh api`/`gh search` this pass — likely renamed/moved/private;
  its render capability is therefore **UNVERIFIED at source**, but the vendored
  copy is a validator, not a fidelity renderer.)*
- **`pbir-validator/`** — a local **ajv** JSON-schema validator
  (`validate-pbir.mjs`) that walks the `.Report` folder and validates every
  `.json` against its `$schema`. Pure validation, no render.
- **`fab-inspector/`, `tabular-editor/`** — validation/BPA, no render.

**Verdict:** these are the **validation triad** (schema + rules + BPA) already
covered in `docs/research/dev-tooling-stack.md` and `pbi-cli-visual-authoring.md`.
They belong *before* the screenshot in the loop; none render Desktop-fidelity
images.

---

## RECOMMENDED verification-loop approach

**Primary: the Power BI Desktop Bridge CLI screenshot loop, on the Windows dev
box.** It is first-party, purpose-built for agent verify loops, explicitly
Claude-Code-compatible, and the *only* path that gives **Desktop-true** images
without publishing to a cloud capacity we don't have.

**The loop (Claude Code drives all of this non-interactively, except the one-time
setup flagged below):**

1. `npm install -g @microsoft/powerbi-desktop-bridge-cli` (once per machine).
2. **[HITL, once]** Open `powerbi/cc-otel-report.pbip` in Power BI Desktop and,
   when prompted, **enter the Azure Postgres + Azure SQL data-source credentials
   and run a data Refresh.** This is unavoidable for *data-populated* screenshots:
   our model is Import mode with no cached data, and the bridge has no refresh
   verb. After this, Desktop caches data in the (gitignored) `cache.abf`.
   *(If only layout/formatting/theme verification is needed, this step can be
   skipped — visuals still render their chrome; data regions will be empty.)*
3. `powerbi-desktop status` → capture the `--pid` of the running instance (and the
   PBIR page IDs). (Or `powerbi-desktop open <pbip>` to launch it.)
4. Agent edits PBIR on disk (via the existing pbi-cli offline Report layer, #95).
5. `powerbi-desktop reload --pid <pid>` to pull the on-disk edits into Desktop.
6. *(optional fast pre-check)* `pbi report preview` for an instant layout/wiring
   wireframe before spending a Desktop render.
7. `powerbi-desktop screenshot-all --pid <pid> --output-dir <dir> --scale 2`
   → PNGs (one per page), use `--wait-seconds` if just reloaded.
8. Claude Code **reads the PNGs** and visually verifies its own authoring; loop to
   step 4 until correct.

**Ordered prerequisites this imposes:**
1. **Power BI Desktop installed** on the Windows dev machine. **[HITL — Ahmed must
   install it]**
2. Node.js + `npm i -g @microsoft/powerbi-desktop-bridge-cli`. (Agent-doable.)
3. Preview feature *"Enable external tool access to Power BI Desktop through secure
   local APIs"* — **on by default**; confirm it wasn't disabled. **[HITL check]**
4. **One-time in Desktop: data-source credentials for Azure Postgres (`marts`) +
   Azure SQL (employee dim), then a Refresh** — required only for data-populated
   screenshots. **[HITL — cannot be done headless]**
5. A running Desktop instance with the report open before `reload`/`screenshot`.

**HITL flags (state plainly):**
- **Install Power BI Desktop?** — **Yes**, one-time, Ahmed.
- **Provision a workspace / Fabric / PPU / capacity?** — **No** (that's the
  fallback path only).
- **Service principal?** — **No** for the primary path.
- **Enable an export tenant setting?** — **No** for the primary path.
- **Data-source credentials in Desktop + a Refresh** — **Yes, one-time, HITL.**

**Can the recommended loop get fresh data without a human? — No, not on a clean
machine.** The Desktop Bridge screenshots what Desktop renders and has **no data-
refresh capability**; our Import model ships with no cached data. Data-populated
verification therefore requires a **one-time human credential entry + Refresh in
Desktop**; after that, reopens reuse the local `cache.abf` and the loop runs
unattended. **Layout / structure / formatting / theme verification needs no data
and is fully headless immediately.** The only way to get *fresh data on every run
with zero human involvement* is the cloud `exportToFile` fallback, which costs the
full workspace + Premium/Embedded/Fabric-capacity + tenant-setting + SP stack.

**Fallback: Fabric/PBI REST `exportToFile`.** Adopt only once the report is
published to a workspace on Premium/Embedded/Fabric capacity. It renders true
PNG/PDF unattended with automatically fresh (schedule-refreshed) data, at the
price of that entire cloud footprint — including flipping the **"Export reports as
image files"** tenant setting (off by default) for PNG, and **not** working on
PPU.

**Caveats to carry into #108:** the Desktop Bridge and the Report Authoring skill
are both **preview** (API surface may change; CLI is v0.1.2). PBIR itself is still
labelled preview on Learn. Pin the CLI version and re-verify command surface
before wiring it into a routine.

---

## Sources (primary)

- **Microsoft Learn** (via Learn MCP):
  - *What is the Power BI Desktop Bridge? (Preview)* — `power-bi/developer/agentic/power-bi-desktop-bridge-overview` (bridge methods, prerequisites, CLI command table, named-pipe/local-only transport).
  - *What is the Power BI Report Authoring skill?* — `power-bi/developer/agentic/power-bi-report-authoring-skill-overview` (verify-via-bridge loop; Claude Code compatibility; PBIR-is-source-of-truth considerations).
  - *Export Power BI report to file* — `power-bi/developer/embedded/export-to` (PNG/PDF/PPTX; capacity + PPU-not-supported; PNG tenant setting off by default; async polling; SP auth).
  - *Power BI Desktop projects (PREVIEW)* / *project report folder* — `power-bi/developer/projects/projects-overview`, `.../projects-report` (PBIP/PBIR layout; `.gitignore` = `cache.abf`, `localSettings.json`; `byPath` opens model in edit mode).
  - *Download Power BI Desktop* — `power-bi/fundamentals/desktop-get-the-desktop` (install-time command-line switches only; no report-open render switch).
- **npm registry API**: `registry.npmjs.org/@microsoft/powerbi-desktop-bridge-cli` — latest **0.1.2**, published **2026-07-08**, full README (command table, `--pid`/`--scale`/`--wait-seconds`, JSON-to-stdout).
- **`gh api`**: `MinaSaad1/pbi-cli` `master` — README, `src/pbi_cli/skills/power-bi-report/SKILL.md` (`report preview` = live HTML wireframe), `src/pbi_cli/preview/renderer.py` (docstring: "Not pixel-perfect Power BI rendering").
- **pbi-tools** README (`pbi-tools/pbi-tools`) — extract/compile/deploy; no render.
- **Repo / disk**: `../archive/cc-otel-azure/tools/pbi-inspector/` (PBIR-Inspector rules validator, `Base-rules.json`, `win-x64-CLI.zip`), `.../pbir-validator/validate-pbir.mjs` (ajv schema validator); `docs/research/pbi-cli-visual-authoring.md` (offline PBIR authoring layer, #95).
