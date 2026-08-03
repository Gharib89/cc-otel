# Report handover — Claude Code Adoption

**Owner from 2026-08-03: Mohamed Atallah (`Mohamed.Atallah@itworx.com`).**
Pipeline owner (everything below `marts`): Ahmed Gharib (`Ahmed.Gharib@itworx.com`).

You own the Power BI layer. You do **not** need this repository, git, Power BI Desktop, the VPN, or
database access to run it — everything below happens in the Power BI Service. The decisions behind
this arrangement are in [`docs/adr/0022-report-ownership-leaves-the-repo.md`](../docs/adr/0022-report-ownership-leaves-the-repo.md);
this file is the operating manual.

## What you're taking over

| Thing | Value |
|---|---|
| Workspace | **AIWorx** (PPU license mode) |
| Items | Semantic model + report, both published as **`cc-otel-report`** |
| What consumers see | Power BI app **Claude Code Adoption**, single audience: managers |
| Your role | Workspace **Admin** (Ahmed keeps Admin for pipeline diagnosis) |
| Data sources | Azure Postgres `ccotel-pg-prod` (`cc_otel` DB, `marts` schema) + Azure SQL HR view `vw_UserBasicInfo` on `itxdatainteg-prod` |
| Scheduled refresh | **Hourly at `:30`**, 24 of PPU's 48 daily slots |
| Gateway | None, and none needed — both sources are reachable over cloud connections |

Consumers reach the report only through the app and hold no workspace role, so row-level security
(`OrgScope`: a manager sees themselves plus their management subtree) always applies to them. It does
**not** apply to you: Admin/Member/Contributor bypass RLS, so what you see is the whole fleet. That is
expected — just don't screenshot an unscoped page into a channel where scoped consumers read it.

## First tasks, in order

### 1. Take over the semantic model

Workspace **AIWorx** → the `cc-otel-report` **semantic model** → **Settings** → **Take over**.

A semantic model has exactly one owner, and only the owner can edit data-source credentials or the
refresh schedule. Until you take over, both are read-only for you.

### 2. Re-enter both data-source credentials

Semantic model **Settings** → **Data source credentials** → **Edit credentials**, for both sources.
Ahmed sends you the two passwords out of band (password manager or one-time-secret link — they are
never committed, this repo is public):

| Source | Auth | User |
|---|---|---|
| Postgres `ccotel-pg-prod.postgres.database.azure.com` | Basic | `cc_otel_read_user` — **not** `cc_otel_read`, which is a NOLOGIN group role and fails whatever password you give it |
| Azure SQL `itxdatainteg-prod` | Basic | the employee-dataset login Ahmed provides |

Keep the connection **encrypted** for Postgres (SSL is required server-side).

Credentials are stored per server, so the report arrives at production uncredentialed even though it
refreshed fine against the old server. Expect the first refresh to fail until this step is done.

### 3. Confirm the schedule and the alerts

Semantic model **Settings** → **Refresh**:

- Scheduled refresh **on**, hourly at **`:30`**. Both halves matter: the `:30` offset clears the
  hourly database-side mart refresh that runs at `:00`, and hourly (rather than daily) is what keeps
  the report's freshness cards measuring the *pipeline's* silence instead of the report's own refresh
  lag.
- **Send refresh failure notifications** to the semantic model owner **and** add
  `Ahmed.Gharib@itworx.com` as an additional recipient.

### 4. Sign-off

**Signed off 2026-08-03.** Takeover, credential re-entry and the hourly schedule were confirmed
working against production the same day, so the originally-planned 24-consecutive-green window was
waived by Ahmed rather than waited out — he watches refresh history directly and steps in on a
failure. The standing detector from here on is the **refresh-failure notification** (step 3), not a
one-off observation window: a stalled refresh has to reach a human by mail, because nothing in the
repo watches the Service.

## The two parameters — how the report changes environments

Semantic model **Settings** → **Data access** → **M parameters**:

| Parameter | Current value |
|---|---|
| `PgHost` | `ccotel-pg-prod.postgres.database.azure.com` |
| `PgDatabase` | `cc_otel` |

All 21 Postgres queries read these, so changing `PgHost` moves the whole model to another server in
one edit — no Desktop, no file changes. **After any change you must re-enter the Postgres credentials
(step 2), because they are bound to the server name.**

