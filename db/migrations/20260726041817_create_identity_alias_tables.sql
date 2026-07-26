-- migrate:up

-- Linked identities (#320, parent #303, ADR-0011). A developer on a personal Claude
-- subscription emits under an address that reaches neither IS's roster drop nor the HR view,
-- so OrgScope filters it out for every viewer. These two relations carry the personal ->
-- corporate pairs that give that identity a scoping address; the link governs visibility only
-- and nothing is merged, so marts.email_bucket() and both sets of facts stay untouched.

-- Session-derived pairs. Materialised as a table at the top of marts.refresh_all() rather than
-- left as a view: dim_user and the unresolved-identity finding both read it, so a view would
-- be one scan per consumer, and the current pair set stays selectable and auditable between
-- refreshes rather than existing only inside a query plan.
--
-- personal_email is the primary key because the derivation's second guard asserts exactly one
-- corporate partner per address — a second row for the same address would mean the guard leaked.
-- Ungranted like the rest of staging: Power BI reads marts only (#19).
--
-- The three guards are asserted here as well as applied in the derivation, because this table
-- feeds a scoping address: ADR-0011's failure mode is one employee's activity disclosed to
-- another employee's management chain, and the guards may not be dropped as redundant. A future
-- bug in the rule therefore aborts the refresh — every mart stays at its last good contents and
-- marts.mart_refresh_log shows the cycle that never finished — instead of quietly widening
-- someone's visibility. Corporate means '@itworx.com' (inline; #278 gathers the predicate).
CREATE TABLE staging.stg_identity_alias (
    personal_email TEXT PRIMARY KEY,
    corporate_email TEXT NOT NULL,
    shared_sessions INTEGER NOT NULL,
    CONSTRAINT stg_identity_alias_personal_side CHECK (personal_email NOT LIKE '%@itworx.com'),
    CONSTRAINT stg_identity_alias_corporate_side CHECK (corporate_email LIKE '%@itworx.com'),
    CONSTRAINT stg_identity_alias_two_shared_sessions CHECK (shared_sessions >= 2)
);

-- Operator-supplied pairs — the same family as the roster drop (ADR-0009), inserted by hand
-- when the derivation cannot see the link or gets it wrong. Always outranks a derived pair,
-- and a row with a NULL corporate_email suppresses one: the failure mode of a wrong link is
-- one employee's activity disclosed to another employee's manager, so the correction path
-- cannot depend on the next derivation happening to change its mind.
--
-- added_by defaults to the operator's own DB identity (humans reach prod as themselves over
-- the VPN), so attribution costs the insert nothing and is never blank.
--
-- Deliberately unconstrained where the derived table is checked: this table exists to overrule
-- the rule, so the three guards are derivation-only by design. A corporate-to-corporate pair is
-- the operator's call to make — one person holding two corporate addresses is exactly the case
-- the derivation refuses to guess at — and constraining it here would leave no correction path
-- when the domain test itself turns out to be the thing that was wrong (ADR-0011, Consequences).
CREATE TABLE ref.identity_alias (
    personal_email TEXT PRIMARY KEY,
    corporate_email TEXT,
    added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    added_by TEXT NOT NULL DEFAULT current_user,
    notes TEXT
);

-- migrate:down

DROP TABLE IF EXISTS ref.identity_alias;
DROP TABLE IF EXISTS staging.stg_identity_alias;
