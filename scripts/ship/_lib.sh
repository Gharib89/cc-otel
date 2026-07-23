#!/usr/bin/env bash
# Shared helpers for the ship phase scripts (#230). Sourced, never executed.
#
# Owns exactly three concerns that the phase scripts used to each restate:
#   1. the gitignored env-file inventory (copied into the worktree at isolate,
#      back out at merge) — SHIP_ENV_FILES, the single source so a fourth file
#      can't be added to one side and silently lost at the other;
#   2. the `<type>/<slug>-<issue>` branch convention — construct + suffix match;
#   3. the JSON-object emit pattern every script prints on stdout.
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

ship_emit() { # ship_emit <key> <raw-json-value> [<key> <raw-json-value> ...]
  # Values are emitted verbatim: quote strings with ship_qstr, pass bools/arrays raw.
  local out="" k v
  while [ $# -gt 0 ]; do
    k=$1
    v=$2
    shift 2
    out="$out${out:+,}\"$k\":$v"
  done
  printf '{%s}\n' "$out"
}
