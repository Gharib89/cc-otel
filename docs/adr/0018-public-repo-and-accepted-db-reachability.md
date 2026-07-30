# The repo stays public; the firewall ranges leave it, the reachability residual stays

**Status:** accepted — **amends ADR-0004**, which chose a public Postgres endpoint plus a firewall
allowlist to keep Power BI gateway-less, without recording what that posture costs while the repo
holding it is public.

Issue #385 filed a single exposure: `iac/params/{prod,interim}.bicepparam` publish eight ITWorx VPN
egress ranges, in a public repo, under a work identity. Widening the question found two facts that
reorder it. The prod admin password was **identical to interim's** — the shared POC password that
#93's own context said prod "must not inherit". And the ranges are not what makes the endpoint
reachable: both param files keep `AllowAllAzureServices` (`0.0.0.0-0.0.0.0`), which admits any Azure
tenant's resources, while the server FQDN is derivable from `namePrefix` in `iac/main.bicep`,
`postgresAdminUser = 'ccotel_admin'` is committed and immutable after server creation, and
`passwordAuth` stays `Enabled` because the sink, CI migrations and the Power BI read login all use
it. Eight IP ranges in a repo were the least load-bearing part of the exposure they described.

## Decisions

- **The repo stays public, as a constraint rather than a preference.** Public repositories get
  unlimited GitHub Actions minutes; private repositories on the free plan get 2000 per month, and
  this repo's CI — Docker integration tests, Bicep, PSRule, ~100 runs a fortnight — does not fit in
  that. Going private is the only move that actually un-publishes anything, and it is unaffordable,
  so every decision below is downstream of it.
- **The VPN egress ranges are env-sourced, never committed.**
  `postgresFirewallRules = concat([AllowAllAzureServices], json(readEnvironmentVariable('PG_FIREWALL_RULES', '[]')))`,
  with the JSON array in the uncommitted `.env.<env>`. This is the deliberate exception to
  "bicepparam values are committed literals" and it follows the `PG_ADMIN_PASSWORD` /
  `RESOURCE_GROUP` precedent already in those files. The rationale is **perimeter hygiene, not
  database defense** — under the residual below it buys the database nothing; what it buys is not
  publishing a durable, search-indexable map of the employer's network perimeter. Anyone tempted to
  inline the ranges back for readability is undoing that and nothing else.
- **`PG_FIREWALL_RULES` is a required key** in `bootstrap/lib/Get-BootstrapConfig.ps1`. Unset, the
  param file compiles to the Azure-services rule alone — which is exactly what lets
  `az bicep build-params` run in CI without secrets, and exactly what would make a real deploy ship
  IaC that no longer describes the live firewall. Resource-group deploys are incremental, so the
  live rules survive and nothing else would detect the drift. `readEnvironmentVariable` reads the
  `az` child process's environment rather than the config object, so the key also joins
  `Invoke-StepDeploy`'s `$secretEnv` — a required key that never gets exported is validated and then
  ignored.
- **The reachability residual is accepted, not remediated.** Any Azure tenant can reach
  `ccotel-pg-prod` and attempt password auth against a publicly-known login, and Postgres has no
  lockout. The mitigation is a strong password that is **distinct per environment** — the rotation
  #385 performed is therefore load-bearing, not hygiene.
- **The FQDN, `ccotel_admin`, and the Entra admin login/objectId are knowingly public.** The
  hostname is derivable from committed Bicep; the admin login is immutable post-create, so scrubbing
  the string would change nothing deployed; the Entra pair was already committed deliberately as
  directory pointers. Recorded here so a future audit does not re-file #385 against them.
- **No history rewrite.** One commit introduces the ranges (`3fc9a85`), but 134 commits and 14
  remote branches sit on top, and GitHub retains unreachable objects after a force-push regardless —
  the cost is real and the removal is not. The ranges are treated as disclosed; VPN egress IPs are
  not credentials, so nothing rotates in response.
- **The visibility call was made locally.** IS was not consulted. Nothing in this ADR is pending an
  answer, and #385 does not close on one.

## Considered options

- **Private repository** — the only true un-publish, rejected on the Actions-minutes arithmetic
  above.
- **VNet-injected workload-profile ACA environment + NAT Gateway, dropping the `0.0.0.0` rule** — the
  textbook fix, and the wrong trade here. A Container Apps environment's network type is immutable
  after creation, so this is an environment recreate, and NAT Gateway adds ~$33/mo plus per-GB
  against hard caps of $150 (prod) and $75 (interim, ADR-0004). It also still leaves a password
  endpoint reachable from the allowlisted ranges, so it buys less than its price.
- **`passwordAuth: 'Disabled'`, Entra-only** — structurally the strongest option and free of
  recurring cost: with no password to guess, the `0.0.0.0` rule stops mattering. It needs three auth
  paths migrated — the sink to its managed identity, CI migrations to an OIDC-derived token, Power BI
  to a service principal — which is a project, not a fix, and it is not scheduled. This is the option
  to revisit if the residual ever stops being acceptable.
- **Deleting the ranges outright** (#385's own opening fear) — would have left the addresses in
  history while breaking the deployed firewall rule: the worst of both. Env-sourcing is what makes
  the change safe enough to land without waiting on anyone.
- **Rotating the ranges** — not a thing. They are ITWorx's NAT egress, not a secret this project can
  cycle.

## Consequences

- **A deploy from a machine without `PG_FIREWALL_RULES` in `.env.<env>` now fails at precheck**
  rather than quietly narrowing the firewall's IaC description. That is the intended trade: one more
  required key against silent drift.
- **`iac/params/*.bicepparam` no longer round-trips the live firewall.** Reading the file tells you
  the Azure-services rule and where the rest lives; `az postgres flexible-server firewall-rule list`
  is the source of truth for what is deployed.
- **The prod and interim admin passwords are now distinct**, so the two environments stop sharing a
  compromise. The POC-era shared password remains in the archived credential set and must not be
  reused.
- **ADR-0004's public-endpoint choice is unchanged but now carries a written residual.** Anyone
  reasoning about prod DB exposure reads this ADR alongside it; #93's allowlist design is untouched
  and still correct.
- **CI is unaffected** — `az bicep build-params` compiles both param files with the variable unset,
  which is how the `iac` job already runs.
