#!/usr/bin/env bash
# ship phase-5 local gate: path-aware mirror of CI.
#
# Derives selection from the workflows' own paths: filters (via
# tools/gate_paths.py, #226) rather than a hand-maintained regex per workflow,
# runs the matching local gates, and emits one JSON verdict on stdout. A
# failing gate's last 40 log lines go to stderr — never the full log. The
# secrets grep always runs (small-lane floor: a leaked cred is irreversible).
#
# Usage:
#   scripts/ship/local-gate.sh [--base <ref>] [--all] [--no-docker] [--small <pytest-node>]
#
#   --base       diff base (default origin/main); gates select on merge-base..worktree
#   --all        run every gate regardless of the diff
#   --no-docker  mark Docker-requiring gates "deferred-to-ci" instead of running
#                them (cloud fire with DOCKER=absent; PR CI proves them)
#   --small      small lane: secrets grep + the one named pytest node, nothing else
#
# Gate statuses: pass | fail | deferred-to-ci | unavailable (required tool missing)
# Exit: 0 all selected gates pass · 1 a gate failed · 2 a tool was unavailable
set -uo pipefail

cd "$(dirname "$0")/../.." || { echo '{"error":"cd to repo root failed","verdict":"tool-unavailable"}'; exit 2; }

BASE=origin/main ALL=0 NO_DOCKER=0 SMALL=""
while [ $# -gt 0 ]; do
  case $1 in
    --base) BASE=$2; shift 2 ;;
    --all) ALL=1; shift ;;
    --no-docker) NO_DOCKER=1; shift ;;
    --small) SMALL=$2; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

MB=$(git merge-base "$BASE" HEAD) || { echo '{"error":"merge-base failed — fetch the base ref"}'; exit 2; }
# Committed + uncommitted tracked changes vs merge-base, plus untracked files.
FILES=$( { git diff --name-only "$MB"; git ls-files --others --exclude-standard; } | sort -u )

if [ "$NO_DOCKER" = 1 ] || ! docker info >/dev/null 2>&1; then DOCKER=absent; else DOCKER=present; fi

LOGDIR=$(mktemp -d)
trap 'rm -rf "$LOGDIR"' EXIT
RESULTS="" FAILED=0 TOOLING=0

record() { RESULTS="$RESULTS${RESULTS:+,}\"$1\":\"$2\""; }

run_gate() { # run_gate <name> <cmd...>
  local name=$1 log; shift
  log="$LOGDIR/${name//[:\/]/_}.log"
  if "$@" >"$log" 2>&1; then
    record "$name" pass
  else
    record "$name" fail; FAILED=1
    { echo ""; echo "== $name FAILED — last 40 lines =="; tail -40 "$log"; } >&2
  fi
}

pwsh_gate() { # pwsh_gate <name> <pwsh-command>  (unavailable if no pwsh)
  local name=$1 cmd=$2
  if have pwsh; then run_gate "$name" pwsh -NoProfile -Command "$cmd"
  else record "$name" unavailable; TOOLING=1; fi
}

docker_gate() { # docker_gate <name> <cmd...>  (deferred if no docker)
  local name=$1; shift
  if [ "$DOCKER" = present ]; then run_gate "$name" "$@"
  else record "$name" deferred-to-ci; fi
}

# --- secrets grep (always) ---------------------------------------------------
# Scans added diff lines plus untracked files. The throwaway container creds
# (postgres:postgres) are the one sanctioned literal (dev-migrate.sh,
# testcontainers) — IGNORE_RE; the scanner also excludes itself (its own
# pattern line is a guaranteed hit).
SECRET_RE='postgres(ql)?://[^ "'"'"']+:[^ "'"'"'@]+@|bearer +[a-z0-9._~+/=-]{25,}|AKIA[A-Z0-9]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|client_secret[^a-z_]|sig=[a-z0-9%]{30,}'
IGNORE_RE='postgres://postgres:postgres@'
secrets_hits() {
  # Diff scan: added lines, tagged "diff:<n>" (real file lines aren't recoverable
  # from a combined diff, so label the source instead of emitting a bogus number).
  git diff "$MB" -- . ':(exclude)uv.lock' ':(exclude)scripts/ship/local-gate.sh' \
    | grep '^+' | grep -vE '^\+\+\+' | grep -vE "$IGNORE_RE" | grep -nEi "$SECRET_RE" \
    | sed 's/^/diff:/'
  # Untracked scan: grep files by name so hits carry real path:line (-I skips
  # binaries; -H forces the filename even for a single file).
  git ls-files --others --exclude-standard -z \
    | grep -zvF 'scripts/ship/local-gate.sh' \
    | xargs -0 -r grep -IHnEi "$SECRET_RE" 2>/dev/null | grep -vE "$IGNORE_RE" || true
}
if hits=$(secrets_hits) && [ -n "$hits" ]; then
  record secrets fail; FAILED=1
  { echo ""; echo "== secrets FAILED — matching added lines =="; head -20 <<<"$hits"; } >&2
else
  record secrets pass
fi

# --- small lane: one node + secrets, done ------------------------------------
if [ -n "$SMALL" ]; then
  run_gate "pytest:$SMALL" uv run pytest "$SMALL"
else

