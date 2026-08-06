# A front door is retired on measured silence, not on a date

**Status:** accepted — generalises **ADR-0021** from a cutover tactic to the standing rule, and adds
a gate item to #248 Part B. Implemented by #431 (`tools.front_door`). Decided 2026-08-06.

ADR-0021 makes interim **write-quiet by construction**: its sink writes to production, so interim's
`meta.processed_batches` stops gaining rows and #409's terminal sweep can prove its own precondition.
That measurement is correct for what it guards — no further interim *rows* after the copy — and
**silent about the front door**. Interim's `meta.processed_batches` is empty *because* the repointed
sink writes elsewhere. A machine still POSTing to interim's collector endpoint produces zero interim
batches and full production rows, so every quiet gate in the repo reads green while the endpoint is
in active use.

Measured 2026-08-06 on `ccotel-app-interim`'s `Requests` platform metric, split by `statusCode`
(the repoint landed 2026-08-03 ~19:14Z):

```
2026-07-30  200  7708    401     7
2026-07-31  200   873
2026-08-01  200   985    404     2
2026-08-02  200  9094    404     8
2026-08-03  200  2456    401     2
2026-08-04  200  1367    401  1348    404  3
2026-08-05  200   374
2026-08-06  200   267   (partial day, to 13:00Z)
```

Real client traffic, not probe noise: 37 of the 120 hours since 2026-08-02 are flat zero and the
non-zero hours track ITWorx working hours, whereas a liveness probe is constant across all 120.

**The root cause is that the tail has no upper bound a date can encode.** Claude Code reads `OTEL_*`
**once, at process start**. A Windows machine-scope environment-variable change never reaches an
already-running process, and the **installer**'s drift repair converges the *disk* on IS's 90-minute
cadence, not the process. So the rollout duration of any fleet-config change is set by the
longest-lived session on the fleet — and Claude Desktop keeps one process alive for days. The
trigger here was a single seat whose Desktop process had been open across the flip; the numbers
above say it was not the only one, and nothing names the rest.

Deleting the resource group under that traffic loses data **silently**. The client collector's
`retry_on_failure.max_elapsed_time: 0` plus its file-backed `sending_queue` (`collector/config.yaml`)
means it retries forever into a dead host and buffers up to 10,000 batches locally. No error reaches
this repo, the report, or `marts.dq_finding`; the seat simply stops appearing.

## Decisions

- **A front door is retired only after measured silence at that front door.** The evidence is
  `Requests` on the environment's Container App, split by `statusCode`, per UTC day. Not a store
  clock, not a log query, not an elapsed-time argument.

- **The measurement is `tools.front_door`, and it is read-only.** It prints the per-day table and a
  verdict — `SILENT` / `STILL RECEIVING` — and exits 1 while the door is still receiving. Detection
  only, exactly as ADR-0023 settled for `env-schema-status`: the tool never deletes anything and
  never opens a gate. The human go/no-go with Ahmed stays as it is; this adds one item to the
  evidence it decides on.

- **The threshold is 7 consecutive complete days with zero `200`s**, a fixed constant rather than a
  flag. Seven covers a full working week, so a seat that only works Mondays cannot hide inside the
  window. No `--force` twin and no knob, for ADR-0021's reason: the decision it feeds is
  irreversible and its failure mode is silent, so a lowerable threshold invites being lowered under
  time pressure.

- **The run is anchored at yesterday, and today never counts toward it.** The current UTC day is
  reported but excluded from the verdict — it is still accruing, so a morning with no posts yet is
  not a day without posts. A window that stops short of yesterday scores **zero** however quiet it
  was, so `--until` a month back cannot report a run that ended weeks ago: a day the window does
  not cover is unknown, and unknown is never silence. Both exclusions run the same direction —
  the gate must not open early.

- **A window reaching past Azure's 93-day platform-metric retention is refused.** Outside retention
  the API answers with an empty series rather than an error, so "no requests" and "no data" are
  indistinguishable and unretained days would read as silence. Inside it, the metric answers
  **retrospectively**, which is why no collection had to be running before the question was asked.

- **`Requests` rather than the Log Analytics access log.** The platform metric needs no workspace,
  no ingestion delay and no KQL, it survives a revision replacement, and its 93 days outlast the
  workspace's default 30. The `statusCode` split is what separates accepted ingest from rejected
  posts, and a rejected payload is **dropped, not queued** — so the rejected column is live data
  loss, never retry noise.