### The trap: a green refresh can silently shrink the model

Every Postgres query in this model is `SELECT *`. So if the target database is **missing columns**
that the model expects — because its schema is behind the code — the query still succeeds, and Power
BI reconciles by **deleting those columns from the model**. The refresh reports success. Visuals bound
to the deleted columns go blank or error afterwards, with nothing pointing at the cause.

This happened on the first attempt at this very repoint (2026-08-03): production was missing eight
migrations, and the refresh quietly dropped `dq_finding[subject]`, `[kind]`,
`[first_detected_at]`, `[standing_since]` plus columns from five `bridge_session_*` tables,
`fact_session` and `fact_tool_outcome`.

**So: before pointing `PgHost` at any database, confirm with Ahmed that its schema is up to date.**
"The refresh succeeded" is not evidence that it is. After a host change, spot-check the Data Health
page and one bridge visual rather than trusting the green tick.

The only other server that exists is `ccotel-pg-interim.postgres.database.azure.com`, the old
environment. It is a valid rollback target **only until the ingest repoint lands** (tracked in #410,
expected within days of this handover): after that, interim stops receiving telemetry and would show
frozen, incomplete data. Once #410 is done, forward-only — if production looks wrong, the fix is in
production, and it is Ahmed's.

## The one question managers will ask

> "The numbers for July were higher/lower than last week. Which is right?"

**The later one.** Production inherited telemetry from 2026-07-17 onward, and it arrived in stages:
each developer machine was switched over on its own schedule, and each one's pre-switch backlog is
copied afterwards. Two consequences:

- Fleet totals for **17 July → early August only go up** as backlogs land. Nothing is being
  double-counted and nothing is being deleted; rows are still arriving for that window.
- It stops moving once the copy tickets close (#245, #409, #410). Ahmed can tell you where that
  stands — it is a pipeline question, not a report one.

Nothing on the report canvas explains this, deliberately: a temporary banner would have needed
removing on a schedule tied to tickets you don't track. This paragraph is the answer.

## Whose problem is it?

| Symptom | Owner |
|---|---|
| Refresh fails with a credentials/sign-in error | **You** — re-enter credentials (step 2) |
| Refresh fails after a parameter change | **You** — credentials are per server; re-enter them |
| App consumers can't see the report, or see too much | **You** — app audience + workspace roles |
| A visual is wrong, mislabelled, or badly laid out | **You** — Desktop edit + republish |
| Refresh succeeds but the data is **stale** (freshness cards amber/red) | **Ahmed** — the database's own hourly mart refresh, or ingest, has stalled |
| Numbers look wrong but internally consistent | **Ahmed** — mart definitions |
| Data Health page shows unknown-email or identity findings | **Ahmed** — data quality in the pipeline |
| Refresh fails with a Postgres error that isn't about the login | **Ahmed** — send him the exact error text |

Quick way to tell the top half from the bottom: if the refresh **succeeded** and the data is still
wrong or old, it is below the database boundary, so it is Ahmed's. Include the refresh timestamp and
the exact error string when you escalate.

## Don't

- **Don't rename the published items in the Service.** Republishing matches by name; a rename makes
  the next publish create a duplicate pair and leaves the app pointed at the old report while fresh
  data lands in the new one.
- **Don't grant workspace roles above Viewer** to get someone access — Admin, Member and Contributor
  all bypass RLS, so it silently hands over the whole fleet's data. Add people to the **app audience**
  instead.
- **Don't author in this repository.** The `powerbi/` tree here is a frozen archive of the last
  repo-authored state (ADR-0022); the Service is the source of truth now. If you ever want to go back
  to on-disk authoring, that is a conversation with Ahmed, not a commit.
- **Don't save the `.pbip` from Desktop** if you ever do open this repo's copy — it re-serializes the
  whole project and produces a large meaningless diff.

## Background, if you want it

- `README.md` (this folder) — what the model and the seven report pages contain, RLS design, theme.
- `../docs/adr/0014-ppu-workspace-hourly-refresh.md` — why PPU, why hourly at `:30`, why an app with
  one audience.
- `../docs/adr/0022-report-ownership-leaves-the-repo.md` — this handover's decisions.
- `../docs/report-data-contract.md` — what each column on the Users page means.