# Workflow names with no local mirror at all (manual workflow_dispatch only —
# never triggered by a PR diff today). Listed explicitly so they are skipped as
# a deliberate decision; any OTHER unmapped triggered name fails loudly below.
EXCLUDED=' deploy publish-images '
KNOWN_GATES=' python integration docker iac installer bootstrap ci-powerbi '

if [ "$ALL" = 1 ]; then
  wf() { return 0; }
else
  TRIGGERED=$(printf '%s\n' "$FILES" | uv run python -m tools.gate_paths) || {
    echo '{"error":"tools.gate_paths failed to derive selection","verdict":"tool-unavailable"}'
    exit 2
  }
  wf() { grep -qxF "$1" <<<"$TRIGGERED"; }

  # A triggered workflow that is neither a known local gate group nor an
  # explicit exclusion is new (or renamed) and has no local mirror yet —
  # TOOLING rather than silently skipping its checks.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$KNOWN_GATES$EXCLUDED" in
      *" $name "*) ;;
      *) record "$name" unavailable; TOOLING=1 ;;
    esac
  done <<<"$TRIGGERED"
fi

# --- python (python.yml) ------------------------------------------------------
if wf python; then
  run_gate python:ruff uv run ruff check .
  run_gate python:mypy uv run mypy
  run_gate python:sqlfluff uv run sqlfluff lint db/
  run_gate python:pytest-unit uv run pytest -m "not integration"
fi

# --- integration (integration.yml) --------------------------------------------
# CI runs the integration suite, schema-drift, and spec-sync together as one
# integration.yml trigger, so local mirrors that as one group (previously
# schema-drift/spec-sync narrowed to db/ or column_spec.py changes only — that
# no longer matches CI's actual trigger, #226).
if wf integration; then
  docker_gate integration:pytest uv run pytest -m integration

  # The drift verdict (regenerate, normalize pg_dump version comments, diff) is
  # owned by dev-migrate.sh --check (#225) — CI runs the identical call. On drift
  # the regenerated dump is left in the tree (that IS the fix: commit it).
  # column_spec.py rides this gate: a spec edit without its migration drifts even
  # though schema.sql itself is unchanged, so spec_sync --check catches it (#167).
  if [ "$DOCKER" = present ] && have dbmate && have pg_dump; then
    run_gate schema-drift scripts/dev-migrate.sh --check
  elif [ "$DOCKER" = absent ]; then
    record schema-drift deferred-to-ci
  else
    record schema-drift unavailable; TOOLING=1
  fi
  # spec_sync self-spins a throwaway container; unset DATABASE_URL so it never
  # reaches for a real DB (.env points at Azure — CLAUDE.md).
  docker_gate spec-sync bash -c 'unset DATABASE_URL; uv run python -m tools.spec_sync --check'
fi

# --- iac (iac.yml) -------------------------------------------------------------
if wf iac; then
  if have az; then run_gate iac:bicep bash -c 'az bicep build --file iac/main.bicep --stdout >/dev/null'
  else record iac:bicep unavailable; TOOLING=1; fi
  pwsh_gate iac:psrule 'Assert-PSRule -InputPath ./iac/ -Module PSRule.Rules.Azure -ErrorAction Stop'
fi

# --- installer (installer.yml) --------------------------------------------------
if wf installer; then
  pwsh_gate installer:pssa '$f = Invoke-ScriptAnalyzer -Path ./installer -Recurse; if ($f) { $f | Format-Table -AutoSize | Out-String | Write-Host; exit 1 }'
  if have node; then run_gate installer:node-test node --test installer/test_wrapper.mjs
  else record installer:node-test unavailable; TOOLING=1; fi
  pwsh_gate installer:pester 'Import-Module Pester; $c = New-PesterConfiguration; $c.Run.Path = "./installer"; $c.Run.Exit = $true; Invoke-Pester -Configuration $c'
fi

# --- bootstrap (bootstrap.yml) ---------------------------------------------------
if wf bootstrap; then
  pwsh_gate bootstrap:pssa '$f = Invoke-ScriptAnalyzer -Path ./bootstrap -Recurse; if ($f) { $f | Format-Table -AutoSize | Out-String | Write-Host; exit 1 }'
  pwsh_gate bootstrap:pester 'Import-Module Pester; $c = New-PesterConfiguration; $c.Run.Path = "./bootstrap"; $c.Run.Exit = $true; Invoke-Pester -Configuration $c'
fi

# --- docker builds (docker.yml) ---------------------------------------------------
# docker.yml matrix-builds both images on any trigger — mirror both together
# (previously split docker:sink / docker:collector by their own paths; #226).
if wf docker; then
  docker_gate docker:sink docker build -q -t cc-otel-sink:gate sink/
  docker_gate docker:collector docker build -q -t cc-otel-collector:gate collector/
fi

# --- powerbi (ci-powerbi.yml) ------------------------------------------------------
if wf ci-powerbi; then
  pwsh_gate powerbi:validate '.\.github\powerbi\validate.ps1'
fi

fi # end !SMALL

# --- verdict -----------------------------------------------------------------
if [ "$FAILED" = 1 ]; then verdict=fail; rc=1
elif [ "$TOOLING" = 1 ]; then verdict=tool-unavailable; rc=2
else verdict=pass; rc=0; fi

printf '{"base":"%s","docker":"%s","gates":{%s},"verdict":"%s"}\n' \
  "$BASE" "$DOCKER" "$RESULTS" "$verdict"
exit "$rc"
