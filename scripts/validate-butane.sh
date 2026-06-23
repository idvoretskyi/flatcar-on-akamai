#!/usr/bin/env bash
#
# validate-butane.sh — offline validation of the Butane templates.
#
# Compiles butane/flatcar.bu and butane/k8s/k3s-server.bu with canonical
# test fixtures, deep-merges the results, and asserts that expected content
# is present in the merged Ignition document.
#
# This script is the single source of truth for butane validation. It is
# called by:
#   - `make validate`
#   - .github/workflows/ci.yml (butane job)
#
# The pinned butane version comes from scripts/lib/versions.sh (or an
# override in .env / the environment).  On Linux the binary is downloaded
# to build/butane if it is not already on PATH.  On other platforms the
# script requires butane to be on PATH; if it is absent it exits 0 with a
# clear advisory (so local macOS `make validate` still passes the rest of
# the suite).
#
# Usage:  scripts/validate-butane.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

# Source .env so a BUTANE_VERSION override there is respected, consistent with
# the other scripts. In CI there is no .env; the default from versions.sh is used.
load_env

mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Canonical test fixtures — defined once here, used for all three checks.
# ---------------------------------------------------------------------------
TEST_HOSTNAME="ci-test"
TEST_SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ci@test"
TEST_K3S_TOKEN="ci-test-token-000000000000000000000000000000"

# ---------------------------------------------------------------------------
# Resolve butane: prefer build/butane (downloaded by ensure_butane), then
# PATH.  On non-Linux platforms without a PATH butane, skip gracefully.
# ---------------------------------------------------------------------------
resolve_butane() {
  if [ -x "${BUILD_DIR}/butane" ]; then
    return 0
  fi
  if command -v butane >/dev/null 2>&1; then
    return 0
  fi
  # Attempt to download (works on Linux; the upstream asset is linux-gnu only).
  if [ "$(uname -s)" = "Linux" ]; then
    ensure_butane > /dev/null
    return 0
  fi
  # Non-Linux without a PATH butane: skip with advisory.
  warn "butane not found and the pinned release is linux-only — skipping butane validation"
  warn "Install butane manually or run 'make validate' on Linux / in CI."
  exit 0
}

resolve_butane

require jq envsubst

# ---------------------------------------------------------------------------
# 1. Compile base (flatcar.bu)
# ---------------------------------------------------------------------------
log "compiling base: butane/flatcar.bu"
BASE_JSON="${BUILD_DIR}/validate-base.json"
HOSTNAME="$TEST_HOSTNAME" SSH_AUTHORIZED_KEY="$TEST_SSH_KEY" \
  compile_butane "${REPO_ROOT}/butane/flatcar.bu" "$BASE_JSON" HOSTNAME SSH_AUTHORIZED_KEY
jq -e '.ignition.version' "$BASE_JSON" >/dev/null
log "butane: flatcar.bu OK"

# ---------------------------------------------------------------------------
# 2. Compile k3s overlay (k3s-server.bu)
# ---------------------------------------------------------------------------
log "compiling k3s overlay: butane/k8s/k3s-server.bu"
K3S_JSON="${BUILD_DIR}/validate-k3s-overlay.json"
HOSTNAME="$TEST_HOSTNAME" K3S_TOKEN="$TEST_K3S_TOKEN" \
  compile_butane "${REPO_ROOT}/butane/k8s/k3s-server.bu" "$K3S_JSON" HOSTNAME K3S_TOKEN
jq -e '.ignition.version' "$K3S_JSON" >/dev/null
log "butane: k3s-server.bu OK"

# ---------------------------------------------------------------------------
# 3. Merge base + overlay and assert expected content.
# ---------------------------------------------------------------------------
log "merging base + k3s overlay"
MERGED_JSON="${BUILD_DIR}/validate-merged.json"
jq -n \
  --slurpfile base    "$BASE_JSON" \
  --slurpfile overlay "$K3S_JSON" \
  -f "${SCRIPT_DIR}/lib/merge-ignition.jq" > "$MERGED_JSON" \
  || die "Ignition merge failed"

jq -e '.ignition.version' "$MERGED_JSON" >/dev/null

# Assert k3s systemd units are present.
# Use index/any for exact-membership rather than contains(), which does
# substring matching on string elements and could produce false positives.
jq -e '
  .systemd.units | map(.name) as $names |
  ["k3s.service","k3s-sysext-install.service"] |
  all(. as $x | $names | index($x) != null)
' "$MERGED_JSON" >/dev/null \
  || die "merged Ignition is missing expected k3s systemd units"

# Assert expected file paths are present (exact-membership, same rationale).
jq -e '
  .storage.files | map(.path) as $paths |
  ["/etc/rancher/k3s/config.yaml","/etc/hostname"] |
  all(. as $x | $paths | index($x) != null)
' "$MERGED_JSON" >/dev/null \
  || die "merged Ignition is missing expected storage files"

log "merge + content assertions: OK"
log "butane validation passed (version: $(jq -r '.ignition.version' "$MERGED_JSON"))"
