# Why the wrapper utilization gauges never reach the interim sink

**Ticket:** #71 (part of map #68). **Date:** 2026-07-16. **Method:** `/diagnose` — reproduce → evidence → root cause.

> **This replaces an earlier, WRONG diagnosis.** The prior version concluded the
> gauges die because the statusline payload carries no `rate_limits` block — a
> field it claimed exists "only for Claude.ai Pro/Max" and is therefore "not
> fixable client-side." **That conclusion is false and is rejected.** It trusted a
> general sentence in the Claude Code docs over the POC database, which is the
> ground truth for what these exact ITWorx seats emit. The POC proves these seats
> **do** emit `rate_limits`, that a statusline wrapper **did** capture it
> successfully for weeks, and that the loss is a **client-side regression in our
> interim implementation**, not a licensing property.

## Question

`claude_code.usage.utilization` and `claude_code.usage.reset_in_seconds` never
land in interim (`raw.metrics` = 0 rows for scope `cc-otel.statusline`;
`staging.stg_utilization_segments` = 0 → `fact_usage_window` +
`fact_utilization_hourly` permanently empty). Every native Claude Code metric
flows. Why?

## Answer (one line)

The gauges are **statusline-wrapper metrics** (there is no native OTel metric for
them). The interim wrapper builds and POSTs them correctly **only when it can see
`OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_HEADERS` in its environment**
— but per ADR-0003 it re-bakes no endpoint/token of its own and the baked
`statusLine.command` sets none, so when those env vars are absent from the
statusline subprocess the wrapper silently POSTs to `http://localhost:4318` with
no auth and the push dies. **Confirmed client-side-fixable** (the POC wrapper
carried its own endpoint and worked on these same seats and Claude Code versions).

---

## Ground truth: the POC database (sibling `otel` DB on the POC server)

The POC is the authoritative record of what these ITWorx seats emit. Query
(`otel` DB, `public.metrics`) — **captured while the POC server was live**; that server
was archived and deleted on 2026-07-28 (ADR-0016), so re-running this needs the dump
restored from the prod `archive` container, and the numbers below stand as recorded:

```
             metric_name             |     scope_name     |  rows  |         first_seen         |         last_seen          | users
-------------------------------------+--------------------+--------+----------------------------+----------------------------+------
 claude_code.usage.utilization       | cc-otel.statusline | 269138 | 2026-05-21 14:45:54.45+00  | 2026-07-15 23:24:46.679+00 |   10
 claude_code.usage.reset_in_seconds  | cc-otel.statusline | 269135 | 2026-05-21 14:45:54.45+00  | 2026-07-15 23:24:46.679+00 |   10
 claude_code.context.used_percentage | cc-otel.statusline | 135844 | 2026-05-21 14:45:54.45+00  | 2026-07-15 23:24:46.679+00 |   10
```

Facts this establishes:

