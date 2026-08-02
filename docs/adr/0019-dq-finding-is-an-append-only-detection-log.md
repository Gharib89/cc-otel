# `dq_finding` is an append-only detection log; consumers read the current cycle

**Status:** accepted. Records a decision first taken in #15 (retention) and never written where a
reader would find it. Amends no ADR.

`marts.refresh_all()` runs hourly and re-inserts a row for every still-true DQ condition. There is
no `TRUNCATE`, no `DELETE`, no `ON CONFLICT`. The table therefore holds `cycles × conditions` rows,
not one row per finding: when this was measured (#374), 3,296 rows carried roughly 20 conditions,
`multi_email_session` alone showing 2,617 rows for 12 distinct findings across 312 cycles, growing
~150 rows/day.

Nothing said so. #15's resolution settled the retention half — "`dq_finding` untrimmed under the
5-year policy — findings are data provenance" — but it lives in a closed ticket's comment, framed as
a lifecycle question, and it never addressed how the table should be *read*. So the row count reads
as a finding count to everyone who meets it. It already has: #364's body cited 2,509 as a count of
offending session-days and reasoned about precedent from it, and the `pg_health` page carried a
`DQ Findings` card defined as `COUNTROWS ( dq_finding )` — a number that grew every hour while the
data quality it claimed to measure stood still.

## Decisions

**The table stays append-only.** A row is a *detection*; the condition it detects is the *finding*.
The log is provenance — it answers "was this already true in March, and when did it start" — and
that is worth more than a tidy row count. Volume does not argue otherwise: ~150 rows/day is ~55k a
year, against raw tables projected at ~180M rows over five years (#15).

**`detected_at` is the cycle key.** `refresh_all()` is a `FUNCTION` with no `COMMIT`, so it runs in
a single transaction, and `detected_at` defaults to `now()` — transaction time. Every row of a cycle
therefore carries one identical timestamp, and `MAX(detected_at)` identifies the newest cycle
exactly. No cycle-id column is needed. (`mart_refresh_log` deliberately differs: it uses
`clock_timestamp()` because it times each matview individually.)

**Consumers read `marts.dq_finding_current`,** a plain view over the newest cycle. It is the answer
to "what is wrong now"; the table is the answer to "what has ever been wrong". The Power BI model
reads the view — the whole `pg_health` DQ surface (the count card, the by-type chart, the grid) is a
now-question. Named `_current` after `dim_seat_current`, which already means the now-slice of a
historized object in this schema.

**A finding's identity is not recorded, and that is deferred, not solved.** `details` is a payload,
not a key: for over half the detector types it carries a volatile measurement — `abs_diff_usd`,
`last_activity_date`, `record_count`, an observation share — that moves every cycle. So
`(finding_type, details)` is not a natural key, and "has this cleared / how long has it stood"
cannot be asked today. The subject each detector groups by is already written in its own `GROUP BY`
and is simply discarded at insert. Recovering it is mechanical but touches every detector, and
nothing yet asks the question, so it waits.

**Not every finding is a defect, and the current count cannot reach zero.** `seat_boundary_basis`
("not an error — it makes the inferred share of the timeline measurable"), `cumulative_value_kind`
(an exclusion recorded so it is never silent), `owner_email_mismatch` ("an observation, never a
control") and `multi_email_session` are standing gauges: permanently true by design. The other eight
types drain — someone can act until they reach zero. The classification is settled here but not
implemented, for the same reason as the subject: it needs a column on the table.

## Considered options

**Dedupe on insert — a findings register.** An upsert on a natural key, bumping `last_seen`, so one
row means one finding. Rejected: it contradicts #15's provenance ruling by rewriting history in
place, so "what did the table say at 14:00 on 12 July" stops being answerable; the natural key it
needs does not exist yet; and it would buy a cosmetic row count at the price of the one property
the table currently has for free.

**A documented read pattern and nothing else.** A `CONTEXT.md` note telling readers to filter to the
latest cycle. Rejected: the defect is a live card on a page people read, and prose does not fix a
DAX measure. It also leaves every future consumer one forgotten `WHERE` clause away from the same
mistake.

**Trim the log.** Retention would cap the growth. Rejected outright by #15, and it treats a symptom
— a trimmed log still reports detections as findings, just fewer of them.

## Consequences

The `DQ Findings` card drops from a four-digit number that grew hourly to roughly 20, and moves only
when data quality moves. `Last DQ Finding` — `MAX ( detected_at )` — degenerates over a
current-cycle source into the last refresh time, duplicating `Last Mart Refresh` on the same card
band, so that tier becomes the count of distinct `finding_type` current instead.

The card still counts gauges among defects, so it cannot show a clean bill of health. That is a
known and documented wart until the classification lands.

The log keeps growing, by design. It is queried through `psql` and the `analysis/` DuckDB lab, not
the report.
