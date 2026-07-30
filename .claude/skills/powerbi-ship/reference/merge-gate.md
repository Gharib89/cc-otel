# Phase 6 — the merge gate

The one guaranteed human stop. The review medium is the **rendered report**,
open live in Desktop on the worktree copy — make the call a fast yes by pairing
the summary with the final screenshots so the human knows exactly which pages
to inspect.

**Write it uncompressed.** A session-wide output style (a compressed/terse mode
armed by a hook, a brevity instruction) does **not** apply to this summary. It is
the evidence a human approves an irreversible squash-merge on, so it gets full
sentences and the whole template below — no dropped articles, no fragments, no
omitted rows. Same for the disposition lines it carries.

## Sequence

1. Collect the **auto-review** and dispose of every finding (below).
2. Launch Desktop on the worktree `.pbip` (store-install attach pattern,
   `powerbi-tooling.md`), `powerbi-desktop status --wait-seconds 120` until ready.
3. Clear the calc banner if raised (TOM `RequestRefresh(Calculate)` — tooling doc).
4. `screenshot-all` the affected pages at scale 2; attach the PNGs in chat.
5. Post the summary below. **Wait.** No auto-merge.

**Metadata-only class:** skip steps 2–4 — pages are pixel-identical to `main`,
so a screenshot carries no review signal. In the summary, replace "Pages
verified" with the structural evidence: the coverage assertions, and the
`validate.ps1` verdict vs `main`'s baseline. Offer an optional Desktop render
sanity-check (confirm no visual errored from the edit) — don't block on it.
The hard stop stands.

## Auto-review

`copilot-pull-request-reviewer` runs on every PR in this repo without being
asked, so a `desktop-bound` PR carries its comments even though this skill
requests no bot. Read them on merit and fold each into the summary's
**Self-review** block with a disposition, so the human meets findings already
triaged rather than discovering them.

Two calls, both needed — inline threads never appear in `reviews`:

```sh
gh api repos/<owner>/<repo>/pulls/<n>/comments   # inline threads
gh pr view <n> --json reviews                    # top-level review body
```

Reply in-thread at `POST .../pulls/<n>/comments/<id>/replies`, passing the body
via `--input <json-file>`. A `-f body="…"` containing quotes gets shredded by
the shell into `accepts 1 arg(s), received 5`.

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
