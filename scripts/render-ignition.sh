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
# Kubernetes overlay (CLUSTER in .env, or --cluster):
#   none    : pure Flatcar node (default)
#   k3s     : compile butane/k8s/k3s-server.bu → Ignition fragment, then
#             deep-merge with the base Ignition using scripts/lib/merge-ignition.jq.
#             K3S_TOKEN is auto-generated and persisted to .env if unset.
#
# Usage:  scripts/render-ignition.sh [--backend knuckle|butane] [--cluster none|k3s]
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

load_env

: "${BACKEND:=knuckle}"
: "${CLUSTER:=none}"
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="${2:?--backend needs a value}"; shift 2 ;;
    --cluster) CLUSTER="${2:?--cluster needs a value}"; shift 2 ;;
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

# ---------------------------------------------------------------------------
# k3s overlay — compiled and deep-merged onto the base Ignition when
# CLUSTER=k3s.  Called after the base has been written to $OUT.
# ---------------------------------------------------------------------------
merge_k3s_overlay() {
  require jq envsubst

  # Auto-generate and persist K3S_TOKEN if not already set.
  if [ -z "${K3S_TOKEN:-}" ]; then
    log "K3S_TOKEN not set — generating a random token"
    K3S_TOKEN="$(openssl rand -hex 32)"
    local envfile="${REPO_ROOT}/.env"
    if [ -f "$envfile" ]; then
      # Append only if the key is absent (avoid duplicates on re-runs).
      if ! grep -q '^K3S_TOKEN=' "$envfile"; then
        printf '\n# Auto-generated cluster token (do not share)\nK3S_TOKEN="%s"\n' \
          "$K3S_TOKEN" >> "$envfile"
        log "appended K3S_TOKEN to ${envfile}"
      else
        # Update the existing line in-place.
        sed -i "s|^K3S_TOKEN=.*|K3S_TOKEN=\"${K3S_TOKEN}\"|" "$envfile"
        log "updated K3S_TOKEN in ${envfile}"
      fi
    fi
    export K3S_TOKEN
  fi

  # Download butane if not already present (reuses the same binary as render_butane).
  : "${BUTANE_VERSION:=v0.23.0}"
  local bin="${BUILD_DIR}/butane"
  if [ ! -x "$bin" ]; then
    local url="https://github.com/coreos/butane/releases/download/${BUTANE_VERSION}/butane-x86_64-unknown-linux-gnu"
    log "downloading butane ${BUTANE_VERSION} (for k3s overlay)"
    curl -fsSL -o "$bin" "$url" || die "butane download failed"
    chmod +x "$bin"
  fi

  # Render the overlay template (substitute HOSTNAME + K3S_TOKEN).
  local rendered_overlay="${BUILD_DIR}/k3s-server.rendered.bu"
  # shellcheck disable=SC2016
  HOSTNAME="$HOSTNAME" K3S_TOKEN="$K3S_TOKEN" \
    envsubst '${HOSTNAME} ${K3S_TOKEN}' \
    < "${REPO_ROOT}/butane/k8s/k3s-server.bu" > "$rendered_overlay"

  # Compile overlay Butane → Ignition fragment.
  local overlay_json="${BUILD_DIR}/k3s-overlay.json"
  log "compiling k3s overlay Butane -> Ignition"
  "$bin" --strict < "$rendered_overlay" > "$overlay_json" \
    || die "k3s overlay butane compile failed"

  # Deep-merge: base ($OUT) + overlay → merged.
  local merged="${BUILD_DIR}/ignition.merged.json"
  log "merging base + k3s overlay"
  jq -n \
    --slurpfile base "$OUT" \
    --slurpfile overlay "$overlay_json" \
    -f "${SCRIPT_DIR}/lib/merge-ignition.jq" > "$merged" \
    || die "Ignition merge failed"

  mv "$merged" "$OUT"
  log "k3s overlay merged into ${OUT}"
}

case "$BACKEND" in
  knuckle) render_knuckle ;;
  butane)  render_butane ;;
  *) die "BACKEND must be 'knuckle' or 'butane' (got '${BACKEND}')" ;;
esac

case "$CLUSTER" in
  none|"") : ;;
  k3s)     merge_k3s_overlay ;;
  *) die "CLUSTER must be 'none' or 'k3s' (got '${CLUSTER}')" ;;
esac

# Sanity: valid JSON with an ignition.version field.
jq -e '.ignition.version' "$OUT" >/dev/null 2>&1 || die "output is not valid Ignition JSON"

log "wrote ${OUT} (backend: ${BACKEND}, cluster: ${CLUSTER})"
log "Ignition spec version: $(jq -r '.ignition.version' "$OUT")"