1. **These seats DO emit `rate_limits`.** 10 distinct ITWorx users produced
   ~269 k utilization datapoints. The prior "Pro/Max only" claim is empirically
   false for this fleet. (Claude Code's own statusline docs say `rate_limits`
   "appears only for Claude.ai subscribers (Pro/Max)"; ITWorx's Team-Standard +
   Premium OAuth seats evidently receive it too. Ground-truth data overrides the
   doc's general wording — this is exactly the trap the prior diagnosis fell into.)
2. **The metrics came from a statusline wrapper, not native Claude Code.** The
   `scope_name` is `cc-otel.statusline` (a wrapper-defined instrumentation scope),
   never `com.anthropic.claude_code`. Claude Code has **no** native OTel metric
   for rate-limit utilization — confirmed against the current monitoring docs.
   Utilization is *only* obtainable by parsing the statusline JSON.
3. **The window naming matches today's wrapper exactly.** POC datapoints carry
   `window` ∈ {`5h`, `7d`, `7d_sonnet`}. That is precisely the mapping the interim
   wrapper produces (`five_hour`→`5h`, `seven_day`→`7d`, `seven_day_sonnet`→
   `7d_sonnet`). So the interim wrapper's parsing/label logic is *not* the bug.

Sample POC row (identity lives in datapoint **attrs**, resource is bare):

```
metric_name | claude_code.usage.utilization
value       | 47
user_email  | mariam.okasha@itworx.com
attrs       | {"window":"5h","user.email":"mariam.okasha@itworx.com","model":"claude-opus-4-8[1m]", ...}
resource    | {"service.name":"claude-code"}
scope_name  | cc-otel.statusline
```

(The POC wrapper was a *richer* implementation: it also emitted
`context.used_percentage`, `session.duration_ms`, `session.api_duration_ms`, and
a dozen datapoint attributes. The interim wrapper is a deliberate minimal
rewrite per ADR-0003 — two gauges, `window` attr only, identity in the resource.)

### The before/after that isolates the regression to our pipeline change

For `ahmed.gharib@itworx.com` (same machine, same seat as the interim tester):

- **POC utilization:** 213,002 rows, continuous **2026-05-21 → 2026-07-14 10:29**.
- **Interim native metrics start:** **2026-07-14 12:12** (2 h after POC stops).
- Across the POC window ahmed ran Claude Code **v2.1.146 → v2.1.205** (from the
  `com.anthropic.claude_code`-scope `cc_version` values), and utilization flowed
  **through every one of them**.

The same physical seat emitted utilization fine until the moment it cut over to
interim, then went dark while its native metrics kept flowing. The only thing
that changed is **our wrapper + endpoint**, not the seat tier or Claude Code.

Because v2.1.128 is the release where Claude Code stopped propagating `OTEL_*`
env vars to subprocesses, and the POC wrapper kept working all the way to
v2.1.205, **the POC wrapper cannot have depended on inherited `OTEL_*`** — it must
have carried its own endpoint/token. The interim wrapper does the opposite.

---

## Interim database: gauges absent, native metrics healthy

`raw.metrics` (interim `ccotel-pg-interim` / `cc_otel`):

```
             metric_name             |        scope_name         | count |            last
-------------------------------------+---------------------------+-------+----------------------------
 claude_code.active_time.total       | com.anthropic.claude_code |   249 | 2026-07-16 06:47:58+00
 claude_code.token.usage             | com.anthropic.claude_code |   252 | 2026-07-16 06:47:58+00
 claude_code.cost.usage              | com.anthropic.claude_code |    63 | 2026-07-16 06:47:58+00
 ... (all native metrics present) ...
```

- **No `cc-otel.statusline` scope row has EVER reached interim** (`SELECT DISTINCT
  scope_name` returns only `com.anthropic.claude_code` and NULL).
- All interim traffic is from a single tester, `ahmed.gharib@itworx.com` — interim
  is a parallel-cutover validation, not a full fleet yet.

So the wrapper's POST never arrives. The failure is upstream of the collector.

---

## The stage where the gauges die

The wrapper resolves its OTLP target from the environment
(`installer/cc-otel-wrapper.mjs:189-203`):

```js
export function resolveEndpoint(env = process.env) {
  const override = env.STATUSLINE_OTLP_ENDPOINT;          // set only by tests
  if (override && override.trim()) return override.trim();
  const base = env.OTEL_EXPORTER_OTLP_ENDPOINT;           // inherited from CC
  if (base && base.trim()) return base.trim().replace(/\/+$/, "") + "/v1/metrics";
  return "http://localhost:4318/v1/metrics";              // <-- fallback when absent
}
export function resolveHeaders(env = process.env) {
  const override = env.STATUSLINE_OTLP_HEADERS;           // set only by tests
  const raw = override && override.trim() ? override : env.OTEL_EXPORTER_OTLP_HEADERS;
  return parseKv(raw);                                    // {} (no auth) when absent
}
```

ADR-0003 states this by design: *"The OTLP metrics endpoint and bearer are reused
from the machine's existing telemetry env … the wrapper re-bakes no secret of its
own."* (`docs/adr/0003-wrapper-minimal-contract.md:9`)

The baked delivery sets **no** `STATUSLINE_*` and **no** per-command env — the
statusLine command is literally `node "C:/Program Files/ClaudeCode/cc-otel-wrapper.mjs"`
(`installer/install.ps1:157-168`; decoded from the built `installer/dist/install.ps1`
managed-settings blob). The wrapper is therefore **100 % dependent on inheriting
`OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_HEADERS`** from the Claude Code
process into the statusline subprocess.

When that inheritance does not happen, `resolveEndpoint()` returns
`http://localhost:4318/v1/metrics` and `resolveHeaders()` returns `{}`: the wrapper
POSTs to a non-existent local collector with no bearer, `fetch` throws, and the
silent-failure posture swallows it. Zero rows, no error surfaced.

---

## Reproduction (feedback loop)

Ran the **real** `installer/cc-otel-wrapper.mjs` against a realistic statusline
payload (`rate_limits.{five_hour,seven_day,seven_day_sonnet}.{used_percentage,resets_at}`),
`STATUSLINE_DEBUG_LOG` on, differential on the endpoint env:

**A — `OTEL_*` absent (the production statusline-subprocess case):**
```
payload keys: session_id,model,rate_limits
  rate_limits.five_hour: {"used_percentage":47,"resets_at":...}
pushBestEffort threw: fetch failed          <-- POST to localhost:4318, no listener
=> mock collector received 0 POSTs
```

**B — `OTEL_EXPORTER_OTLP_ENDPOINT` + `OTEL_EXPORTER_OTLP_HEADERS` present:**
```
payload keys: session_id,model,rate_limits
otlp post ok: status=200 metrics=2 points=6   <-- POSTs correctly built OTLP/JSON
=> mock collector received 1 POST at /v1/metrics, CT application/json, Bearer <token>
```

The wrapper's body builder and POST are **correct**; the outcome flips entirely on
whether the endpoint/token env is visible.

## The fix path is proven to work end-to-end

Authenticated OTLP/JSON POST to the **real interim collector** carrying the
wrapper's exact scope + metric (zero datapoints, so it inserts nothing):

```
POST https://ccotel-app-interim.<...>.azurecontainerapps.io/v1/metrics
  Content-Type: application/json,  Authorization: Bearer <interim fleet token>
  {"resourceMetrics":[{...scope "cc-otel.statusline", metric "claude_code.usage.utilization"...}]}
=> HTTP 200  {"partialSuccess":{}}
POST with a wrong bearer  => HTTP 401
```

So the collector's HTTP receiver accepts JSON (not only the native exporter's
`http/protobuf`), the fleet bearer authenticates, and the sink parser
(`sink/src/cc_otel_sink/parser.py:164-225`) stores any gauge datapoint and maps
`window` → `usage_window` with no scope/name allowlist. The staging + mart layer
also matches: the column registry (`db/migrations/20260713170005_seed_column_registry.sql:47-48`)
and the utilization mart (`db/migrations/20260713170010_create_marts_utilization.sql`;
`db/schema.sql:573-574`) key on `claude_code.usage.utilization` /
`claude_code.usage.reset_in_seconds` by `metric_name`, joining on `user_email` +
`usage_window` + `ts` — exactly the fields the wrapper emits (both gauges share one
`timeUnixNano`, so the `u.ts = r.ts` join holds). **Nothing between the collector and
the marts blocks utilization.** The single broken link is getting a valid
endpoint+token into the wrapper's process.

