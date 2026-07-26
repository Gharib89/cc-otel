# The report publishes to a PPU workspace, refreshes hourly, and distributes through an app with audiences

**Status:** accepted

`powerbi/README.md` step 4 named a PPU workspace as the publish target without recording why.
Reviewing it before the first publish, the licensing rule looked disqualifying: "to collaborate
and share content in a PPU workspace, all users need a PPU license", and a Pro-licensed viewer
is *blocked* with an upgrade prompt rather than degraded. On that reading a Pro workspace is the
safer superset, since both Pro and PPU licences can "view shared content in non-Premium
workspaces".

The tenant licence inventory (2026-07-26, `subscribedSkus`) dissolves that argument. There is
**no `POWER_BI_PRO` SKU in the tenant at all**: paid Power BI is entirely
`PBI_PREMIUM_PER_USER` (61 of 100 assigned), and the 178 `POWER_BI_STANDARD` assignments are
the free tier — `SPE_E3` does not bundle Pro. So any manager not already licensed needs a PPU
seat assigned *whichever* workspace type is chosen; the Pro workspace's extra reach is a
hypothetical future SKU purchase, not an audience that exists. It costs the same and reaches
the same people.

With the licensing argument neutral, PPU's platform features decide it, and one of them fixes a
known defect in the report. `Hours Since Last Signal` measures query-time `NOW()` against
`MAX(fact_api_usage[last_event_ts])`, which freezes at model refresh — the model's own TMDL
comment names the consequence: "staleness includes the daily report-refresh lag, not just
pipeline silence". Pro's 8-refresh/day ceiling means the report can never track the hourly
marts closer than roughly three hours, so the freshness cards spend most of their range
reporting refresh lag rather than pipeline health. PPU's 48/day allows an hourly refresh, under
which staleness stays below two hours and the card measures what it claims to measure.

## Decisions

- **Workspace license mode is PPU.** The workspace is **AIWorx**. Every consumer needs a PPU
  seat; 39 of 100 were spare as of 2026-07-26, so the manager audience fits without a purchase.
- **Neither source needs a gateway.** Confirmed at the first publish (2026-07-26): the service
  reaches both the public Postgres endpoint and the IS-owned `itxdatainteg-prod` Azure SQL HR
  view over cloud connections. The Postgres side was expected (`AllowAllAzureServices` in
  `postgresFirewallRules`, ADR-0004); the Azure SQL side was the open risk and is now retired.
- **Scheduled refresh is hourly at `:30`** — 24 of the 48 available slots. The offset clears the
  hourly `marts.refresh_all()` (`pg_cron '0 * * * *'`) so the model never reads mid-refresh.
  This keeps `Data Freshness Status` inside its 24h amber threshold by a wide margin, making
  Amber a genuine signal that ingest or `pg_cron` has stopped.
- **Consumers reach the report through a Power BI app, never workspace access.** App
  distribution enforces `OrgScope` without granting a workspace role. The app has a **single
  audience**: managers. The per-page audience split this ADR originally carried was dropped
  once it proved unbuildable — audiences scope items, not pages, and hiding `pg_health` doesn't
  contain it either, since every visible page has a `nav_health` button and navigation buttons
  reach hidden pages. Reserving it would have required splitting the report in two over one
  semantic model; the accepted consequence is that a manager can open Data Health and read it
  as "all clear" when under `OrgScope` its off-roster visuals simply render empty.
- **Only Viewers and app consumers are scoped.** RLS "doesn't apply to workspace Admin, Member,
  or Contributor roles", so every workspace role above Viewer is an unscoped view of all roster
  addresses. The workspace has exactly one Admin and no other members; handover happens by
  semantic-model takeover, not standing membership.
- **XMLA read-write and deployment pipelines are available but deliberately unused for now.**
  Publishing stays manual from Desktop (ADR-0004, `powerbi/CLAUDE.md`). The headroom is
  recorded because it changes what is *possible* later: a scripted deploy would close the last
  hand-operated step in an otherwise on-disk pipeline, and pipelines are the native answer to
  the interim->prod promotion in #247.

## Rejected alternatives

- **Pro workspace** — rejected: reaches no additional real user (no Pro SKU exists in the
  tenant), caps refresh at 8/day which leaves the freshness measure reporting its own refresh
  lag, and forgoes XMLA read-write and deployment pipelines.
- **Twice-daily refresh (07:30 / 19:30 Cairo)** — rejected once PPU removed the 8/day ceiling.
  It kept staleness under the amber threshold, but only by ~12h of margin, and left the card
  dominated by refresh lag rather than pipeline state.
- **Fabric F64+ capacity** — not available; IS owns capacity allocation and none is assigned to
  this project. It is the only thing that would let free-licence users read the report.
- **Workspace Viewer access instead of an app** — rejected: RLS would still apply, but viewers
  would browse the raw item list, including the hidden session-drill page and the Data Health
  page that managers must not consume.

## Consequences

- **Every consumer needs a PPU seat**, drawn from the 39 spare. A manager outside the 61
  already assigned needs IS to assign one before they can open the app. Publishing and refresh
  don't block on this; only distribution does.
- **The instrumented developers cannot see the report.** 178 tenant users hold the free
  `POWER_BI_STANDARD` licence, which grants no access to shared content outside a Premium or
  F64+ capacity. A page showing a developer their own usage is unreachable by licensing alone,
  and more PPU seats would not fix it — only capacity would. The audience stays managers via
  `OrgScope` until that changes. Not tracked as work: pursuing capacity is an IS budget
  decision nobody is scheduling today.
- **Leaving PPU later costs a full refresh** — "any workspace migrated from a PPU environment
  to a non-PPU environment must have its datasets refreshed before use", and reports opened
  before that refresh fail with a blocked-database error. Cheap for a model this small, which
  is why the reversal risk is accepted rather than designed around.
- **24 refresh runs per day means 24 chances to be notified of failure.** Refresh-failure
  emails go to the semantic-model owner; four consecutive failures disable the schedule
  entirely, so a silent inbox rule over these notifications would hide the disable event too.
- **Copilot in Power BI stays unavailable** — it requires an F2+ or P capacity, which PPU is
  not. Unchanged from the Pro option; noted so it isn't mistaken for a PPU benefit.
