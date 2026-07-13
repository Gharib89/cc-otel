# Bootstrap Redesign: Deliverable-Form Options + Friction Constraints

**Date:** 2026-07-14

**Research ticket:** #49 (parent map #48). This is an AFK survey — it decides
nothing. It feeds the grilling that settles deliverable form, shell/tooling, the
automate-vs-gate split, and the idempotency stance. The implementation lands under
a later `ready-for-agent` ticket, not here.

**Research question:** For the one-time-per-environment **bootstrap** (identity/RBAC,
secrets, first infra deploy, first image, DB roles/passwords, fleet cutover, and the
ordering between them), survey (1) deliverable-form options, (2) shell/tooling,
(3) idempotency primitives, and (4) a per-friction-item automate-vs-gate constraint map.

**Method:** Grounded in this repo — `iac/` (`main.bicep`, `params/*.bicepparam`,
`README.md`), `db/migrations/`, `.github/workflows/deploy.yml`, `installer/`,
`scripts/`, `CLAUDE.md`, ADR-0004 — and issues #11, #23, #45, #46, #48. Tool
behaviour (az RBAC, federated credentials, OIDC subject format) verified against
Microsoft Learn primary docs, cited inline. The 10-item friction inventory on #48 is
taken as the authoritative constraint set. Claims not tied to a source are flagged
**UNVERIFIED**.

---

## TL;DR — recommendation

- **Deliverable form:** **Hybrid** — a runbook spine (Markdown, ordered steps, one
  home) that owns the ordering and the human gates, with **scripted mechanical
  clusters** for the deterministic, repeatable stretches (RBAC assignment via ARM
  PUT, federated-credential upsert, secret fan-out, firewall-IP juggling,
  bootstrap-image push). Not pure automation (too many one-shot human gates and
  a hostile `az role assignment` surface), not pure runbook (the mechanical clusters
  are error-prone by hand and bit during interim bring-up).
- **Shell/tooling:** **PowerShell** for the operator-run scripts. It matches
  `installer/` (already PowerShell + Pester), is native on the Windows-primary
  operator machine, and the operator runs bootstrap locally, not in CI. Bootstrap is
  not `make`-shaped (it is a gated sequence, not a dependency graph) and adding a
  `make` dependency to Windows is friction for no payoff. CI (`deploy.yml`) stays
  bash on ubuntu — bootstrap is a **different surface** from the recurring deploy and
  need not share its shell.
- **Idempotency:** **Detect-and-skip (converge)**, not strictly one-shot. This mirrors
  the already-shipped drift-repairing `install.ps1`. The Azure/dbmate/gh primitives
  the bootstrap touches are nearly all idempotent when addressed by deterministic name
  (ARM deployments, deterministic-GUID role assignments, federated credentials,
  `gh secret set` upsert, `dbmate up`). The sharp exceptions get explicit detect-first
  guards.
