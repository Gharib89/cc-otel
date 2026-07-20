# Power BI CI gate assets

Config + helper for `.github/workflows/ci-powerbi.yml`, which validates the
`powerbi/` PBIP/PBIR report and TMDL semantic model. All tool versions are pinned
in the workflow. The `fab-inspector` and BPA rulesets are vendored here (no runtime
dependency on upstream `master`). The `pbir-schema` job is the one exception: it
fetches the Fabric JSON schemas from `developer.microsoft.com` at runtime, pinned
by the exact `$schema` version each report file declares.

| File | Job | Source |
|---|---|---|
| `validate-pbir.mjs` | `pbir-schema` | project-native — validates each PBIP/PBIR file against the Fabric JSON schema it declares in `$schema` (ajv `8.17.1`, fetches the schema + `$ref` closure over HTTP) |
| `gotchas-lint.mjs` | `pbir-schema` | project-native — the statically checkable `pbir-gotchas` skill traps as lint rules (#135); pure node, no deps |
| `fab-inspector-rules.json` | `fab-inspector` | vendored from `NatVanG/fab-inspector` `v3.4.0` `Rules/Base-rules.json` (report visual-quality rules) |
| `BPARules.json` | `bpa` | vendored from `TabularEditor/BestPracticeRules` `BPARules-PowerBI.json` |

## `BPARules.json` local edit

One rule is downgraded from upstream: **`META_AVOID_FLOAT`** severity `3 → 2`.
Tabular Editor 2 `-A` fails CI only on severity-3 (Error) violations. The semantic
model uses `double` columns intentionally for cost/rate/token aggregates (#90), so
enforcing "no floats" as a hard error would fail the gate on the already-reviewed
model. Downgraded to a warning (still reported, non-blocking). The other two
severity-3 rules — `DAX_DIVISION_COLUMNS` (use `DIVIDE`) and the auto-date/time
rule (`DIABLE_AUTO_DATE/TIME`, an upstream ID typo kept verbatim so it correlates
with BPA output) — remain hard errors, so the gate can still go red.
