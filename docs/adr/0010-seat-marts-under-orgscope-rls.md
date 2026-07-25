# The seat marts are scoped by the `OrgScope` RLS role, not by an App audience

**Status:** accepted

Retiring the fabricated `seat_roster` (#294) put three real seat marts into the semantic model:
`dim_seat_current`, `dim_seat`, and `fact_seat_day`. All three come from IS's roster drop
(ADR-0009), and all three sit outside the `OrgScope` security-filter chain, which reaches only
`vw_UserBasicInfo` and — through the existing relationship — `dim_user`.

That leaves two holes. The licensed-seat count is org-wide for every viewer, so a manager would see
their own scoped active users beside a licensed population of 184. And the seat marts carry 184 real
employee addresses, roughly 164 of which belong to people with no telemetry at all and therefore no
`dim_user` row; before #294 every roster email was telemetry-derived and so already scoped. Both are
latent today only because nobody is assigned to the role yet — the workspace members bypass RLS.

Decision log: #301 (triage grilling with Ahmed, 2026-07-25). This ADR **supersedes the "Organization-
level row-level security on seat data" out-of-scope bullet in #290**, which was written when the
roster was fabricated and every roster email was already inside the scoped user dimension.

## Decisions

- **`OrgScope` gains a table permission on each of the three seat marts.** One mechanism closes both
  concerns at once: the count scopes because `fact_seat_day` is the licensed-count grain, and the
  addresses scope because the same predicate governs which rows the Filters pane and
  personalize-visuals can reach.
- **The predicate is strict subtree membership, restated against the HR view.** Each permission asks
  whether the seat's email is in the set of `vw_UserBasicInfo[Email]` where the email equals the
  viewer's UPN or the management path contains it — the same test the `vw_UserBasicInfo` permission
  applies, written out rather than inherited. A security filter must not depend on another filter
  having already been evaluated, so each expression wraps the HR view in `ALL()` and stands alone.
- **No `LOWER`/`TRIM` normalization on either side.** DAX string comparison is case-insensitive, and
  the existing `dim_user`-to-HR-view and `dim_user`-to-`dim_seat_current` relationships both join
  these columns successfully, which is empirical proof the values already match. Normalizing in the
  predicate would mask an upstream roster/HR mismatch instead of surfacing it.
- **The relationship topology is unchanged.** A `fromCardinality: one` edge into `dim_user` makes
  Desktop reject the model silently (#118), and relating the seat marts to the HR view would create
  an ambiguous path. #294's shape — fact to date only, current-seat on the one side of `dim_user`,
  seat history disconnected — stays exactly as built. The role is the only lever.
- **No measure and no `isHidden` changes.** `Paid Seats` scopes automatically once `fact_seat_day` is
  filtered and everything composed over it follows; `Instrumented Seats` already scoped through
  `dim_user`. Hiding the two `user_email` columns was the cheap alternative and is rejected below.

## Rejected alternatives

- **A Power BI App with separate audiences.** Publishing a manager audience that excludes the seat
  pages would hide the numbers without scoping them. The boundary is presentation-only: a Viewer with
  Build permission reaches the whole model through Analyze in Excel or a new report, so the 184
  addresses leak past the audience. Closing that means withholding Build from Viewers, which also
  removes legitimate self-service. RLS holds at the model, wherever the query originates, and the App
  audience remains available on top of it as a product choice rather than the security boundary.
- **Hiding the `user_email` columns (`isHidden`).** Blocks the Filters pane and nothing else — the
  columns stay queryable, and the licensed count stays org-wide, so it addresses neither concern
  fully. It would also complicate #295's untracked-seat worklist, which legitimately shows those
  addresses, for no security gain. Under RLS the Filters pane surfaces only entitled addresses, which
  is the outcome hiding was reaching for.

## Consequences

- **Seat history becomes viewer-relative.** The predicate keys on a live HR row, and people leave. A
  seat-day belonging to someone who has since departed has no HR row and therefore disappears for
  every viewer under the role, so the licensed-seats-over-time visual rewrites its own past: a month
  reading 13 seats today may read 11 next quarter, with nothing on the visual indicating why.
  Workspace members see the stable org-wide history. This was weighed against scoping only
  `dim_seat_current`, which would have left the licensed count unscoped — the very hole this decision
  exists to close. A manager's real question is how their current reports are doing, and that stays
  coherent as the absolute baseline drifts.
- **Data Health is not published to a manager audience.** The reason is product, not security: RLS
  makes the page safe, but a manager viewing it sees zero off-roster active users and an empty
  mismatch table, because those identities have no HR row — so the page reads "everything is fine"
  when it is not. Recorded in `powerbi/README.md` where the publish runbook lives.
- **Off-roster personal-email identities stay invisible to role viewers.** They have no HR row, which
  was already true before this change. Making them visible needs session-data linking, its own
  ticket.
- **The subtree predicate is repeated three times.** Deduplicating it into a measure or calculated
  table would reintroduce the evaluation-order dependency the decision rejects, so the repetition is
  the point rather than an oversight.
- **Verification cannot be a smoke test.** An empty result is the failure mode and it is silent — a
  `View as` returning nothing is indistinguishable from a correctly-scoped view of someone with no
  reports. Every future change here asserts a non-empty result of an independently computed size, for
  both a manager with reports and an individual contributor without.