## Considered options

- **Wait longer on a fixed clock** — extend #248 Part B's two weeks to three or four. Rejected: the
  same bet with a bigger number. The tail is bounded by the longest-lived process on the fleet, and
  no date encodes that. Only the measurement closes it.

- **Push the config change harder** — have IS re-push the installer, or force a reboot. Rejected as
  the *gate*: it shortens the tail without measuring it, and the installer already converges the
  disk. It remains the right *remedy* once the measurement names a day that is not yet silent.

- **Automate the delete behind the measurement.** Rejected on ADR-0023's reasoning — a watchdog that
  acts on its own reading hides the gap it exists to surface, and `az group delete` is the least
  reversible action in this repo.

- **A scheduled workflow, like `env-schema-status`.** Rejected as machinery ahead of need: this
  question is asked at one gate, a handful of times, and the metric answers retrospectively — so an
  operator running the tool on the day gets the same answer a month of cron runs would have
  accumulated. A recurring front-door watch is #432's concern, per seat.

- **Query the collector's access log in Log Analytics** (the method used ad hoc on 2026-08-05).
  Rejected as the standing rule: it works, but it needs the workspace to exist and to have retained
  the window, it is a different query per environment, and the workspace dies with the resource
  group it is measuring.

## Consequences

- **#248 Part B gains a gate item**: zero `200`s at interim's front door for 7 consecutive complete
  days before `az group delete rg-cc-otel-interim`. Measured 2026-08-06 the run was **0 days**, so
  the earliest date the item can be satisfied moved later than the two-week clock's ~2026-08-17.

- **The rule outlives interim.** It is written for any front door this project retires — a second
  environment, a re-pointed collector, a replaced Container App — which is why it is an ADR rather
  than a checklist item on one issue.

- **The 2026-08-04 `401` spike is explained by mechanism and accepted by figure.** 1,348 rejected
  posts in one day, against 2 the day before and 0 after. A `401` payload is dropped, so this is
  live data loss on that date. Investigated 2026-08-06:

  - The **repoint deploy is the trigger**. The activity log shows a `listSecrets` then a
    `containerApps/write` at `2026-08-03 19:27:35–19:28:03Z`, caller `Ahmed.Gharib@itworx.com`,
    which created revision `--0000036` and restarted the collector. That revision served the whole
    spike (05:00Z until `--0000038` replaced it at 13:13Z) and no longer exists.
  - The **wrapper resolves endpoint and bearer independently** — each checks `process.env` first,
    then falls back to `managed-settings.json` on disk, read **once per process**
    (ADR-0003, `installer/cc-otel-wrapper.mjs:214`). A process alive across the flip can therefore
    pair one environment's front door with the other's token for its whole life.
  - The **hourly shape says many stragglers, not one client**: bursty, tracking ITWorx working
    hours (peaks 11:00–13:00Z and 16:00–19:00Z, near-zero at 07:00Z and 09:00Z), decaying to zero
    by 08-05. A single mis-tokened client retrying would be flat, because the collector's retry is
    unbounded.

  **What no retained log can settle is which machines.** `bearertokenauth` logs nothing on reject
  at any level, so interim's `ContainerAppConsoleLogs_CL` holds no `401` line for the whole day —
  an architectural gap, not a retention one — and a `401` is refused before any body is parsed, so
  it carries nothing identifying. Accepted with the figure rather than left unremarked, and not
  tracked: the population is frozen, the rows were never written anywhere, and the same process-
  lifetime cause is what this ADR's measurement now guards against repeating.

- **`tools.front_door` is the first tool in this repo that shells out to `az`.** It resolves the
  executable through `shutil.which` (the CLI is `az.cmd` on Windows, which a bare argv cannot find)
  and addresses the resource by `--resource <name> --resource-group` rather than by resource ID,
  because git-bash rewrites a leading `/subscriptions/...` into a Windows path.

- **It needs Monitoring Reader on the resource group and an `az login` in the right subscription.**
  Interim lives in the VS Enterprise subscription, not the default one, so neither the subscription
  nor the resource group has a safe default — the tool refuses rather than guessing.
