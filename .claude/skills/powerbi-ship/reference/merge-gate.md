# Phase 6 — the merge gate

The one guaranteed human stop. The review medium is the **rendered report**,
open live in Desktop on the worktree copy — make the call a fast yes by pairing
the summary with the final screenshots so the human knows exactly which pages
to inspect.

## Sequence

1. Launch Desktop on the worktree `.pbip` (store-install attach pattern,
   `powerbi-tooling.md`), `powerbi-desktop status --wait-seconds 120` until ready.
2. Clear the calc banner if raised (TOM `RequestRefresh(Calculate)` — tooling doc).
3. `screenshot-all` the affected pages at scale 2; attach the PNGs in chat.
4. Post the summary below. **Wait.** No auto-merge.

## Post this summary, then stop

```
## /powerbi-ship summary — #<issue>: <title>

PR:        <url>  (<branch> → main)
Issue:     <one-line restatement of what was asked>
Class:     <report | model | mixed>

Implementation
  - <what changed, 1–3 lines>

Pages verified (screenshots attached; Desktop is open on the worktree copy —
review live, don't Save there)
  - <page> — <what to look at>
  ...

Model verification            (model/mixed only, else omit)
  - <measure> → <ADOMD-verified value / check>  ✓
  ...

Deviations from plan
  - <departure: what + why>   (or: None — plan held)

Self-review
  Spec:    <finding> → <fixed | rejected: reason>   (or: clean)
  Design:  <finding> → <fixed | rejected: reason>   (or: clean)

Local gate:  validate.ps1 <✓> · <other touched gates>
CI:          <checks> → <green | state>

Ready to merge. Reply "merge" to squash-merge, delete the branch, and clean up.
```

## On approval

Close the Desktop instances this run launched (file locks block worktree
removal), then run `scripts/ship/merge.sh <pr> <issue> --worktree <path>` from
the main checkout and finish any `false` step in its JSON by hand. The
worktree's `cache.abf` is discarded with the worktree — never copy it back.

## If the human says no / wants changes

Their note is the next round on the same branch: implement, re-verify with
screenshots, re-run `local-gate.sh`, push, and come back to this gate. Don't
re-open the whole pipeline.
