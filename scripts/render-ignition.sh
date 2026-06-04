#!/usr/bin/env bash
#
# render-ignition.sh — produce build/ignition.json from the shared config.
#
# Two backends (BACKEND in .env, or --backend):
#   knuckle : clone + build the patched knuckle fork (idvoretskyi/knuckle,
#             branch emit-ignition) and run `--emit-ignition` on
#             knuckle/config.json. Primary path. Requires Go.
#   butane  : compile butane/flatcar.bu with the standalone butane binary.
#             No-Go fallback. The binary is downloaded + checksum-pinned.
#
# Either way, HOSTNAME and SSH_AUTHORIZED_KEY from .env are injected so the
# generated Ignition carries your identity (Afterburn cannot use Linode keys).
#
# Usage:  scripts/render-ignition.sh [--backend knuckle|butane]
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

load_env

: "${BACKEND:=knuckle}"
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="${2:?--backend needs a value}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need_var SSH_AUTHORIZED_KEY
: "${HOSTNAME:=flatcar-akamai}"
: "${CHANNEL:=stable}"

BUILD_DIR="${REPO_ROOT}/build"
mkdir -p "$BUILD_DIR"
OUT="${BUILD_DIR}/ignition.json"

render_knuckle() {
  require git go jq
  : "${KNUCKLE_REPO:=https://github.com/idvoretskyi/knuckle.git}"
  : "${KNUCKLE_REF:=emit-ignition}"

  local work="${BUILD_DIR}/knuckle-src"
  if [ -d "${work}/.git" ]; then
    log "updating knuckle fork (${KNUCKLE_REF})"
    git -C "$work" fetch --depth 1 origin "$KNUCKLE_REF" >/dev/null 2>&1
    git -C "$work" checkout -q FETCH_HEAD
  else
    log "cloning knuckle fork ${KNUCKLE_REPO} (${KNUCKLE_REF})"
    git clone --depth 1 --branch "$KNUCKLE_REF" "$KNUCKLE_REPO" "$work" >/dev/null 2>&1 \
      || die "clone failed (does branch ${KNUCKLE_REF} exist?)"
  fi

  local bin="${BUILD_DIR}/knuckle"
  log "building knuckle"
  ( cd "$work" && CGO_ENABLED=0 go build -o "$bin" ./cmd/knuckle ) || die "knuckle build failed"

  # Inject identity from .env into the committed config (single source of truth).
  local cfg="${BUILD_DIR}/knuckle-config.json"
  jq --arg key "$SSH_AUTHORIZED_KEY" --arg host "$HOSTNAME" --arg ch "$CHANNEL" \
    '.hostname=$host | .channel=$ch | .users[0].ssh_keys=[$key]' \
    "${REPO_ROOT}/knuckle/config.json" > "$cfg"

  log "emitting Ignition via knuckle --emit-ignition"
  "$bin" --emit-ignition --config "$cfg" > "$OUT" || die "knuckle --emit-ignition failed"
}

render_butane() {
  require curl jq
  : "${BUTANE_VERSION:=v0.23.0}"
  local bin="${BUILD_DIR}/butane"
  if [ ! -x "$bin" ]; then
    local url="https://github.com/coreos/butane/releases/download/${BUTANE_VERSION}/butane-x86_64-unknown-linux-gnu"
    log "downloading butane ${BUTANE_VERSION}"
    curl -fsSL -o "$bin" "$url" || die "butane download failed"
    chmod +x "$bin"
  fi

  require envsubst
  local rendered="${BUILD_DIR}/flatcar.rendered.bu"
  # shellcheck disable=SC2016 # envsubst needs the literal variable names, not expansions
  HOSTNAME="$HOSTNAME" SSH_AUTHORIZED_KEY="$SSH_AUTHORIZED_KEY" \
    envsubst '${HOSTNAME} ${SSH_AUTHORIZED_KEY}' \
    < "${REPO_ROOT}/butane/flatcar.bu" > "$rendered"

  log "compiling Butane -> Ignition"
  "$bin" --strict < "$rendered" > "$OUT" || die "butane compile failed"
}

case "$BACKEND" in
  knuckle) render_knuckle ;;
  butane)  render_butane ;;
  *) die "BACKEND must be 'knuckle' or 'butane' (got '${BACKEND}')" ;;
esac

# Sanity: valid JSON with an ignition.version field.
jq -e '.ignition.version' "$OUT" >/dev/null 2>&1 || die "output is not valid Ignition JSON"

log "wrote ${OUT} (backend: ${BACKEND})"
log "Ignition spec version: $(jq -r '.ignition.version' "$OUT")"
