# Claude Code business-impact metrics — track, measure, display

**Research ticket:** #156 (part of wayfinder #153) · **Date:** 2026-07-21

**Question:** what metrics do the industry and Anthropic's own guidance use to measure AI
coding-assistant (specifically Claude Code) impact on the business — adoption, engagement,
productivity, code quality, ROI/cost? For each candidate: definition + computation, telemetry
needed, whether cc-otel already captures it, and how leading dashboards display it.

**Primary sources**

- Anthropic — [Claude Code monitoring/OTel docs](https://code.claude.com/docs/en/monitoring-usage) (full signal inventory already cataloged in [claude-code-otel-signals.md](claude-code-otel-signals.md))
- Anthropic — [Claude Code Analytics dashboard](https://code.claude.com/docs/en/analytics) and [contribution-metrics blog](https://claude.com/blog/contribution-metrics)
- DORA — [four/five keys](https://dora.dev/guides/dora-metrics-four-keys/), [AI research](https://dora.dev/research/ai/), [2024 report](https://cloud.google.com/blog/products/devops-sre/announcing-the-2024-dora-report), [2025 report](https://cloud.google.com/blog/products/ai-machine-learning/announcing-the-2025-dora-report)
- SPACE — [Forsgren et al., ACM Queue](https://queue.acm.org/detail.cfm?id=3454124)
- DX — [Core 4](https://getdx.com/research/measuring-developer-productivity-with-the-dx-core-4/) ([docs](https://docs.getdx.com/dx-core-4/)), [AI Measurement Framework](https://getdx.com/research/measuring-ai-code-assistants-and-agents/), [Claude Code integration](https://getdx.com/blog/dx-releases-integration-with-claude-code/)
- GitHub — [Copilot usage metrics](https://docs.github.com/en/copilot/concepts/copilot-usage-metrics/copilot-metrics) (comparable product)

---

## 1. What each framework measures (context for the catalog)

**Anthropic's own dashboard** (the strongest signal for "what the vendor thinks matters") leads
with: PRs with Claude Code, lines of code with CC, % of merged PRs CC-assisted, **suggestion
accept rate**, lines accepted; charts are DAU + sessions/day (adoption), **PRs per user per day**
(their headline productivity ratio), with/without-CC PR breakdown, and a top-10 leaderboard.
Console/API plans add a daily **Spend** line alongside user count. Anthropic's explicit ROI
guidance: track PRs-per-user as adoption grows and pair with DORA/sprint velocity; internally
they cite a 67% increase in PRs merged per engineer per day
([analytics docs](https://code.claude.com/docs/en/analytics), [blog](https://claude.com/blog/contribution-metrics)).
Everything on that dashboard except PR *merge* attribution is reconstructible from the OTel
stream cc-otel already ingests — merge attribution needs the GitHub side.

**DORA** measures delivery outcomes (change lead time, deployment frequency, change fail rate,
failed-deployment recovery time, deployment rework rate) — all from git/CI/incident systems,
none from Claude Code telemetry. Its AI research is the key caveat source: 2024 found AI
adoption *reduced* delivery throughput (−1.5%) and stability (−7.2%) per 25% adoption increase;
2025 reversed on throughput (now positive) but stability stays negative — "AI is an amplifier";
ROI comes from the surrounding system, not the tool alone.

**SPACE** demands metrics from ≥3 of its 5 dimensions (Satisfaction, Performance, Activity,
Communication, Efficiency), at least one perceptual (survey). CC telemetry covers Activity
(sessions, commits, LoC) and a slice of Efficiency (active time); Satisfaction and Performance
need surveys/external systems. Core rule repeated by every framework: **activity/volume metrics
must never drive individual performance evaluation.**

**DX Core 4**: Speed (PRs merged per engineer), Effectiveness (DXI survey composite), Quality
(change failure rate / defect ratio), Impact (% time on new capabilities). Its **AI Measurement
Framework** tracks the adoption lifecycle in three dimensions — Utilization (% engineers active
daily/weekly; leaders plateau ~60%), Impact (flagship: **AI-driven time savings, hrs/dev/week**,
survey + telemetry; plus % PRs AI-assisted, acceptance rate), Cost (spend, ROI by use case).
Their Claude Code integration's display convention: AI-user vs non-user cohort comparisons and
before/after-enablement views.

**GitHub Copilot** guidance groups: Adoption (DAU/WAU), Engagement (requests per active user),
Acceptance rate ("developer confidence" signal), Lines of code (suggested/added/deleted), PR
lifecycle (merge counts, median time to merge). Display: 28-day trend windows; "look for
patterns across these signals rather than focusing on any single number."

---

## 2. Metrics catalog

Coverage legend — where cc-otel stands today:

- **mart** — in `marts.*` and surfaced by semantic-model measures (`_Measures.tmdl`).
- **model-only gap** — data is in a mart; only a DAX measure/visual is missing.
- **raw-only** — ingested into `raw.events`/`raw.metrics` but not promoted to staging/marts.
- **registry+mart** — needs a new raw column promotion (`meta.column_registry`) *and* a mart.
- **external** — needs git provider / CI / HR systems; out of cc-otel's telemetry reach.
- **survey** — perceptual; not a telemetry metric.

### Adoption

| Metric | Definition / computation | Telemetry | cc-otel coverage | Display convention |
|---|---|---|---|---|
| Daily/weekly/28d active users | Distinct users with any signal in window | any CC metric/event | **mart** — `Active Users`, `Weekly Active Users`, `Active Users 28d` over `fact_session_daily`/`dim_user` | Trend line, DAU + sessions overlay (Anthropic); 28-day windows (GitHub) |
| Seat utilization % | Active users ÷ paid seats | telemetry + seat roster | **mart** — `Seat Utilization %`, `Idle Seats` vs `seat_roster` | KPI tile with Δ; idle-seat list for coaching |
| New / retained / reactivated users | Cohort movement between periods | any signal | **mart** — `New/Retained/Reactivated Users 28d` | Stacked cohort bar or waterfall |
| Sessions per day / per user | `claude_code.session.count` by `start_type` | metrics | **mart** — `fact_session`, `Total Sessions` | Overlay on DAU line (Anthropic pairs them) |
| Usage frequency (active days/user) | Days with activity per user per window | any signal | **mart** — `Active Days` (slice by user) | Histogram: casual vs daily-habit users (DX utilization) |
| Ecosystem feature adoption | % sessions/users using agents, skills, MCP, hooks, plugins | events | **mart** — five bridges + `Sessions Using X %` measures | Small-multiple bars; maturity signal beyond raw adoption |

### Engagement

| Metric | Definition / computation | Telemetry | cc-otel coverage | Display convention |
|---|---|---|---|---|
| Prompts per user-day / session | Distinct `prompt_id` count | `user_prompt` events | **mart** — `fact_session_daily.prompts` | Requests-per-active-user trend (GitHub engagement) |
| Active hours per user per day | `active_time.total`, `user` vs `cli` split | metrics | **mart** — `Avg Active User/CLI Hours per Day` | Split bar: human-attention vs delegated-CLI time; the split itself is the story (delegation ratio) |
| Session duration | max−min signal per session | derived | **mart** — `fact_session.duration_s`, `Avg Session Duration` | Distribution, not average alone |
| Subscription-window utilization | Peak/end % of 5h/7d usage windows | `usage.utilization` gauges | **mart** — `fact_usage_window`, `fact_utilization_hourly`, `Limit-Hit Rate` | Heatmap by hour; limit-hit rate as capacity-planning KPI (unique to CC subscription plans — no industry comparable) |

### Productivity / output

| Metric | Definition / computation | Telemetry | cc-otel coverage | Display convention |
|---|---|---|---|---|
| Lines of code added/removed | `lines_of_code.count` by `type` | metrics | **mart** — `fact_session_daily.loc_added/loc_removed` | Trend with Δ vs prior period; Anthropic shows "lines with CC"; loc_added ≈ "lines accepted" (rejected edits never apply) |
| Commits (per active user) | `commit.count`; ratio ÷ active users | metrics | **mart** (totals + Δ); ratio = **model-only gap** | Ratio trend line, not raw count — normalizes for adoption growth |
| PRs created per active user | `pull_request.count` ÷ active users | metrics | **mart** (totals + Δ); ratio = **model-only gap** | **Anthropic's headline chart** (PRs per user per day, trend as adoption grows) |
| Suggestion accept rate | accepts ÷ (accepts+rejects) on Edit/Write/NotebookEdit | `code_edit_tool.decision` | **mart** — `fact_edit_decision`, `Tool Acceptance Rate` (+ by language/tool/source) | KPI tile with Δ; per-language bar (trust signal; GitHub calls it "developer confidence") |
| % of merged PRs AI-assisted | Merged PRs containing ≥1 effective CC line | **git provider** (Anthropic's GitHub-app matching) | **external** | Anthropic summary tile; with/without-CC stacked bar |
| AI time savings (hrs/dev/week) | Self-reported + telemetry blend | survey | **survey** — DX's flagship impact metric | Single tile: hrs/dev/week × loaded cost = ROI numerator |
| PRs merged per engineer (org-wide) | All merged PRs ÷ engineers | git provider | **external** — DX Core 4 Speed key | Longitudinal trend vs CC adoption curve (indirect impact) |

### Quality / reliability

| Metric | Definition / computation | Telemetry | cc-otel coverage | Display convention |
|---|---|---|---|---|
| Rejected-edit rate by language | rejects ÷ decisions per `language` | `code_edit_tool.decision` | **mart** — `fact_edit_decision` (`Rejected Edits`) | Per-language bar; rising rejection = quality/trust erosion early-warning |
| Tool success / error rate | `tool_result.success` ÷ total; latency from `duration_ms` | `tool_result` events | **raw-only** — `raw.events` has `success_bool`, `duration_ms`, `tool_name`; no mart (`error_type` would need a registry promotion) | Reliability strip: success % + p50/p95 latency by tool |
| API error rate | `api_error` events ÷ `api_request` events | events | **raw-only** — events land in `raw.events`; no mart (`status_code`/`attempt` need registry promotion) | Ops tile on Data Health page, not exec page |
| Session quality survey | `feedback_survey` responses | events (gated by `CLAUDE_CODE_ENABLE_FEEDBACK_SURVEY_FOR_OTEL`) | **raw-only**, low volume; SPACE "S" via telemetry | CSAT tile if volume ever justifies it |
| Change failure rate / defect ratio / PR revert rate | % deploys needing intervention / % bug-fix PRs | CI + issue tracker | **external** — DORA key, DX Quality key; DX uses PR revert rate as AI-quality proxy | Paired with throughput — DORA's stability warning makes this the honest counterweight |
| DORA delivery keys (lead time, deploy freq, CFR, recovery, rework) | Standard DORA definitions | git/CI/CD/incidents | **external** | Anthropic: "use alongside DORA metrics"; separate delivery dashboard |

### Cost / ROI

| Metric | Definition / computation | Telemetry | cc-otel coverage | Display convention |
|---|---|---|---|---|
| Spend (API-equivalent value) per day/user/model | `cost.usage` counter (USD) / `cost_usd` on `api_request` events | metrics + events | **raw-only** — `raw.events.cost_usd` and the `claude_code.cost.usage` rows in `raw.metrics` are ingested; **nothing cost-related in staging/marts/model** (verified by grep) | Anthropic Console: daily spend line alongside user count; per-user "spend this month" |
| Cost per commit / per accepted line / per active hour | spend ÷ output denominators | derived | **raw-only** (falls out once cost is promoted) | Efficiency ratio tiles; trend, not point-in-time |
| Value-vs-seat ratio | API-equivalent value consumed ÷ seat price | cost + seat roster | **raw-only** + `seat_roster` | ITWorx pays flat per-seat (Team Standard/Premium), so `cost.usage` is *value consumed*, not marginal spend — frame as "API-equivalent value vs seat cost", the subscription-plan ROI tile |
| Token usage + cache hit ratio | `token.usage` by type | metrics | **mart** — `fact_api_usage`, `Cache Hit Ratio` | Cache ratio = cost-efficiency KPI; token mix stacked area |
| ROI composite | time saved × loaded dev cost vs seat cost | survey + finance | **survey** + seat data | Single executive tile; DX: base targets on industry data, not vendor claims |

---

## 3. Recommended executive shortlist

Eight metrics, ordered as the exec page should read (adoption → output → quality → cost).
Chosen to span SPACE dimensions (Activity, Efficiency, Performance-proxy, Cost) and to match
what Anthropic/GitHub/DX all put above the fold; everything is telemetry-native except #8's
denominator.

| # | Metric | Status | Display guidance |
|---|---|---|---|
| 1 | **Active users vs paid seats** (28d/window + Δ) | shipped | KPI tile + trend line; idle-seat count as sub-label. The "are we adopting" headline. |
| 2 | **PRs per active user** (+ commits per active user) | model-only gap — divide existing measures | Ratio trend line. Anthropic's headline productivity chart; ratio holds meaning as adoption grows where raw counts mislead. |
| 3 | **Suggestion accept rate** (+ Δ, per-language drill) | shipped | KPI tile with prior-period Δ; language bar on drill. The trust/confidence signal every vendor leads with. |
| 4 | **Lines of code with CC** (added, net) | shipped | Trend + Δ tile. Pair with accept rate so volume is never read alone. |
| 5 | **Active hours per user per day** (user vs cli split) | shipped | Split bar/area. The delegation ratio (cli share rising = leverage increasing) is the differentiated story. |
| 6 | **API-equivalent value per user/day** | **needs cost promotion** (P1 below) | Daily value line alongside DAU (Anthropic Console pattern); per-user value in the user table. |
| 7 | **Value-vs-seat ratio** | needs P1 + seat price constant | Single ROI-flavored tile: "value consumed = N× seat cost". Honest subscription-plan framing without survey data. |
| 8 | **Tool success rate** | **needs fact_tool_outcome** (P2 below) | Small reliability strip (success % + p95 latency); exec-visible because reliability failures kill adoption. |

Deliberately excluded from the exec page: token totals (mechanism, not outcome — keep on ops
pages), subscription-window utilization (capacity planning, keep on its own page), raw session
counts (superseded by active users + ratios), leaderboards as *performance* readings (SPACE/DX/
GitHub all warn against individual-level use — keep the existing top-users visual framed as
adoption coaching only).

## 4. Gaps → promotion candidates (column promotion allowed per #153)

1. **P1 — promote cost.** Add `sum(cost_usd)` to `marts.fact_api_usage` (source column already
   in `staging.stg_api_request`'s underlying `raw.events`; cross-check against
   `claude_code.cost.usage` deltas in `stg_counter_delta`). Unlocks shortlist #6–7 and all
   cost-per-X ratios. Cheapest, highest-value promotion.
2. **P2 — `marts.fact_tool_outcome`.** New mart over `tool_result` events: session_id, date,
   tool_name, success_bool, count, duration p50/p95. `error_type` needs a `meta.column_registry`
   promotion first if error taxonomy is wanted. Unlocks shortlist #8.
3. **P3 — API error rate.** Count `api_error` vs `api_request` events (both already in
   `raw.events`); a Data Health page tile, not exec. `status_code`/`attempt` need registry
   promotion only if breakdown is wanted.
4. **P4 (defer) — `feedback_survey` CSAT.** Gated fleet-side and low-volume; revisit if the
   fleet enables `CLAUDE_CODE_ENABLE_FEEDBACK_SURVEY_FOR_OTEL`.
5. **Out of telemetry reach (needs GitHub integration or surveys, separate decision):** % PRs
   AI-assisted / merge attribution, DORA keys, median time to merge, DXI, time-savings survey.
   Anthropic's own dashboard derives exactly one thing externally — PR merge attribution — so
   cc-otel parity with the vendor dashboard is achievable minus that one metric.

## 5. Caveats to encode in the report itself

- **No single number** (SPACE, GitHub, DX unanimously): always pair volume (LoC, commits) with
  a quality/trust signal (accept rate, rejected-edit rate).
- **Never individual performance evaluation** (SPACE, DX explicit): per-user views are for
  adoption coaching and seat management.
- **DORA's amplifier warning**: AI adoption correlates with throughput gains (2025) but
  *negative* stability; if delivery metrics ever join the report, change-fail/revert rate must
  ride along as the counterweight.
- **Anthropic's contribution metrics are conservative underestimates** (effective-lines
  normalization, >20% rewrites unattributed) — don't benchmark ITWorx absolute numbers against
  Anthropic's published percentages.
