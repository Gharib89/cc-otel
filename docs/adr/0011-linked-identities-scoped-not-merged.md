# A personal-email identity is linked to its corporate identity for scoping only, never merged

**Status:** accepted

A developer who buys their own Claude subscription on a personal email emits telemetry under that
address. It never reaches IS's roster drop, which carries corporate seats only, and never reaches
the HR view, which is keyed on corporate email. `OrgScope` (ADR-0010) filters `vw_UserBasicInfo` and
propagates into `dim_user`, so an identity with no HR row is filtered out for every viewer under the
role: a manager reads zero off-roster active users and an empty mismatch table — not "none of my
people are on personal accounts", but "this question cannot be answered here", with nothing on the
page distinguishing the two. ADR-0010 recorded that as a consequence and deferred the fix to #303,
pending a signal that could associate a personal address with a corporate one.

That signal exists, and it is stronger than #303 assumed. Ten distinct `session_id`s between
2026-07-13 and 2026-07-17 carry both `riham.fayez@itworx.com` and a personal address. A session is
one Claude Code process, so two addresses inside one session is one human re-authenticating.
`machine`, listed in #303 as a candidate, does not exist — neither `raw.metrics` nor `raw.events`
carries a host, hostname, or IP column.

The population is one, and it is a migration rather than a parallel account: corporate emission
stopped 2026-07-16, personal emission continues, and the ITWorx Standard seat stays open. The
personal side is 11% of all reported API-equivalent value, produced in 8 days at roughly 4x the
prior daily rate.

Decision log: #303 (design grilling with Ahmed, 2026-07-25). This ADR **amends two consequence
bullets of ADR-0010** — "off-roster personal-email identities stay invisible to role viewers", which
becomes conditional on a link existing, and "Data Health is not published to a manager audience",
whose stated reason no longer holds for this class.

## Decisions

- **The link governs visibility, not attribution. Nothing is merged.** The two identities keep two
  `dim_user` rows and two sets of facts. `marts.email_bucket()` — the cross-cutting identity rule
  called by `dim_user` and six facts — is deliberately **not** touched. Collapsing the addresses
  there would have been the cheapest mechanism and is rejected below.
- **`dim_user` gains `rls_email`, the scoping address.** Its own address for every identity, the
  corporate address for a linked one. Both relationships out of `dim_user` re-point to it:
  `dim_user_to_vw_UserBasicInfo` and `dim_user_to_dim_seat_current`.
- **The `OrgScope` role is unchanged.** No fourth table permission, no fifth copy of the subtree
  predicate. This is the whole reason the mechanism is a join key rather than a rule: ADR-0010's
  standing hazard is that four identical predicates diverge, and re-pointing a relationship adds
  nothing to that count. Power BI RLS filters intersect and never widen, so a `dim_user` permission
  could not have re-admitted the row in any case — it is dropped by propagation before any
  permission is evaluated.
- **Both relationships must move, not just the HR one.** Measured against the live model while
  writing this: filtering `dim_seat_current` alone to a single seat leaves only that seat holder's
  row in `dim_user`, so a many-side row matching no visible one-side row does not survive. The
  personal identity holds no seat, so the `dim_seat_current` permission drops it independently of
  the HR path. Re-pointing only `dim_user_to_vw_UserBasicInfo` would have changed nothing, silently.
- **A link is derived from shared sessions under three guards.** At least **two** shared
  `session_id`s; exactly one corporate partner across that address's sessions, so any conflict
  yields no link; and never corporate-to-corporate. Corporate means `'@itworx.com'`. One shared
  session would have sufficed for the observed case, which has ten; two costs nothing on the data
  and closes the single-accident case.
- **A `session_id` is evidence of one process, not one person, and the guards are what close the
  gap.** On a shared terminal both addresses are corporate, so the personal-to-corporate rule never
  fires. A wrong link needs someone to authenticate with a personal account inside another person's
  session. That residual case is what the human override exists for.
- **Derived and human-supplied links are separate relations with explicit precedence.** Session-
  derived pairs land in `staging.stg_identity_alias`, materialised as a table at the top of
  `refresh_marts` — one scan instead of one per consuming mart, and the current pair set is
  selectable and auditable between refreshes rather than existing only inside a query plan.
  Human-supplied pairs land in `ref.identity_alias`, operator-inserted, the same family as the
  roster drop (ADR-0009). `rls_email = COALESCE(manual, derived, user_email)`, so a human always
  outranks a derived guess and a manual row with a null corporate address suppresses a bad
  auto-link. The suppression path is justified by the failure mode being a disclosure, not a
  cosmetic defect.
- **An off-roster identity the rule cannot resolve becomes a `dq_finding`.** Silence is the wrong
  output for "a human needs to look at this".
