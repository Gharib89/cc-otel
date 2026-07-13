# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | --------------------- | ----------------------------------------- |
| `needs-triage`              | `needs-triage`        | Maintainer needs to evaluate this issue   |
| `needs-info`                | `needs-info`          | Waiting on reporter for more information  |
| `ready-for-agent`           | `ready-for-agent`     | Fully specified, ready for an AFK agent   |
| `ready-for-human`           | `ready-for-human`     | Requires human implementation             |
| `wontfix`                   | `wontfix`             | Will not be actioned                      |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the right-hand column to match whatever vocabulary you actually use.

## Dimension labels

Beyond the five canonical states, triage stamps three dimensions per issue (same scheme as the crm repo):

| Dimension | Labels |
| --------- | ------ |
| Kind      | `bug` · `enhancement` · `documentation` · `refactor` · `chore` |
| Size      | `XS` (trivial, one spot) · `S` (surgical, ~1 file) · `M` (multi-file or new path) · `L` (sweep / new module) · `XL` (new subsystem / design-gated) |
| Priority  | `critical` (production-breaking, no workaround) · `high` (broken functionality or active exposure) · `med` (should do) · `low` (nice to have) |
