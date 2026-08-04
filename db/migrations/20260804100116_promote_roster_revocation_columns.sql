-- migrate:up

-- Promote IS's revocation headers out of `extra` into real snapshot columns (#419, parent #290,
-- follow-up to #291). The 2026-08-02 drop first carried `revoked_subscription_1/2` and
-- `revoke_date_1/2`; until now they landed verbatim in `ref.seat_roster_snapshot.extra`, so
-- nothing was lost -- this makes them queryable at the grain they belong to.
--
-- They are per-subscription revocation *events* (which subscription, and when), not a
-- person-level status: the drop that introduced them records 42 Github Copilot revocations
-- against exactly one Claude seat, while four people vanished from the file outright with no
-- revocation record at all. So they sit at assignment grain, unpivoted per sequence exactly
-- like `subscription_N` / `assignment_date_N`, and they do not replace revocation-by-absence.
--
-- Nullable with no backfill and no default: snapshots are immutable (ADR-0009), so the drops
-- already landed keep their `extra` copy and read NULL here. Only drops loaded from now on
-- populate the columns.
--
-- `revoked_subscription_raw` is deliberately unnormalized, with no `revoked_seat_tier`
-- counterpart: telling a revoked Claude subscription from a revoked Github Copilot one needs
-- the raw value, because `normalize_tier` strips the `Claude ` prefix and passes every other
-- product through unchanged.
ALTER TABLE ref.seat_roster_snapshot
ADD COLUMN revoked_subscription_raw TEXT,
ADD COLUMN revoke_date DATE;

-- migrate:down

ALTER TABLE ref.seat_roster_snapshot
DROP COLUMN revoked_subscription_raw,
DROP COLUMN revoke_date;