- **The off-roster flag survives the link, carried by `is_linked_identity`.** A model calculated
  column, `user_email <> rls_email`, materialised at refresh and therefore viewer-independent. The
  eight sites that read `RELATED ( dim_seat_current[...] )` as "holds a seat" guard on it, because
  after the seat re-point that expression resolves for a linked identity through a seat it does not
  hold. A linked identity therefore keeps reading `"Off-roster identity"`, stays out of
  `Instrumented Seats`, and counts in `Off-Roster Active Users` — which returns 1 for the right
  manager instead of blank.
- **People-counting measures move onto the scoping address.** `Active Users` and its family count
  `DISTINCTCOUNT` of a fact `user_email`, so unmerged facts would count one person twice for their
  own manager. They count a `RELATED ( dim_user[rls_email] )` calculated column instead. Per-email
  visuals still show both addresses and both sets of numbers; anything claiming to count people
  counts one person.
- **The corporate/personal test stays `'@itworx.com'`.** Keying it on Anthropic organization
  membership would be the stronger test and is deliberately deferred — see Consequences.

## Rejected alternatives

- **Collapsing the addresses in `marts.email_bucket()`.** One function body, zero mart changes,
  `OrgScope` inheriting the merge for free — by far the cheapest mechanism, and wrong. It answers
  "whose activity is this?" by destroying the answer to "is this work happening inside a seat we pay
  for?". After the collapse `Roster Status` finds a seat and a recent `last_seen` and reads
  `"Active seat"`; `Off-Roster Active Users` goes to zero for **everyone**, workspace members
  included. The honest "we cannot attribute this" becomes a confident "everything is fine", and both
  the idle seat and the unmanaged subscription disappear. Cost attribution was not the objection —
  ADR-0007 defines `cost_usd` as API-equivalent value rather than spend, so the personal-account
  dollars are ITWorx work either way.
- **Appending synthetic rows to the HR view's M query.** `vw_UserBasicInfo` is an imported M query
  over IS's SQL Server that already carries two local stopgap transforms, so a third appending one
  row per link would need no role change at all. Rejected because it writes non-employees into the
  HR dimension, where they surface with blank Department and Division in anything sliced by HR
  attributes, and because combining a Postgres alias relation with a SQL Server source in one M
  expression runs into the Formula Firewall.
- **Severing `dim_user_to_vw_UserBasicInfo` and giving `dim_user` its own permission.** Adds the
  fifth copy of the subtree predicate that ADR-0010 and the role's own comment warn against ("change
  all four together or not at all"), and loses the HR attributes the report slices telemetry by.
- **Dropping `dim_user_to_dim_seat_current` instead of re-pointing it.** Would have removed the
  propagation ADR-0010 flagged as a latent hazard, but the relationship is load-bearing: eight
  measure sites walk `RELATED` across it and a `seat_tier` slicer on four pages depends on it.

## Consequences

- **A linked identity's telemetry buckets under its corporate seat tier.** The `seat_tier` slicer
  reaches the personal-account rows through the re-pointed relationship, so they appear under
  "Standard". Defensible — it is that person's work at that person's tier — and accepted rather than
  guarded, on the grounds that a ninth guard buys precision nobody asked for.
- **A link makes one person's personal-account activity visible to their management chain.** That is
  the point, and it is also the failure surface: a wrong link discloses one employee's activity to
  another employee's manager. The guards, the human override, and the `dq_finding` worklist exist
  for that reason and none of them may be dropped as redundant.
- **Verification cannot be a smoke test**, for the same reason ADR-0010 gives: an empty result is the
  failure mode and it is silent. Every change here asserts a non-empty result of an independently
  computed size, for both a manager with reports and an individual contributor without, read through
  `.github/powerbi/dax-eval.ps1` rather than off a screenshot.
- **A linked identity inherits its corporate identity's HR lifetime.** `rls_email` keys on a live HR
  row, so when the person leaves, both of their identities disappear for role viewers together —
  the same viewer-relative behaviour ADR-0010 accepted for seat history, now extended to telemetry.
- **The corporate/personal test remains email-domain-shaped, and that leaves a hole.** A developer
  using their *work* email with a *personal* subscription passes the domain test, so no link is
  needed and no flag fires, and unlicensed usage blends silently into corporate adoption numbers.
  Closing it needs a mapping from telemetry's `organization_id` to `anthropic_org_name` — which
  `CONTEXT.md` already claims exists and which no relation in the database actually holds. Left
  open deliberately rather than widened into this decision, and deliberately without a tracking
  ticket (#313, closed unplanned): the hole is theoretical on the observed population, and Ahmed
  raises it himself if a case ever surfaces. The re-entry signal is a telemetry identity on an
  `@itworx.com` address emitting under an `organization_id` that holds no seats.
- **`marts.email_bucket()` remains a pure `IMMUTABLE` expression.** Had the merge been chosen it
  would have had to read a relation and drop to `STABLE`. Nothing depends on that volatility today,
  but the seven marts that call it stay inlined and unchanged.
