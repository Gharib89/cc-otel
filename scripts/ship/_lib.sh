#!/usr/bin/env bash
# Shared helpers for the ship phase scripts (#230). Sourced, never executed.
#
# Owns exactly five concerns that the phase scripts used to each restate:
#   1. the gitignored env-file inventory (copied into the worktree at isolate,
#      back out at merge) — SHIP_ENV_FILES, the single source so a fourth file
#      can't be added to one side and silently lost at the other;
#   2. the `<type>/<slug>-<issue>` branch convention — construct + suffix match;
#   3. the JSON-object emit pattern every script prints on stdout;
#   4. the secrets-scan regexes local-gate.sh greps with (#269) — security
#      load-bearing, so they live here where test_ship_lib.py can exercise them;
#   5. the Windows-PowerShell Pester exit-code mapping (#401) — same reason: the
#      "exit 3 never reads as pass" rule needs a test.
#
# Kept intentionally shallow: local-gate.sh keeps its own record()/verdict logic,
# and claim.sh/reflect.sh stay one-liners over these helpers.

# 1. Env-file inventory ------------------------------------------------------
# The gitignored files that carry cloud access into a worktree. isolate.sh copies
# them in; merge.sh copies them back out before destroying the worktree.
SHIP_ENV_FILES=(.env .env.interim .env.prod)

# 2. Branch convention -------------------------------------------------------
ship_branch() { # ship_branch <type> <slug> <issue> -> "<type>/<slug>-<issue>"
  printf '%s/%s-%s' "$1" "$2" "$3"
}

ship_branch_suffix_re() { # ship_branch_suffix_re <issue> -> anchored "-<issue>$"
  printf -- '-%s$' "$1"
}

# 3. JSON emit ---------------------------------------------------------------
ship_qstr() { # ship_qstr <string> -> a JSON string literal (escapes \ " and \t \r \n)
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

ship_emit() { # ship_emit <key> <value> [<key> <value> ...]
  # Default: <value> is quoted/escaped as a JSON string. An @-prefixed value is
  # emitted as raw JSON (bools, numbers, arrays, objects) after the sigil is
  # stripped. Forgetting the sigil yields a valid, stringified value — never
  # invalid JSON. `@` is recognised only as the first character; the inverse
  # footgun (a string value whose content starts with `@` emits as raw) has no
  # caller today — every string emitted here has a literal non-`@` prefix.
  local out="" k v
  while [ $# -gt 0 ]; do
    k=$1
    v=$2
    shift 2
    case $v in
      @*) v=${v#@} ;;
      *)  v=$(ship_qstr "$v") ;;
    esac
    out="$out${out:+,}\"$k\":$v"
  done
  printf '{%s}\n' "$out"
}

# 4. Secrets-scan regexes ----------------------------------------------------
# local-gate.sh's always-on secrets grep matches SECRET_RE (case-insensitive)
# on added diff lines + untracked files, minus IGNORE_RE. The throwaway
# container creds (postgres:postgres) are the one sanctioned literal.
# NB: this file is itself a guaranteed SECRET_RE hit — local-gate.sh excludes it
# from the scan alongside its own path.
SECRET_RE='postgres(ql)?://[^ "'"'"']+:[^ "'"'"'@]+@|bearer +[a-z0-9._~+/=-]{25,}|AKIA[A-Z0-9]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|client_secret[^a-z_]|sig=[a-z0-9%]{30,}'
IGNORE_RE='postgres://postgres:postgres@'

# 5. Windows PowerShell Pester status ----------------------------------------
# local-gate.sh runs the bootstrap Pester suite under Windows PowerShell 5.1 —
# the shell bootstrap.yml's CI job uses — through winps-pester.ps1, which exits 3
# when no Pester 5 is reachable from 5.1. Lives here rather than in local-gate.sh
# so test_ship_lib.py can pin the mapping: exit 3 must never read as `pass`, or
# "local gate green" silently means less than CI green (#401).
ship_winps_pester_status() { # ship_winps_pester_status <exit-code> -> pass|unresolved|fail
  case $1 in
    0) printf 'pass' ;;
    3) printf 'unresolved' ;;
    *) printf 'fail' ;;
  esac
}
