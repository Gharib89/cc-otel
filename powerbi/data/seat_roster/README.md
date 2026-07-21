# Seat roster drops

Claude seat roster consumed by the `seat_roster` semantic-model table
(#117 modeling decision). Derived from telemetry — the roster is regenerated
from post-cleanup `marts.dim_user` (itworx emails), superseding the IS-file
plan (#116, via the #153 shine map / #154).

- **File convention:** `seat_roster_YYYY-MM-DD.csv` — one file per drop, dated
  as-of. The model's M query always loads the **latest** drop by filename sort;
  adding a new drop is data-only (no model edit).
- **Schema (locked in #117):** `user_email,seat_tier` — UTF-8, comma-delimited,
  header row.
- **History:** every drop is retained on disk so a future SCD2 (tier history)
  stays possible; the model itself is Type 1 (latest snapshot only).
- **Git:** `*.csv` here is gitignored — roster files carry employee emails and
  stay off the repo. Only this README is tracked.
- **Path:** the `seat_roster` M partition reads this folder by **absolute path**
  (`D:\projects\cc-otel\powerbi\data\seat_roster`) — Power Query's `Folder.Files`
  takes no relative paths, and the model already carries machine/env-specific
  source values (the Postgres hostname). Authoring/refresh happens on the one
  Desktop authoring machine by convention; adjust the partition source if that
  ever moves.
- **Generating a drop:** query interim `marts.dim_user` for itworx emails and
  emit one row per user — `ahmed.gharib@itworx.com` and `hadeel.sharaf@itworx.com`
  are `Premium`, every other user `Standard`. No stub rows (the #163 regeneration
  dropped the earlier `stub.idle-seat-*` placeholders).
