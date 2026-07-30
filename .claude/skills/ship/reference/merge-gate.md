# Phase 9 — the merge gate

This is the merge gate — the one guaranteed human stop (rationale in the autonomy
contract in SKILL.md). Your job is to make that call a 10-second yes/no by laying
out everything they'd want to check.

**Write it uncompressed.** A session-wide output style (a compressed/terse mode
armed by a hook, a brevity instruction) does **not** apply to this summary. It is
the evidence a human approves an irreversible squash-merge on, so it gets full
sentences and the whole template below — no dropped articles, no fragments, no
omitted rows. Same for the disposition lines it carries.

## Post this summary, then stop

```
## /ship summary — #<issue>: <title>

PR:        <url>  (<branch> → <default-branch>)
Issue:     <one-line restatement of what was asked>
Lane:      <full | small — skipped: integrated test, local suite (CI), self-review (if auto-bot)>

Implementation
  - <what was built, 1–3 lines>
  - tests added/updated: <files / count>

Deviations from plan
  - <departure: what + why, conservative option taken>   (or: None — plan held)

Integrated tests
  - target(s) run: <which, e.g. testcontainers e2e>  → <pass | handed to you>
  - <anything skipped and why>

Self-review (code-review skill)
  - <comment> → <fixed | rejected: reason | n/a>
  ...

Automated review   (copilot-pr-review-loop, unattended)
  - rounds run: <n>/2 → <quiet: no new findings | cap reached, all dispositioned>
  - <finding> → <fixed | declined: reason>
  ...

Local gate:  tests <✓/✗> · lint <✓/✗> · type <✓/✗> · docs <✓/✗> · security-scan <✓/✗/n/a>
Docs-sync:   <ran: files | skipped: reason>
CI:          <checks> → <green | state>

Ready to merge. Reply "merge" to squash-merge, delete the branch, and clean up.
```

Then **wait.** Do not merge until the user explicitly says so. Never use an
auto-merge flag while a review could still be pending — it can merge the instant
CI is green, before a review lands.

## On approval

Run `scripts/ship/merge.sh <pr> <issue> --worktree <path>` from the main
checkout. It performs the whole land-and-clean ritual and reports each step in
its JSON: squash-merge (the squash **subject** is the PR title — release tooling
reads it, so the title must be the Conventional-Commit line), re-verify the PR
actually reached `MERGED`, verify the `Closes #<issue>` auto-close fired (closes
manually if not), copy gitignored env files out of the worktree, delete the
remote branch explicitly, remove the worktree, force-delete the local branch (a
squash-merged branch isn't an ancestor of the default branch), and ff-only pull.
Any `false` in the JSON → finish that step by hand before reporting done.

## If the user says no / wants changes

Treat their note as the next round of work: apply it on the same branch, re-run
the local gate, and come back to this gate. Don't re-open the whole pipeline.
