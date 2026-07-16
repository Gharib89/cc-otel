# Why the wrapper utilization gauges never reach the sink

**Ticket:** #71 (part of map #68). **Date:** 2026-07-16. **Method:** `/diagnose` — reproduce → evidence → root cause. **Diagnosis only; nothing fixed.**

## Question

`claude_code.usage.utilization` and `claude_code.usage.reset_in_seconds` never land (0 rows in `raw.metrics`; `staging.stg_utilization_segments` = 0, so `fact_usage_window` + `fact_utilization_hourly` are permanently empty). Every other Claude Code signal flows. Why?

## Answer (one line)

The statusline JSON payload on this fleet carries **no `rate_limits` block**, so the wrapper short-circuits before building or POSTing any OTLP body. `rate_limits` is a Claude.ai **Pro/Max**-only field; this fleet authenticates as an OAuth **organization** (Team/Enterprise seats), which does not receive it. **Not fixable client-side** — it is a property of the billing/seat tier, not a wrapper bug.

---

## Stage where the gauges die

**Stage: `buildOtlpBody()` returns `null` on the missing `rate_limits` block, and `pushBestEffort()` returns before any HTTP call.** The wrapper never builds an OTLP body and never touches the network for these gauges. Every other signal is emitted by Claude Code's own OTel exporter, which is unaffected.

`installer/cc-otel-wrapper.mjs:251-254` — the hard gate:

```js
export function buildOtlpBody(payload, nowMs = Date.now(), identity) {
  if (!payload || typeof payload !== "object") return null;
  const rl = payload.rate_limits;
  if (!rl || typeof rl !== "object") return null;   // ← no rate_limits ⇒ null
```

`installer/cc-otel-wrapper.mjs:382-386` — `null` body ⇒ silent return, no POST, throttle file untouched:

```js
const body = buildOtlpBody(payload);
if (!body) {
  debug("no rate_limits in payload — skip push");
  return;
}
```

The header comment states this is by design (`installer/cc-otel-wrapper.mjs:26`): *"A payload with no `rate_limits` block triggers no HTTP call."*

## Evidence

### 1. Code path — confirmed short-circuit (no HTTP)
Above. Regression test already pins the behavior — `installer/test_wrapper.mjs:535`:

```js
test("end-to-end: no rate_limits block → no HTTP call at all", async () => {
  ...
  const { code } = await runWrapper(
    JSON.stringify({ session_id: "abc", model: { id: "x" } }), ...);
  assert.equal(code, 0);
  assert.equal(received.length, 0);   // collector received nothing
});
```

### 2. Live reproduction (this machine, real wrapper, `STATUSLINE_DEBUG_LOG` on)
Fed a realistic statusline payload with `context_window` but no `rate_limits`:

```
input: {"session_id":"repro-1","model":{"id":"claude"},"context_window":{"used_percentage":40}}
debug log:
  payload keys: session_id,model,context_window
  no rate_limits in payload — skip push
exit=0
throttle file: NOT created  → push path never reached (throttleAllows would have written it)
```

The wrapper exits 0 (silent posture), builds no body, makes no POST. The throttle file's absence proves execution stopped at the `!body` guard, upstream of `throttleAllows()` and `postOtlp()`.

### 3. Interim DB — the two gauges are absent; native metrics flow
`raw.metrics` (interim, `ccotel-pg-interim` / `cc_otel`):

```
metric_name                        rows
claude_code.token.usage            105
claude_code.active_time.total       94
claude_code.cost.usage              26
claude_code.lines_of_code.count      8
claude_code.code_edit_tool.decision  5
claude_code.session.count            5
claude_code.commit.count             1
--- utilization / reset_in_seconds:  0
staging.stg_utilization_segments:    0
```

Seven native metric classes land; the two wrapper gauges are the only absent ones. This isolates the failure to the wrapper's `rate_limits` source, not the sink/collector/network (those carry every native metric fine).

### 4. Fleet auth-mode fingerprint (DB, counts only — no PII pulled)
Of 255 `raw.metrics` rows (1 is a null-identity probe), **254 carry `user_email`, `user_account_id`, and `organization_id`**. All three are populated only under **OAuth-authenticated, org-scoped** login — not bare `ANTHROPIC_API_KEY`/Console billing (which would not stamp `user.email`). So the fleet logs in via OAuth **within an organization** (Team/Enterprise seats), yet produced **0** `rate_limits`-derived rows across days of real sessions.

### 5. Authoritative condition for `rate_limits` (official Claude Code docs)
`https://code.claude.com/docs/en/statusline.md` — the statusline stdin JSON includes a top-level `rate_limits` block (`five_hour` / `seven_day{,_sonnet,_opus}` → `used_percentage` + `resets_at`), gated:

> "**rate_limits: appears only for Claude.ai subscribers (Pro/Max) after the first API response in the session.**"

> "This field is only present for Claude.ai subscribers (Pro/Max) after the first API response."

So `rate_limits` is **absent** for API-key/Console billing, Bedrock, and Vertex — and the tier that carries it is specifically **Pro/Max**.

---

## Root cause

The wrapper is behaving exactly as designed. Its two gauges are derived **solely** from the statusline payload's `rate_limits` block (ADR-0003; wrapper header lines 6-9). That block only exists for Claude.ai **Pro/Max** subscribers. This fleet authenticates as an OAuth **organization** (evidence #4: `organization_id` populated on 254/254 identified rows) — Team/Enterprise seats, which are subscription seats (consistent with `CONTEXT.md:37` "subscription seats make cost_usd misleading") but are **not** the Pro/Max tier the statusline docs name as the sole carrier of `rate_limits`. The block therefore never appears in the payload, and the wrapper correctly emits nothing.

The timing caveat ("after the first API response") is not the cause: statusline refreshes fire continuously through a session and the throttle is only 5 min/machine, so any session that ever received `rate_limits` would have pushed it on a later refresh. Zero rows fleet-wide over days means the block is **never** present — a tier condition, not a race.

**Design-premise gap:** ADR-0003's premise — "subscription rate-limit utilization exists only in the statusline JSON" — is correct about *where* the data lives, but the wrapper only yields data when seats are **Pro/Max**. The design conflated "subscription seats" (true for this fleet — hence cost is excluded) with "the Pro/Max tier that exposes `rate_limits` in the statusline" (false for an org/Team/Enterprise fleet).

## Fixable client-side?

**No.** This is a fundamental limitation of the fleet's billing/seat tier, not a wrapper defect:

- The wrapper cannot synthesize data Claude Code never provides. No code change makes `rate_limits` appear in a payload that does not contain it.
- The only way these gauges populate is if the fleet's Claude Code sessions authenticate as **Claude.ai Pro/Max** — a licensing/identity decision outside this repo.
- Everything downstream (`stg_utilization_segments`, `fact_usage_window`, `fact_utilization_hourly`) is correct-but-starved; it will populate the moment `rate_limits` ever arrives, and no plumbing fix will make it arrive on the current tier.

**Feeds the viability decision (#72):** the utilization/limits mart is unachievable on the fleet's current OAuth-org seat tier. Options are (a) drop the utilization gauges + their marts from scope, or (b) move (some) seats to Pro/Max — an org licensing change, HITL with Ahmed.