- **Automate-vs-gate split (10 friction items):** **6 automatable** (2 now,
  4 with-care), **4 human-gated**. Gated: prod-tenant verification (#9), IS RG grant
  (implicit prerequisite), GHCR PAT creation (part of #4), fleet cutover (implicit in
  #10). Full table below.

---

## 1. Deliverable-form options

The bootstrap is a **gated, ordered sequence** with a few deterministic mechanical
stretches inside it. Three candidate forms:

### A. Runbook-only (Markdown, human runs every command)

- **Friction handling:** Documents the ordering (#5, #6) and the gates (#9) well —
  prose is the natural home for "verify the tenant before you proceed". But the
  mechanical, error-prone stretches (the ARM-PUT role assignment #1, per-sub role-def
  lookup #2, the three-home secret fan-out #4, firewall IP juggling #8) stay
  hand-typed, which is exactly what bit during interim bring-up.
- **Build cost:** Lowest. One Markdown file.
- **Maintain cost:** Low to write, but rots — commands drift from reality silently and
  the next bring-up re-discovers the same sharp edges.
- **Re-runnability:** Human-mediated only. No detect-and-skip; the operator re-reads
  and re-judges each step.

### B. Automation-only (one script does everything end-to-end)

- **Friction handling:** Great for the mechanical clusters. Bad for the gates —
  the prod-tenant check (#9), the IS RG grant, and the fleet cutover (#10) are
  genuinely human decisions with irreversible or cross-org consequences; wrapping them
  in a script either forces fragile "pause and prompt" interaction or, worse, encodes
  an assumption (same tenant) the map explicitly says must be *verified* first.
- **Build cost:** Highest. Must encode every sharp edge (the `az role assignment
  create` `MissingSubscription` bypass, the per-sub Contributor GUID lookup, the
  federated-credential subject) plus interaction/gating logic.
- **Maintain cost:** Highest — a bootstrap runs a handful of times per environment
  lifetime, so heavy automation is amortised over very few runs. Classic
  over-automation of a rare task.
- **Re-runnability:** Best in principle (converge on every run), but the human gates
  cap the benefit — you cannot fully unattended it regardless.

### C. Hybrid — runbook spine + scripted mechanical clusters  ⟵ recommended

- **Friction handling:** The runbook owns ordering and gates (#5, #6, #9, cutover);
  small, single-purpose scripts own the deterministic clusters where hand-typing bit:
  - `assign-rbac` — the `az rest --method PUT` role assignment with per-sub role-def
    lookup (#1, #2).
  - `ensure-federated-credential` — idempotent OIDC subject upsert (#3).
  - `sync-secrets` — fan out `DATABASE_URL` et al. to the three homes from one source,
    guaranteeing byte-identity (#4).
  - `bootstrap-images` — push a first real SHA image so ACA can start (#5), or just
    lean on `deploy.yml`.
  - `open-my-ip` / `close-my-ip` — operator-IP firewall juggling (#8).
- **Build cost:** Moderate. Each script is small and does one mechanical thing; the
  spine is prose. Matches the repo's existing shape — `installer/` is exactly this
  (tested pure-logic seam + thin effectful shims).
- **Maintain cost:** Moderate, and honest — the scripts encode the sharp edges once so
  the next bring-up doesn't re-learn them; the spine stays readable.
- **Re-runnability:** Each script is detect-and-skip (converge); the spine's gates stay
  human. This is the same posture as the shipped `install.ps1` (#46) — verify real
  state, repair drift, no-op when clean.

**Recommendation:** **C (hybrid).** It is the only form that both encodes the
mechanical sharp edges (so they stop biting) and keeps the irreversible cross-org
decisions in front of a human. It also matches the grain of the codebase: `installer/`
already proves the "runbook-ish orchestration + tested mechanical shims" pattern in
PowerShell.

---

## 2. Shell / tooling

| Option | Fit | Against |
|---|---|---|
| **PowerShell** | Native on the Windows-primary operator box; matches `installer/` (PowerShell + Pester, PSScriptAnalyzer CI in #43); `az`/`gh`/`psql`/`dbmate` all callable; operator runs bootstrap **locally**, not in CI. | Not CI's shell — but bootstrap isn't a CI task. |
| **bash** | Matches CI (`deploy.yml`) and `scripts/` (`cloud-ship-bootstrap.sh`); ubiquitous in Azure docs. | Not native on the operator box (Git Bash/WSL needed); WSL itself is a variable the installer already has to gate against (#46). Bootstrap's audience is the operator, not the runner. |
| **make** | Encodes ordering/targets. | Needs `make` installed on Windows (extra dependency the map flags); bootstrap is a **gated sequence with human stops**, not a file-dependency graph — `make`'s model doesn't fit, and its re-run story (timestamp-based) is wrong for "converge on cloud state". |

**Key implication for the automate-vs-gate split:** the operator runs bootstrap on
**Windows, interactively**. That argues for PowerShell scripts the operator invokes by
hand between reading runbook steps — which naturally leaves the human gates as
"operator stops and reads the next section" rather than script-internal prompts. It
also keeps bootstrap tooling off the ubuntu CI surface entirely, so there is no
cross-platform tax.

**Recommendation:** **PowerShell** for operator-run bootstrap scripts; leave
`deploy.yml` (the recurring deploy, explicitly out of scope per #48) as bash-on-ubuntu.
Two surfaces, two shells, each native to its runner. Do **not** introduce `make`.

---

## 3. Idempotency / re-runnability

**Stance: detect-and-skip (converge on desired state), not strictly one-shot.** A
one-shot bootstrap that half-fails (e.g. migration fails after RBAC is set) leaves the
operator hand-reconstructing "what already happened". Converge lets a re-run pick up
where it left off. This is the posture `install.ps1` already took (#46).

Primitive-by-primitive (each is the mechanical work the scripts would wrap):

| Primitive | Idempotent? | How / sharp edge |
|---|---|---|
| **ARM deployment** (`az deployment group create`, the Bicep in #23) | **Yes** | ARM is declarative — re-deploying the same template converges. This is the whole `iac/` story. |
| **Role assignment** | **With care** | Role assignments are keyed by a GUID *name*; using a **deterministic** name — `guid(scope, principalId, roleDefId)` — makes create idempotent, and reusing the name after the principal is deleted/recreated fails `RoleAssignmentUpdateNotPermitted`. [MS Learn: Bicep RBAC](https://learn.microsoft.com/azure/azure-resource-manager/bicep/scenarios-rbac), [Troubleshoot RBAC](https://learn.microsoft.com/azure/role-based-access-control/troubleshooting). But note #1: `az role assignment create` itself throws `MissingSubscription` on this sub and must be bypassed with `az rest --method PUT` to the ARM `roleAssignments/{guid}` endpoint — so the idempotency is "PUT with a deterministic GUID name", not the CLI verb. |
| **Federated identity credential** (`az ad app federated-credential create`) | **Effectively yes** | Keyed by `name` (which "can't be changed later"); subject is exact-match (`repo:Gharib89/cc-otel:ref:refs/heads/main`), no pattern matching. [MS Learn: WIF create-trust](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust). Detect-first with `az ad app federated-credential list` then create-if-absent; re-creating an existing name errors, so guard it. |
| **`gh secret set`** | **Yes (upsert)** | Sets or overwrites the value; safe to re-run. Ideal for the `sync-secrets` fan-out — the guarantee we want for #4 (byte-identical `DATABASE_URL`) is exactly "one source, upsert to all homes". |
| **`dbmate up`** | **Yes** | Tracks applied versions in `schema_migrations`; re-running applies only pending migrations, no-ops when current. Already how `deploy.yml`'s `migrate` job behaves. |
| **Postgres firewall rule** (`az postgres flexible-server firewall-rule create`) | **With care** | Create with a fixed name updates in place (idempotent); `deploy.yml` sidesteps by using a per-run unique name `gha-<run_id>` and deleting in `if: always()`. For operator-IP juggling (#8) use a **stable** name (e.g. `operator-<initials>`) so re-runs converge rather than accrete rules. |
| **`az containerapp update --image`** | **Yes** | Setting the image to a given tag is convergent; re-running with the same SHA is a no-op revision-wise. Chicken-egg (#5) is about *ordering* (image must exist first), not idempotency. |
| **DB LOGIN users + passwords** (#7) | **No** | `CREATE ROLE ... LOGIN PASSWORD` is not convergent and has **no secret home** by design (#11 no Key Vault). Detect-with-`\du`, create-if-absent, and treat password material as a human-held, human-entered value — this is a gated step, not scripted secret generation. |

**Net:** the Azure/gh/dbmate surface supports detect-and-skip almost everywhere,
*provided* every create is addressed by a deterministic name. The two genuine
non-idempotent spots — the CLI role-assignment bug and DB login/password creation —
are already the ones the map flags as sharp, and both are handled by the hybrid form
(ARM PUT script; human-gated password step).

---

## 4. Per-friction-item constraint map

Classification: **Automatable now** (deterministic, safe to script today) /
**Automatable-with-care** (scriptable but has a sharp edge that must be encoded) /
**Human-gated** (irreversible, cross-org, or a decision that must be verified by a
person before proceeding).

| # | Friction item (#48) | Class | Sharp edge / rationale |
|---|---|---|---|
| 1 | `az role assignment create` broken (`MissingSubscription`) | **With care** | Must **not** use `az role assignment create`; bypass with `az rest --method PUT` to `…/providers/Microsoft.Authorization/roleAssignments/{guid}` using a deterministic GUID name. Encode the bypass once. (Confirmed: role assignments keyed by GUID name — [MS Learn RBAC](https://learn.microsoft.com/azure/azure-resource-manager/bicep/scenarios-rbac).) |
| 2 | Nonstandard built-in Contributor GUID | **With care** | Never hardcode the role-def GUID; look it up per-sub: `az role definition list --name Contributor --query "[0].name"`. NB: MS docs give Contributor's canonical id as `b24988ac-6180-42a0-ab88-20f7382dd24c` — the same value the map calls "nonstandard" on this sub — so the map's "universal `…bb6e-116d6d5b6f6b`" framing looks like a mis-recollection. **The encoded rule (look up per-sub, don't hardcode) is correct regardless**, which is what matters; the discrepancy is worth a line in the grilling. |
| 3 | Federated credential required for OIDC | **With care** | Subject is branch-based and exact-match: `repo:Gharib89/cc-otel:ref:refs/heads/main` — one credential shared across interim+prod (no GitHub Environments on free plan). Login is silently impossible without it. Detect-then-create by name; name is immutable. ([MS Learn WIF](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-create-trust).) |
| 4 | Secret sprawl across three homes | **With care** | `DATABASE_URL` must be **byte-identical** across the Bicep input, the sink runtime secret, and the CI migration target, or migrations and the sink split across two DBs. Scriptable via a single-source `sync-secrets` using `gh secret set` (upsert) + `.env` writes. **Sub-part gated:** creating the GHCR classic PAT is a manual GitHub credential action (see below). |
| 5 | Image bootstrap chicken-egg (`:latest` before a real image exists) | **Automatable now** | Deterministic ordering: Bicep first (creates ACA with `:latest` placeholder), then `deploy.yml` pushes a real SHA image and rolls the revision. A `bootstrap-images` script (or a first `deploy.yml` dispatch) closes it. No decision, just sequence. |
| 6 | Bicep-before-workflow ordering | **Automatable now** | `deploy.yml` opens a firewall rule on `ccotel-pg-<env>` and updates `ccotel-app-<env>`; both must pre-exist. Pure ordering constraint — the runbook spine encodes "Bicep, then deploy". No sharp edge beyond sequence. |
| 7 | Out-of-band DB roles/passwords | **Human-gated** | `cc_otel_read`/`cc_otel_ingest` are `NOLOGIN` group roles created by migration `…170001`; the LOGIN users + passwords are created **by hand** and `GRANT`-joined, with **no secret home by design** (#11 no Key Vault). Password material is human-held/human-entered → gated. The `GRANT` step itself is scriptable once the login exists. |
| 8 | Firewall IP juggling | **Automatable now** | `deploy.yml` already opens/closes the runner IP per run. Operator `psql`/`dbmate` needs the operator IP added: an `open-my-ip`/`close-my-ip` pair using a **stable** rule name (converge, don't accrete) — see §3. |
| 9 | Prod tenant gate | **Human-gated** | The entire unprefixed-identity design (one app registration, unprefixed `AZURE_CLIENT_ID`/`AZURE_TENANT_ID`) assumes prod lands in the **same tenant** (`a1a5384f`). A different tenant breaks it (new app + new federated credential + prefixed client/tenant). **Must be verified by a human before prod bootstrap** — a script must not assume it. |
| 10 | Dev DB repoint | **With care** (+ gated cutover) | Mechanically, repointing `.env` `DATABASE_URL` from the retired POC server to interim is a scripted edit. But **which DB is "dev"** and **when to decommission the old server** is a cutover judgement (parallel cutover, ADR-0004) — the decommission and fleet cutover are human-gated. The runbook documents the "which DB is dev" story; the edit is mechanical. |

### Implicit prerequisites (not numbered on #48, but bootstrap gates)

- **IS RG grant** — prod bootstrap cannot start until IS provisions the empty RG and
  grants Contributor scoped to it (ADR-0004). Out of the operator's hands →
  **human-gated**, and the prod RG name is still pending (#23).
- **GHCR classic PAT creation** (the ACA *pull* credential, distinct from the push
  `GITHUB_TOKEN` in `deploy.yml`) — creating a GitHub PAT is a manual credential action
  in the GitHub UI → **human-gated**; setting it as an ACA secret via Bicep is
  mechanical.

**Tally:** Automatable now = **#5, #6, #8** (3). Automatable-with-care = **#1, #2, #3,
#4, #10** (5). Human-gated = **#7, #9** + IS RG grant + GHCR PAT + fleet cutover/decommission.
The gated set is small and clusters at the **edges** (prerequisites: tenant, RG, PAT)
and the **irreversible middle** (DB passwords, cutover) — leaving a scriptable
mechanical core.

---

## Open decisions → recommendations (for the grilling)

1. **Deliverable form** → **Hybrid** (runbook spine + PowerShell mechanical clusters).
   Rationale: encodes the sharp edges that bit during interim bring-up while keeping
   irreversible cross-org calls human. Matches `installer/`'s proven shape.
2. **Shell/tooling** → **PowerShell** for operator-run bootstrap; keep `deploy.yml`
   bash-on-ubuntu; **no `make`**. Bootstrap is operator-local on Windows; it is a
   different surface from the recurring CI deploy.
3. **Idempotency stance** → **detect-and-skip / converge**, addressing every create by
   deterministic name (ARM deployment, `guid()` role-assignment name, federated-cred
   name, `gh secret set` upsert, `dbmate up`, stable firewall-rule names). Two genuine
   non-idempotent spots (CLI role-assignment bug, DB login/password) are handled by the
   ARM-PUT script and a human-gated password step respectively.
4. **Automate-vs-gate split** → automate the mechanical core (8 of 10 items scriptable,
   3 outright and 5 with an encoded sharp edge); gate the four irreversible/cross-org
   decisions (DB passwords #7, prod-tenant verification #9, plus the IS RG grant and
   GHCR PAT prerequisites) and the fleet cutover/POC decommission.

### Things to raise in the grilling (unresolved / needs a human call)

- **The #2 GUID discrepancy** — MS docs say `b24988ac-…dd24c` *is* canonical Contributor;
  the map calls it nonstandard. Worth confirming what the operator actually observed so
  the encoded lookup rule is framed correctly. The rule itself (look up per-sub) is safe
  either way.
- **How far to push `sync-secrets`** (#4) — one source of truth for `DATABASE_URL`
  across three homes is the highest-value automation, but it touches GitHub secrets,
  `.env` files, and Bicep inputs; agree the source-of-truth home before building it.
- **Whether `bootstrap-images` is worth writing** (#5) vs just documenting "dispatch
  `deploy.yml` once after Bicep" — may be a runbook line, not a script.
