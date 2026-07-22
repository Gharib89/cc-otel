# Corp-Domain Filtering & Automatic Identity Normalization (live path)

This project does **not** filter non-`itworx.com` emails out of the live ingest,
and does **not** build automatic identity-normalization machinery (alias-collapse
mapping tables, marts-layer domain gates) beyond the case/trim already done at the
sink.

## What was requested

Issue #188 asked where a corp-domain / identity rule should live so daily data is
"clean" without manual purges — proposing either dropping non-`itworx.com`
`user_email` at the sink, or excluding + alias-collapsing them in the marts layer.

## Why this is out of scope

The premise — that non-itworx emails arriving live are noise to be filtered — is
inverted from the actual design intent:

1. **Surfacing personal-login usage is the goal, not a defect.** A developer
   emitting telemetry under a non-corp identity (e.g. a `gmail.com` login) is a
   signal worth *seeing* in the report, not hiding. Dropping it at the sink or
   masking it in the marts would silently discard exactly the finding we want. The
   live report intentionally shows these rows.

2. **Casing/whitespace is already handled — nothing more is needed.** The sink
   normalizes every identity on ingest:

   ```python
   # sink/src/cc_otel_sink/parser.py — normalize_email
   cleaned = value.strip().lower()   # applied to every user_email
   ```

   Mixed casing and stray whitespace can never reach `raw`. No further
   normalization layer is warranted.

3. **True aliases (same person, different local-part) were a one-time POC bug, not
   a recurring class.** The `gharib@itworx.com` vs `ahmed.gharib@itworx.com` split
   came from a known POC-side data bug with a known-correct target, recovered once
   by an ad-hoc UPDATE. Live identities come straight from the corp machine's
   exporter, so this does not recur — building an alias-mapping table to defend
   against a resolved one-off is speculative machinery.

4. **The `raw` backfill-vs-live asymmetry is intentional.** The backfill path
   (`scripts/backfill/sql/load.sql`, #162) filters out old POC data-quality noise
   before it reaches `raw`; the live sink keeps everything. This is by design: we
   surface only *new* live data faithfully and deliberately do **not** carry old
   POC DQ issues forward. "Make both paths symmetric" is not a goal.

The blob reservoir (ADR-0005) — not `raw` — is the faithful audit copy of what was
emitted, so no domain rule needs to relocate to protect a `raw` faithfulness
property that `raw` was never meant to guarantee.

## Prior requests

- #188 — "Live-sink / marts domain filter + corp-identity normalization"