---

## Root cause

The interim wrapper obtains its OTLP endpoint + bearer **only** by inheriting
`OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_HEADERS` (ADR-0003), and the
installer delivers **no** `STATUSLINE_*`/endpoint of its own on the statusLine
command. Whenever those `OTEL_*` vars are not present in the statusline
subprocess, the wrapper falls back to an unauthenticated `localhost:4318` POST
that cannot succeed — silently. The POC wrapper avoided this by carrying its own
endpoint/token, which is why it kept emitting across the same seats and Claude
Code versions right up to the interim cutover.

### Why the `OTEL_*` env is not there (two readings, both our-side and fixable)

Both are consistent with all evidence, and the recommended fix covers both:

- **(most likely) Claude Code withholds `OTEL_*` from the statusLine subprocess.**
  Since v2.1.128 Claude Code stopped propagating `OTEL_*` env vars to spawned
  subprocesses (`docs/research/claude-code-otel-signals.md:139`). The statusLine
  command is such a subprocess. The interim installer *does* bake the wrapper as
  the statusLine command (decoded managed-settings blob), so the wrapper is
  deployed and firing — but blind, POSTing to `localhost:4318`. This is the
  reading the POC timeline points to: the POC wrapper kept emitting across
  v2.1.146→v2.1.205 (all post-2.1.128), which is only possible if it carried its
  own endpoint/token rather than relying on inherited `OTEL_*`. A clean fleet
  rollout of the *current* wrapper would **not** fix it.
