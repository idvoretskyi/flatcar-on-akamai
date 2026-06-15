#!/usr/bin/env bash
# Shared helpers for flatcar-on-akamai scripts. Sourced, not executed.
set -euo pipefail

# Resolve repo root regardless of where a script is invoked from.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Canonical build output directory. Scripts still run `mkdir -p "$BUILD_DIR"`
# themselves so the directory is only created when actually needed.
BUILD_DIR="${REPO_ROOT}/build"
export BUILD_DIR

# shellcheck source=scripts/lib/versions.sh
. "${BASH_SOURCE[0]%/*}/versions.sh"

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

# ensure_butane — download the pinned butane binary into $BUILD_DIR/butane if it
# is not already present. Echoes the path to the binary.
# Uses BUTANE_VERSION and BUTANE_ARCH from scripts/lib/versions.sh (or overrides
# from the environment / .env).
ensure_butane() {
  require curl
  local bin="${BUILD_DIR}/butane"
  if [ ! -x "$bin" ]; then
    local url="https://github.com/coreos/butane/releases/download/${BUTANE_VERSION}/butane-${BUTANE_ARCH}"
    log "downloading butane ${BUTANE_VERSION}"
    curl -fsSL -o "$bin" "$url" || die "butane download failed"
    chmod +x "$bin"
  fi
  printf '%s' "$bin"
}

# compile_butane <template> <out> <VAR> [VAR ...]
# Substitute the listed variable names with envsubst, then compile the rendered
# Butane template to Ignition JSON with `butane --strict`.
# The caller must have already called ensure_butane (or have butane on PATH) and
# export the listed variables before calling this function.
compile_butane() {
  local template="$1" out="$2"
  shift 2
  local bin
  # Use a pre-downloaded binary if present; fall back to PATH.
  if [ -x "${BUILD_DIR}/butane" ]; then
    bin="${BUILD_DIR}/butane"
  else
    require butane
    bin="butane"
  fi

  # Build the envsubst allowlist (e.g. "${HOSTNAME} ${SSH_AUTHORIZED_KEY}").
  local allowlist=""
  local v
  for v in "$@"; do
    allowlist="${allowlist} \${${v}}"
  done

  require envsubst
  local rendered
  rendered="$(dirname "$out")/$(basename "$template" .bu).rendered.bu"
  # shellcheck disable=SC2016 # envsubst needs the literal variable names, not expansions
  envsubst "$allowlist" < "$template" > "$rendered"
  "$bin" --strict < "$rendered" > "$out" || die "butane compile failed: ${template}"
}

# sed_inplace <expr> <file>
# Portable in-place sed edit. GNU sed -i (no backup suffix) is not available
# on BSD/macOS sed. Write to a temp file and mv instead.
sed_inplace() {
  local expr="$1" file="$2"
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  if sed "$expr" "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    die "sed_inplace failed on ${file}"
  fi
}
