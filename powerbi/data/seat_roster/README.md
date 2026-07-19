# Seat roster drops

IS-provided Claude seat roster consumed by the `seat_roster` semantic-model table
(#116 delivery, #117 modeling decision).

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
- Until #116 delivers the real file, the drop in place is a **stub** (real
  telemetry emails + clearly-marked `stub.idle-seat-*` rows) so measures return
  non-blank values; swap in the real file when it lands.