- **(also possible) the statusLine wrapper isn't rolled out on the interim tester's
  machine yet.** Interim has a single tester whose native metrics come from the
  managed-settings `env` block; if his statusLine still runs the older
  settings-clobbering interim setup (ADR-0003 mentions one) or a manual env-only
  config, no wrapper fires at all. Then deploying the current wrapper as-is only
  works if reading (1) is false — which the POC timeline argues against.

The wrapper's own test suite bakes in the fragile assumption:
`installer/test_wrapper.mjs:471` ("resolves the endpoint from `OTEL_EXPORTER_OTLP_*`
env (no `STATUSLINE_*` set)") asserts the production path *is* inherited `OTEL_*`,
and `:526` ("exits 0 when the collector is unreachable") locks in the silent
failure that hides the `localhost` fallback.

## Recommended fix (client-side, in our implementation)

Make the wrapper self-sufficient for its OTLP target instead of trusting inherited
`OTEL_*` — mirror what the working POC wrapper did:

1. **Bake the endpoint + token into the statusLine delivery.** In
   `installer/install.ps1` `Get-WrapperStatusLineCommand`, emit a command that
   sets the wrapper's own `STATUSLINE_OTLP_ENDPOINT` (full `/v1/metrics` URL) and
   `STATUSLINE_OTLP_HEADERS` (`Authorization=Bearer <fleet-token>`) before
   invoking node — these overrides already win in the wrapper and are independent
   of Claude Code's subprocess env handling. Both values already exist in the
   baked managed-settings `env` block; reuse them so there is one source of truth.
   *(Preferred: keeps the wrapper's silent, dependency-free posture.)*
2. **Or** have the wrapper read `managed-settings.json` (it already resolves
   `CLAUDE_CONFIG_DIR` / the install root) and pull `env.OTEL_EXPORTER_OTLP_ENDPOINT`
   / `env.OTEL_EXPORTER_OTLP_HEADERS` from there when the process env lacks them —
   the file is the authoritative fleet config and always sits next to the wrapper.

Update ADR-0003: the "reuse the machine's telemetry env" clause is the defect —
the statusline subprocess is not a reliable carrier of `OTEL_*`. Add a regression
test that runs the wrapper with `OTEL_*`/`STATUSLINE_*` both unset and asserts it
resolves a real endpoint (from managed-settings), not `localhost:4318`.

## Verification once fixed

Deploy to one seat, run a real session with `rate_limits` present, confirm
`raw.metrics` gains `cc-otel.statusline` rows and `staging.stg_utilization_segments`
> 0, then `marts.refresh_all()` populates `fact_usage_window` /
`fact_utilization_hourly`. The interim collector already 200s these POSTs.

## Answer to the blocked viability question (#72)

**Restoring utilization is client-side-fixable and does not depend on seat tier.**
The POC captured it on these exact ITWorx seats for weeks via a self-contained
statusline wrapper; the interim regression is purely that our minimal rewrite
delegated the endpoint/token to inherited `OTEL_*` env that the statusline
subprocess does not reliably carry.
