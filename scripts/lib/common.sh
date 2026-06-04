#!/usr/bin/env bash
# Shared helpers for flatcar-on-akamai scripts. Sourced, not executed.
set -euo pipefail

# Resolve repo root regardless of where a script is invoked from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# require <cmd> [cmd...] — fail if any binary is missing from PATH.
require() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { warn "missing required tool: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "install the missing tool(s) above and retry"
}

# load_env — source .env from the repo root if present (does not override the
# shell environment for values already exported).
load_env() {
  local envfile="${REPO_ROOT}/.env"
  if [ -f "$envfile" ]; then
    log "loading ${envfile}"
    set -a
    # shellcheck disable=SC1090
    . "$envfile"
    set +a
  else
    warn ".env not found — relying on the current environment (see .env.example)"
  fi
}

# need_var <NAME> — die if a variable is empty/unset.
need_var() {
  local name="$1"
  [ -n "${!name:-}" ] || die "required variable ${name} is not set (see .env.example)"
}
