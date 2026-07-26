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
CREATE TABLE staging.stg_identity_alias (
    personal_email TEXT PRIMARY KEY,
    corporate_email TEXT NOT NULL,
    shared_sessions INTEGER NOT NULL
);

-- Operator-supplied pairs — the same family as the roster drop (ADR-0009), inserted by hand
-- when the derivation cannot see the link or gets it wrong. Always outranks a derived pair,
-- and a row with a NULL corporate_email suppresses one: the failure mode of a wrong link is
-- one employee's activity disclosed to another employee's manager, so the correction path
-- cannot depend on the next derivation happening to change its mind.
--
-- added_by defaults to the operator's own DB identity (humans reach prod as themselves over
-- the VPN), so attribution costs the insert nothing and is never blank.
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
