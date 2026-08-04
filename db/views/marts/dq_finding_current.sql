-- Canonical definition for marts.dq_finding_current.
-- Source of truth for the view body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name dq_finding_current
-- Verified against pg_views.definition by --check (CI + local gate).
CREATE OR REPLACE VIEW marts.dq_finding_current AS
 WITH cycle AS (
         SELECT c.detected_at,
            row_number() OVER (ORDER BY c.detected_at) AS cycle_seq
           FROM ( SELECT DISTINCT dq_finding.detected_at
                   FROM marts.dq_finding) c
        ), detection AS (
         SELECT DISTINCT f_1.finding_type,
            f_1.subject,
            c.cycle_seq
           FROM (marts.dq_finding f_1
             JOIN cycle c ON ((f_1.detected_at = c.detected_at)))
        ), island AS (
         SELECT d.finding_type,
            d.subject,
            d.cycle_seq,
            (d.cycle_seq - row_number() OVER (PARTITION BY d.finding_type, d.subject ORDER BY d.cycle_seq)) AS island_key
           FROM detection d
        ), streak AS (
         SELECT i.finding_type,
            i.subject,
            min(c.detected_at) AS standing_since
           FROM (island i
             JOIN cycle c ON ((i.cycle_seq = c.cycle_seq)))
          GROUP BY i.finding_type, i.subject, i.island_key
         HAVING (max(i.cycle_seq) = ( SELECT max(cycle.cycle_seq) AS max
                   FROM cycle))
        ), first_seen AS (
         SELECT dq_finding.finding_type,
            dq_finding.subject,
            min(dq_finding.detected_at) AS first_detected_at
           FROM marts.dq_finding
          GROUP BY dq_finding.finding_type, dq_finding.subject
        )
 SELECT f.id,
    f.finding_type,
    f.subject,
    f.kind,
    f.detected_at,
    f.row_count,
    f.details,
    fs.first_detected_at,
    s.standing_since
   FROM ((marts.dq_finding f
     JOIN first_seen fs ON (((f.finding_type = fs.finding_type) AND (f.subject = fs.subject))))
     JOIN streak s ON (((f.finding_type = s.finding_type) AND (f.subject = s.subject))))
  WHERE (f.detected_at = ( SELECT max(latest.detected_at) AS max
           FROM marts.dq_finding latest));

GRANT SELECT ON marts.dq_finding_current TO cc_otel_read;
