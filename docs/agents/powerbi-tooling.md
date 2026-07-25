# Power BI authoring tooling

The installed set for authoring the `powerbi/` report **on disk** (PBIP / PBIR /
TMDL), decided in issue #107 from the research in
`docs/research/pbi-tooling-landscape.md`. On-disk PBIP is the source of truth;
there is no live Analysis Services connection in the loop; publishing is a manual
Power BI Desktop step.

## Roster

| Tool | Role | Install |
|---|---|---|
| **pbi-cli** v3.11.1 (MinaSaad1, MIT) | The authoring engine: offline PBIR Report-layer edits (visuals, pages, filters, themes, bookmarks) with `--no-sync` | `uv tool install --prerelease=allow pbi-cli-tool==3.11.1`, then `pbi-cli skills install` and keep only the 6 offline Report skills (see below) |
| **data-goblin `pbip` plugin** (GPL-3.0) | On-disk format reference: `pbip`, `pbir-format`, `tmdl` skills | Enabled in `.claude/settings.json`, marketplace pinned to tag `v26.25` |
| **data-goblin `reports` plugin** (GPL-3.0) | Design canon: the `pbi-report-design` skill (3-30-300, layout, accessibility) | Same marketplace; on-demand (see "Design canon" below) |
| **`pbir-gotchas` skill** (project-native) | 16 cc-otel PBIR format traps not covered by `pbir-format` | Lives in `.claude/skills/pbir-gotchas/`; source of truth is this repo |
| **`.github/powerbi/validate.ps1`** | Local mirror of the `ci-powerbi` gate — the edit-then-validate loop | In-repo; downloads its own pinned validators on first run |
| **@microsoft/powerbi-report-authoring-cli** v0.1.4 (MIT, preview) | PBIR conformance check, **blocking** (promoted by #112) | Runs via `npx` as validate.ps1 leg 4 and a `pbir-schema` CI step |

**Install traps:** `--prerelease=allow` is **required** — 3.11.1 depends on
`pythonnet==3.1.0rc0`, and without the flag `uv` silently resolves back to 3.10.10.
And `pbi-cli --version` misreports **3.10.10** even on a correct 3.11.1 install
(stale hardcoded version string upstream); trust `uv tool list` (shows `v3.11.1`),
not `--version`.

**Plugin-pin trap:** the `.claude/settings.json` marketplace declaration installs
nothing by itself (fresh machine → `Skill` tool fails "Unknown skill"), and
`claude plugin install` clones the marketplace at default-branch HEAD, **ignoring
the `ref: v26.25` pin** (26.26+ is a known breaking window, #105). Fresh-machine
sequence: `claude plugin marketplace add`, then `git checkout v26.25` inside
`~/.claude/plugins/marketplaces/power-bi-agentic-development`, then `claude plugin
uninstall` + `install` for both plugins — "already installed" won't repoint the
version; only a reinstall updates `installed_plugins.json` to the pinned cache
path. Registered Skill invocation needs `/reload-plugins` or a new session.

## pbi-cli skills — keep offline, drop live

`pbi-cli skills install` registers 13 skills. This repo has no live Desktop/AS
connection in the loop, so **keep the 6 offline Report-layer skills** (Report,
Visuals, Pages, Themes, Filters, Custom Visuals) and **uninstall the 7 live ones**
(DAX, Modeling, Deployment, Security, Docs, Partitions, Diagnostics) so they don't
trigger against a connection that isn't there. Semantic-model measures are edited
directly in the TMDL folder on disk — no `pbi connect`.

Known pbi-cli gaps: no drillthrough authoring (hand-write `pageBinding` or set it
once in Desktop — see `pbir-gotchas` trap 1); emits `visualContainer` schema
`2.7.0` while Desktop's baseline is `2.9.0` (both ajv-valid against their own
`$schema`); `report set-theme` writes report.json **invalid** against
report/3.3.0 — `customTheme.reportVersionAtImport` as a string instead of a
`{visual,page,report}` object, and the RegisteredResources item `type` as int
`202` with a wrong `path` (must be string `"CustomTheme"` with a
resource-folder-relative path, just `theme.json`). Hand-fix after `set-theme`;
the ajv gate catches it.

## Design canon — on-demand

The `reports` plugin's `pbi-report-design` skill is available but kept
**invoke-on-demand**: its short description sits in context, its body loads only
when invoked, so it costs nothing per turn until the redesign needs it. If it ever
starts auto-firing unhelpfully, gate it harder with a `skillOverrides` entry
(`"pbi-report-design": "user-invocable-only"`) in `.claude/settings.json`.

The `reports` plugin also ships `pbir-cli` / `create-pbi-report` skills that route
through the **rejected** pbir-cli (non-commercial license + no linux wheel — see
Rejected below). Do not use them; author with pbi-cli instead.

## validate.ps1 — the local gate

```powershell
pwsh .github/powerbi/validate.ps1
```

Runs the same checks as the `ci-powerbi` gate on the same pinned versions
(ajv 8.17.1, fab-inspector v3.4.0, Tabular Editor 2 2.28.0) and the same rule
files in `.github/powerbi/`. It runs the **Windows** fab-inspector binary where
CI runs the linux one, and runs everything on one machine where CI splits
ajv+fab-inspector onto ubuntu and TE2 onto windows — same versions, same rules. fab-inspector and TE2 are cached under `.pbi-tools/`
(gitignored) and reused; the ajv leg installs into a gitignored `node_modules/`
in the repo root (`--no-package-lock`, so the tree stays clean). A fourth leg
runs the Microsoft conformance CLI — **blocking** since #112 promoted it (it
catches role/theme defects that render silently wrong past the other three). A
fifth leg (#135) runs `gotchas-lint.mjs` — the statically checkable
`pbir-gotchas` skill traps as lint rules (pure node, no deps).

**Exit-code contract** (the single source of truth for it):

- `0` clean
- `1` a validation error (a report/model bug)
- `2` tooling failure (download/env issue — not your report's fault)

Requires `node` + `npm` on PATH for the ajv leg (Node 20+) and `npx` for the
Microsoft conformance leg. Runs on Windows (Tabular Editor 2 is Windows-only).

## Microsoft conformance CLI — blocking (promoted by #112)

`@microsoft/powerbi-report-authoring-cli` (first-party, MIT, 0.x preview) validates
PBIR conformance — role names per visual type, theme registration, formatting-object
properties — a *renders-but-wrong* defect class none of the incumbent triad can see
(ajv models `queryState` as an open map; fab-inspector runs repo-custom rules; TE2
is model-side). The #112 evaluation found 16 errors on the legacy report, all true
defects with zero false positives, so it gates as `validate.ps1` leg 4 and a step in
the ubuntu `pbir-schema` CI job. Pinned exactly (`@0.1.4`) to contain preview churn:
`npx -y @microsoft/powerbi-report-authoring-cli@0.1.4 validate <path> --format text`.
It retires none of the triad. The broader Microsoft `skills-for-fabric` stack is the
strategic successor to re-evaluate at GA.

## Screenshot / visual-verification loop

Claude verifies its own report edits by rendering pages to Desktop-fidelity PNGs
and reading them back. The tool is **`@microsoft/powerbi-desktop-bridge-cli`**
(first-party, preview), pinned to **0.1.2**; install
`npm i -g @microsoft/powerbi-desktop-bridge-cli@0.1.2` and the binary is
`powerbi-desktop`.
Command surface: `status`, `manifest`, `open`, `reload`, `screenshot <page-id>`,
`screenshot-all`. It is **preview** — re-verify the surface on any version bump.

The loop: edit PBIR on disk → `powerbi-desktop reload` →
`screenshot-all --output-dir <dir>` (or `screenshot <page-id> --output <path>`) →
Claude reads the PNGs → repeat. `--scale` is 1-3 (default 2). Note `screenshot` takes `--output`
(a file) while `screenshot-all` takes `--output-dir` (a directory).

**Store-install gotcha (decisive on this fleet).** Power BI Desktop here is the
**Microsoft Store (Appx)** build, not the classic MSI. The bridge's `open` verb
cannot launch it: the real exe lives under the protected
`C:\Program Files\WindowsApps\...` and spawning it fails `spawn EPERM`, while the
`PBIDesktopStore.exe` app-execution alias is a zero-byte reparse point the bridge's
existence check rejects (`DESKTOP_EXE_NOT_FOUND`). Setting `PBI_DESKTOP_PATH` to
either does not help. **Workaround: launch Desktop yourself, then let the bridge
_attach_ to the running process** — every other verb (`status`, `screenshot`,
`screenshot-all`) attaches to a running PID and works fine:

```powershell
$appId = "Microsoft.MicrosoftPowerBIDesktop_8wekyb3d8bbwe!Microsoft.MicrosoftPowerBIDesktop"
$pbip  = "<path-to>\cc-otel-report.pbip"       # e.g. powerbi\cc-otel-report.pbip
Start-Process "shell:AppsFolder\$appId" -ArgumentList $pbip
powerbi-desktop status --wait-seconds 120      # poll until "status": "ready"
powerbi-desktop screenshot pg_overview --output shot.png --scale 2
```

If the classic MSI Desktop is ever installed instead, `open` works directly and
this launch step is unnecessary.

**Data gate (one-time, HITL).** The model is Import mode and the bridge has no
refresh verb. First open blocks on the "loading data model" prompt until the
canvas is up; `status` reports `Host is not ready to accept operations` until then.
Data-populated screenshots need a one-time manual credential entry + **Refresh** in
Desktop against Azure Postgres; thereafter the gitignored `.pbi/cache.abf` carries data
across reopens and the loop runs unattended. **Layout / theme / formatting
verification needs no data and works immediately.**

Fallback (not used): Fabric/PBI REST `exportToFile` gives unattended auto-refresh
renders but requires a Premium/Embedded/Fabric-capacity workspace — the Service
stack the report effort (#104) excludes.

## Headless DAX read — `dax-eval.ps1` (#200)

The independent numeric check for the model/mixed verification loop: with the
report open in Desktop, read a measure value straight off the embedded Analysis
Services and assert it. It **supplements**, never replaces, the screenshot +
Postgres cross-check — a wrong-but-rendering measure (a proration bug that still
produces a plausible number) survives a screenshot but not a DAX read.

```powershell
pwsh .github/powerbi/dax-eval.ps1 '[Total Sessions]'                      # bare scalar auto-wrapped in EVALUATE ROW(...)
pwsh .github/powerbi/dax-eval.ps1 'EVALUATE ROW("s",[Total Sessions])'    # full DAX statement
pwsh .github/powerbi/dax-eval.ps1 '[Active Users]' -Port 61754            # explicit port
```

Output is tab-separated rows, a header of column names first (always emitted,
even when the query returns zero data rows). Exit codes: `0` the query ran; `1` a
DAX/query error (bad measure name, syntax); `2` a tooling failure (no `msmdsrv`,
ambiguous port, download/load failure) — the message goes to stderr, legible, no
dialog.

- **Runtime + client.** pwsh 7 (.NET 8), same as `validate.ps1`. Loads the
  **ADOMD.NET client** (`Microsoft.AnalysisServices.AdomdClient` 19.114.8, the
  net8 build). The four files a local connection needs — the managed client, its
  two `Runtime.*` companions, and the native `msasxpress.dll` — self-fetch from
  one NuGet package into `.pbi-tools/adomd-19.114.8/` (gitignored, version-pinned)
  on first run, the same cache convention as TE2 and fab-inspector. An
  `AssemblyResolve` handler loads the companions from that folder. No admin, no
  machine-wide registration, and **no MSAL** — it is referenced only on the Azure
  AD auth path, never for a `localhost` embedded connection.
- **Port discovery** mirrors the TMDL-refresh path: `Get-NetTCPConnection` for the
  loopback listen port of the `msmdsrv` process. Every open Desktop spawns its own
  `msmdsrv`, so with more than one instance the helper refuses to guess and asks
  for `-Port`.
- **Why ADOMD, not the alternatives.** MSOLAP (the AS OLE DB provider) is not
  registered on the fleet box and the Store-Appx Desktop does not register it;
  registering it needs admin on an IS-managed machine. DAX Studio / `dscmd` is a
  full extra install with no cache-pattern fit. AMO's `Server.Execute` (the TE2
  `Tabular.dll` already cached) returns an XMLA diffgram that was not reliably
  parseable into values (#173) — the trigger for this ticket. The `.retail.amd64`
  ADOMD package is net45-only and would force WinPS 5.1, off the pbi tooling's
  pwsh runtime.
- **Cross-check discipline.** `DISTINCTCOUNT` counts a BLANK as a member, so the
  Postgres equivalent of an `Active Users`-style measure is
  `COUNT(*) FROM (SELECT DISTINCT col ...)`, **not** `COUNT(DISTINCT col)` (which
  drops NULL). The interim marts live at `ccotel-pg-interim ... /cc_otel` (schema
  `marts`); `.env.interim`'s `DATABASE_URL` reaches it for the cross-check.
  Refresh the model first (a TOM `RequestRefresh(Full)` + `SaveChanges` on the
  embedded instance uses Desktop's cached credentials) so the cache matches
  current Postgres before comparing.

## Model-layer (TMDL) verification loop — traps from #118

Findings from driving semantic-model edits through Desktop headlessly:

- **When Desktop rejects a TMDL model, it fails *silently*.** No `DataModelLoadFailed` dialog —
  Desktop just opens as `Untitled - Power BI Desktop` with the file never loaded.
  A TOM `TmdlSerializer.DeserializeDatabaseFromFolder` pass (and TE2's BPA leg)
  can still be green: the failure is engine *load*, not parse. Bisect by
  reverting change groups.
- **Known silent killer: a `fromCardinality: one` (1:1) relationship into a table
  on an RLS security-filter chain** (here `dim_user`, security-filtered from
  `vw_UserBasicInfo`'s `OrgScope` rule). `securityFilteringBehavior: oneDirection`
  does not rescue it. Express the join as plain many:1 with the roster/lookup
  table on the *to* side — same filter flow, `RELATED()` still works, and the
  to-side uniqueness is enforced at refresh.
- **`reload` does NOT apply TMDL model changes** — it re-reads the *report* layer
  and (with cached data-source credentials) can trigger a full **data refresh**,
  overwriting `cache.abf`. For model-definition changes, close Desktop and reopen
  the `.pbip` — or, faster for measure-only changes, TOM-add the identical
  measures to the live model (`Table.Measures.Add` + `SaveChanges()`), keeping
  the TMDL edit as the on-disk source of truth. Note a Desktop **save** then
  re-serializes the whole pbip (CRLF, property reorder) — expect wide but
  content-neutral git churn.
- **Unattended data gate for new tables:** a table-scoped TOM refresh against
  Desktop's embedded AS instance works —
  `Model.Tables["x"].RequestRefresh(RefreshType.Full)` + `SaveChanges()` on
  `localhost:<port>` (port via `Get-NetTCPConnection` on the `msmdsrv` process).
  The same embedded instance answers ad-hoc DAX for headless measure
  verification through `dax-eval.ps1` (the ADOMD.NET read; see "Headless DAX
  read" above) — no report visuals needed.
- **New columns render (Blank) until the cache is refreshed.** `cache.abf` is
  the imported-data snapshot; a column added to TMDL after the snapshot (or a
  measure over one) has no data in it. A fresh open re-reads TMDL *structure*
  but still binds the old cache ("Some of the tables have incomplete or no
  data"). Fix: TOM `Full` on the affected table + a `Calculate` pass, then
  reload + screenshot. Needs the worktree's `.env.interim` for Azure
  connectivity.
- **Prefer a DAX calculated column over a SQL sourceColumn for derived
  columns** (e.g. `hour_of_day = HOUR([hour])`): a sourceColumn needs a full
  re-import, and a TOM `RefreshType.Full` against Azure Postgres can hang
  >15 min unattended with no error (refresh/credential-side, not
  connectivity) — while a calc column materialises from already-imported data
  via a local `Calculate` refresh in seconds. Reserve SQL sourceColumns (the
  `activity_date` convention) for columns that need a real re-import anyway.
  After adding one: reopen the `.pbip` (not `reload`), then `Calculate`. On a
  slow fresh open the title reads `Untitled - Power BI Desktop` transiently —
  wait for bridge `ready` before judging it a silent load failure.
- **Sequence TOM refreshes after bridge `reload`, never concurrent** — two
  mashup evaluations race and snap the engine pipe ("Pipe is broken" frown;
  bridge stuck "Host is not ready"); recovery is kill + reopen (TMDL/report on
  disk lose nothing). Wait for bridge `status: ready`, then one TOM pass.
- **DAX trap: `DATESINPERIOD` with an anchor outside the date column's range
  clamps to the nearest stored date instead of returning empty** — a "prior 28d"
  window before first ingest silently leaks current-window rows. Use
  `DATESBETWEEN` with explicit bounds for fixed rolling windows.
- **Every `reload` (and fresh open) re-raises the "calculated objects need to be
  manually refreshed" banner**, which overlays the top ~60px of the canvas in
  screenshots and blanks roster/calc-column visuals. Clear it headlessly:
  `Model.RequestRefresh(RefreshType.Calculate)` + `SaveChanges()` over the same
  TOM connection. Local recompute only; the Azure source is never touched.
  Since #294 every seat table is an Azure mart (`dim_seat`, `dim_seat_current`,
  `fact_seat_day`) rather than a local CSV, so a *new* seat column or table needs
  a table-scoped `Full` against Postgres — credentials required — before
  `Calculate` has anything to recompute over.

## Rejected / out

- **pbir-cli** (data-goblin PyPI) — proprietary Non-Commercial license + no linux
  wheel (breaks ubuntu CI). Hard stop for a commercial repo. Do not revisit as an
  authoring engine; pbi-cli covers the need.
- **POC layout scripts** (`scaffold-chrome` / `rewrite-nav` / `add-table-titles` /
  `fix-misc`.ps1) — hardcoded to the old report's pages; the IA is being redesigned
  from scratch, so they encode a layout we are discarding.
- **fab / Fabric CLI, live-connection skills, MCP servers, pbi-tools, pbi-inspector
  v1** — deploy / live / PBIX-era, out of fit for a no-live-connection on-disk loop.
