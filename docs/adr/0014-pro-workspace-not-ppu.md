# The report publishes to a Pro workspace, not a PPU one, and distributes through an app with audiences

**Status:** accepted

`powerbi/README.md` step 4 said "publish manual from Desktop to the PPU workspace", chosen
because the operator holds a PPU licence and PPU workspaces are the licence's visible
feature. Reviewing the licensing rules before the first publish showed that reading is
backwards: PPU is not a capability the publisher grants, it is a requirement the workspace
imposes on every consumer. Microsoft's rule is unambiguous — "to collaborate and share
content in a PPU workspace, all users need a PPU license", and a Pro-licensed viewer is
*blocked* with an upgrade prompt rather than degraded.

The tenant licence inventory (2026-07-26, `subscribedSkus`) shows there is **no
`POWER_BI_PRO` SKU in the tenant at all**: paid Power BI is entirely
`PBI_PREMIUM_PER_USER` (61 of 100 assigned), and `POWER_BI_STANDARD` (178 assigned) is the
free tier — `SPE_E3` does not bundle Pro. That makes the Pro workspace the *superset*
choice rather than the cheaper one: "View shared content in non-Premium workspaces" is
allowed for both Pro and PPU licences, so the 61 existing PPU holders read a Pro workspace
unimpeded, and any future Pro assignment also works. A PPU workspace would narrow the
possible audience to PPU holders alone while buying nothing.

Nothing in the report needs what PPU buys. The Pro limits it would lift are a 1 GB model
(this model imports 14 marts over a fleet of ~200 seats), 8 refreshes/day (the schedule
uses 2), and XMLA read-write plus deployment pipelines (publishing is manual from Desktop
by design, ADR-0004 and `powerbi/CLAUDE.md`). RLS itself is a Pro feature — a PPU workspace
would not scope one row differently.

The reverse migration is not free either: "any workspace migrated from a PPU environment to
a non-PPU environment must have its datasets refreshed before use", and reports opened
before that refresh fail with a blocked-database error. Choosing PPU first and correcting
later therefore costs a forced full refresh, which is why this is settled before the first
publish rather than after.

## Decisions

- **The workspace is Pro (shared capacity).** The operator publishes with their PPU licence
  — PPU includes every Pro capability — but the workspace license mode stays Pro so that
  Pro-licensed consumers can read the report.
- **Consumers reach the report through a Power BI app, never workspace access.** App
  distribution enforces `OrgScope` without granting a workspace role, and it carries the
  audience split `powerbi/README.md` already specifies: the Data Health page goes to the
  owner/IS audience only, because under the role its off-roster visuals render empty and
  read "all clear" precisely when they are not.
- **Only Viewers and app consumers are scoped.** RLS "doesn't apply to workspace Admin,
  Member, or Contributor roles", so every workspace role above Viewer is an unscoped view of
  all roster addresses. The workspace therefore has exactly one Admin and no other members;
  handover happens by semantic-model takeover, not by standing membership.
- **F64+ capacity is the upgrade path, not PPU.** If IS ever assigns a Fabric F64 or larger
  capacity, moving this Pro workspace onto it lets Free-licensed viewers read the report at
  no per-seat cost. PPU can never do that.

## Rejected alternatives

- **PPU workspace** — rejected: buys nothing this report uses, taxes every viewer with a PPU
  licence, and unwinding it forces a full refresh of the model.
- **Workspace Viewer access instead of an app** — rejected: RLS would still apply, but
  viewers would browse the raw item list, including the hidden session-drill page and the
  Data Health page that managers must not consume.
- **Fabric F64+ capacity now** — not available; IS owns capacity allocation and none is
  assigned to this project.

## Consequences

- Every consumer needs a Pro or PPU licence until an F64+ capacity exists. In practice that
  means a PPU seat, since the tenant carries no Pro SKU — 39 of 100 PPU seats were spare as
  of 2026-07-26, so a manager audience fits without a purchase, but each manager outside the
  61 already assigned needs IS to assign one. Publishing and refresh don't block on this;
  only distribution does.
- **The instrumented developers cannot see the report.** 178 tenant users hold the free
  `POWER_BI_STANDARD` licence, which grants no access to shared content outside a Premium or
  F64+ capacity. A report page showing a developer their own usage is therefore not
  reachable by licensing alone — it needs an F64+ capacity, not more PPU seats. The report's
  audience stays managers via `OrgScope` until that changes.
- Refresh is capped at 8 slots/day. The schedule uses 07:30 and 19:30 Cairo; a future need
  for near-real-time refresh would hit the Pro ceiling and require capacity, not PPU.
- No deployment pipelines. Interim-to-prod promotion (#83) stays a change to the model's
  server binding plus re-entered credentials — the model currently hardcodes the interim FQDN,
  and the planned mechanism is an M parameter editable in semantic-model settings.
- The single-Admin rule means refresh stays broken until the operator returns if stored
  credentials expire while they are away. Accepted deliberately: the alternative grants
  someone standing unscoped access to all roster data.
