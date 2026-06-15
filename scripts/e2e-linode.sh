#!/usr/bin/env bash
#
# e2e-linode.sh — live end-to-end test against a real Akamai/Linode instance.
#
# Orchestrates the full deploy cycle:
#   1. Preflight  — verify credentials, tools, SSH key, region consistency.
#   2. Image      — download Flatcar + upload as an ephemeral private image;
#                   registered for cleanup immediately.
#   3. Render     — scripts/render-ignition.sh injects the test SSH key.
#   4. Apply      — tofu apply in an isolated state dir; unique instance label.
#   5. Assert     — SSH as core, check os-release / hostname / sshd hardening;
#                   k3s: kubectl get nodes Ready.
#   6. Teardown   — trap-based; always runs (success, failure, or Ctrl-C):
#                   tofu destroy + linode image delete + verify nothing left.
#
# Usage:
#   export LINODE_TOKEN=...
#   scripts/e2e-linode.sh [--cluster none|k3s] [--keep]
#
#   --cluster none   bare Flatcar node, g6-nanode-1   (default)
#   --cluster k3s    k3s overlay,       g6-standard-1
#   --keep           skip teardown so you can inspect the live instance
#                    (prints SSH command; you must destroy manually)
#
# Prerequisites:
#   - LINODE_TOKEN exported (scopes: Linodes RW + Images RW)
#   - linode-cli configured and authenticated
#   - tofu, jq, git, go, openssl, ssh, wget, gzip on PATH
#   - ~/.ssh/id_ed25519  (private key; matching public key injected into Ignition)
#
# Cost: ~$0.01–$0.02/hr (g6-nanode-1 / g6-standard-1). Ephemeral image storage
# is billed only for the duration of the run. See docs/08-e2e-testing.md.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Defaults / argument parsing
# ---------------------------------------------------------------------------
E2E_CLUSTER="none"
E2E_KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster) E2E_CLUSTER="${2:?--cluster needs a value}"; shift 2 ;;
    --keep)    E2E_KEEP=1; shift ;;
    *) die "unknown argument: $1 (usage: $0 [--cluster none|k3s] [--keep])" ;;
  esac
done

case "$E2E_CLUSTER" in
  none|k3s) ;;
  *) die "--cluster must be 'none' or 'k3s' (got '${E2E_CLUSTER}')" ;;
esac

# Region: both the image upload and the instance must be in the same region.
E2E_REGION="${E2E_REGION:-gb-lon}"

# Instance type: nanode for bare Flatcar, standard-1 for k3s.
if [ "$E2E_CLUSTER" = "k3s" ]; then
  E2E_TYPE="${E2E_TYPE:-g6-standard-1}"
else
  E2E_TYPE="${E2E_TYPE:-g6-nanode-1}"
fi

# Unique label so the e2e instance is never confused with existing resources.
E2E_TS="$(date +%Y%m%d-%H%M%S)"
E2E_LABEL="flatcar-e2e-${E2E_TS}"

# Isolated tofu state directory (never touches tofu/ in the repo root).
E2E_TOFU_DIR="${BUILD_DIR}/e2e-tofu"

# SSH key used for the test identity.
E2E_SSH_PRIVKEY="${E2E_SSH_PRIVKEY:-${HOME}/.ssh/id_ed25519}"
E2E_SSH_PUBKEY="${E2E_SSH_PRIVKEY}.pub"

# IDs registered during the run; used by cleanup().
E2E_IMAGE_ID=""
E2E_INSTANCE_IP=""

# ---------------------------------------------------------------------------
# Cleanup — always runs via trap EXIT
# ---------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  # Restore errexit in case we were called from an error handler.
  set +e

  if [ "$E2E_KEEP" -eq 1 ]; then
    warn "--keep is set: skipping teardown."
    if [ -n "$E2E_INSTANCE_IP" ]; then
      warn "SSH command:  ssh -i ${E2E_SSH_PRIVKEY} -o StrictHostKeyChecking=no core@${E2E_INSTANCE_IP}"
    fi
    warn "Run 'make e2e-destroy' or destroy manually when done."
    exit "$exit_code"
  fi

  log "=== TEARDOWN ==="

  # Destroy the instance (tofu destroy).
  if [ -d "${E2E_TOFU_DIR}/.terraform" ]; then
    log "running tofu destroy..."
    tofu -chdir="$E2E_TOFU_DIR" destroy -auto-approve \
      -var "image_id=${E2E_IMAGE_ID:-private/0}" \
      -var "label=${E2E_LABEL}" \
      -var "region=${E2E_REGION}" \
      -var "instance_type=${E2E_TYPE}" \
      -var "ignition_path=${BUILD_DIR}/ignition.json" \
      2>&1 || warn "tofu destroy failed — check the Linode console for instance '${E2E_LABEL}'"
  fi

  # Delete the ephemeral image.
  if [ -n "$E2E_IMAGE_ID" ]; then
    log "deleting ephemeral image ${E2E_IMAGE_ID}..."
    linode-cli images delete "$E2E_IMAGE_ID" 2>&1 \
      || warn "image delete failed — delete '${E2E_IMAGE_ID}' manually via linode-cli or the console"
  fi

  # Verify nothing was left behind.
  local stray_instances stray_images
  stray_instances="$(linode-cli linodes list --text --format=label 2>/dev/null \
    | grep "^${E2E_LABEL}" || true)"
  stray_images="$(linode-cli images list --is_public false --text --format=id,label 2>/dev/null \
    | grep "e2e-${E2E_TS}" || true)"

  if [ -n "$stray_instances" ]; then
    warn "STRAY INSTANCE DETECTED — still billing!  Label: ${E2E_LABEL}"
    warn "Run: linode-cli linodes list  (then delete manually)"
  fi
  if [ -n "$stray_images" ]; then
    warn "STRAY IMAGE DETECTED: ${stray_images}"
    warn "Run: linode-cli images delete <id>"
  fi

  [ -z "$stray_instances" ] && [ -z "$stray_images" ] \
    && log "teardown verified: no stray resources."

  exit "$exit_code"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  log "=== PREFLIGHT ==="
  require tofu jq git go openssl ssh wget linode-cli

  [ -n "${LINODE_TOKEN:-}" ] \
    || die "LINODE_TOKEN is not set. Export it: export LINODE_TOKEN=<token> (scopes: Linodes RW + Images RW)"

  [ -f "$E2E_SSH_PUBKEY" ] \
    || die "SSH public key not found: ${E2E_SSH_PUBKEY} (set E2E_SSH_PRIVKEY to override)"
  [ -f "$E2E_SSH_PRIVKEY" ] \
    || die "SSH private key not found: ${E2E_SSH_PRIVKEY}"

  # Verify linode-cli is authenticated (lightweight read).
  linode-cli regions list --text --format=id >/dev/null 2>&1 \
    || die "linode-cli is not authenticated (run 'linode-cli configure')"

  log "region:       ${E2E_REGION}"
  log "instance:     ${E2E_TYPE}  (cluster=${E2E_CLUSTER})"
  log "label:        ${E2E_LABEL}"
  log "ssh key:      ${E2E_SSH_PUBKEY}"
  log "keep:         ${E2E_KEEP}"
}

# ---------------------------------------------------------------------------
# Image upload (ephemeral — always deleted at teardown)
# ---------------------------------------------------------------------------
upload_image() {
  log "=== IMAGE UPLOAD ==="
  require wget gzip

  local channel="${CHANNEL:-stable}"
  local arch="amd64"
  local img_gz="flatcar_production_akamai_image.bin.gz"
  local url="https://${channel}.release.flatcar-linux.net/${arch}-usr/current/${img_gz}"

  mkdir -p "$BUILD_DIR"
  local dest="${BUILD_DIR}/e2e_${channel}_${img_gz}"

  log "downloading Flatcar ${channel} ${arch} Akamai image..."
  wget -q --show-progress -O "$dest" "$url" \
    || die "download failed: ${url}"

  local image_label="${E2E_LABEL}"
  log "uploading as '${image_label}' to region '${E2E_REGION}'..."
  local upload_out
  upload_out="$(linode-cli image-upload \
    --label "$image_label" \
    --region "$E2E_REGION" \
    --cloud-init \
    --description "Flatcar ${channel} ${arch} — e2e ephemeral (${E2E_TS})" \
    "$dest" 2>&1)" || die "image-upload failed:\n${upload_out}"

  E2E_IMAGE_ID="$(printf '%s\n' "$upload_out" | grep -oE 'private/[0-9]+' | head -n1 || true)"
  [ -n "$E2E_IMAGE_ID" ] \
    || die "could not parse image id from upload output; run 'linode-cli images list' to find it"

  log "image ready: ${E2E_IMAGE_ID}"

  # Clean up the local download — we don't need it after upload.
  rm -f "$dest"
}

# ---------------------------------------------------------------------------
# Render Ignition
# ---------------------------------------------------------------------------
render_ignition() {
  log "=== RENDER IGNITION ==="
  local pubkey
  pubkey="$(cat "$E2E_SSH_PUBKEY")"

  SSH_AUTHORIZED_KEY="$pubkey" \
  NODE_HOSTNAME="$E2E_LABEL" \
    "${SCRIPT_DIR}/render-ignition.sh" \
      --backend "${BACKEND:-knuckle}" \
      --cluster "$E2E_CLUSTER"

  [ -f "${BUILD_DIR}/ignition.json" ] \
    || die "render did not produce build/ignition.json"
  jq -e '.ignition.version' "${BUILD_DIR}/ignition.json" >/dev/null \
    || die "build/ignition.json is not valid Ignition"
  log "Ignition rendered: $(jq -r '.ignition.version' "${BUILD_DIR}/ignition.json")"
}

# ---------------------------------------------------------------------------
# Deploy via OpenTofu (isolated state dir)
# ---------------------------------------------------------------------------
deploy() {
  log "=== DEPLOY ==="

  # Mirror the repo's tofu/ directory into an isolated working copy so we
  # don't touch or pollute the developer's own state.
  rm -rf "$E2E_TOFU_DIR"
  cp -r "${REPO_ROOT}/tofu" "$E2E_TOFU_DIR"

  # Write a per-run tfvars file (never committed — under build/).
  cat > "${E2E_TOFU_DIR}/e2e.auto.tfvars" <<EOF
image_id      = "${E2E_IMAGE_ID}"
region        = "${E2E_REGION}"
instance_type = "${E2E_TYPE}"
label         = "${E2E_LABEL}"
ignition_path = "${BUILD_DIR}/ignition.json"
EOF

  log "running tofu init..."
  tofu -chdir="$E2E_TOFU_DIR" init -upgrade >/dev/null

  log "running tofu apply..."
  tofu -chdir="$E2E_TOFU_DIR" apply -auto-approve

  # Capture public IP from outputs.
  E2E_INSTANCE_IP="$(tofu -chdir="$E2E_TOFU_DIR" output -raw ip_address 2>/dev/null || true)"
  [ -n "$E2E_INSTANCE_IP" ] \
    || die "could not read ip_address from tofu output"
  log "instance IP: ${E2E_INSTANCE_IP}"
}

# ---------------------------------------------------------------------------
# Wait for SSH to become available
# ---------------------------------------------------------------------------
wait_for_ssh() {
  local ip="$1" timeout="${2:-300}" interval=10
  log "waiting for SSH on ${ip} (timeout ${timeout}s)..."
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if ssh -i "$E2E_SSH_PRIVKEY" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=5 \
          -o BatchMode=yes \
          "core@${ip}" true 2>/dev/null; then
      log "SSH is up (elapsed ${elapsed}s)"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  die "SSH did not become available within ${timeout}s on ${ip}"
}

# ---------------------------------------------------------------------------
# Run a command on the instance over SSH
# ---------------------------------------------------------------------------
ssh_run() {
  local ip="$1"; shift
  ssh -i "$E2E_SSH_PRIVKEY" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "core@${ip}" "$@"
}

# ---------------------------------------------------------------------------
# Assert — verify the booted node matches expectations
# ---------------------------------------------------------------------------
assert_node() {
  log "=== ASSERT: bare Flatcar node ==="
  local ip="$E2E_INSTANCE_IP"

  wait_for_ssh "$ip" 300

  # 1. Verify it is Flatcar Container Linux.
  local id
  id="$(ssh_run "$ip" 'grep ^ID= /etc/os-release | cut -d= -f2')"
  [ "$id" = "flatcar" ] \
    || die "FAIL: /etc/os-release ID='${id}' (expected 'flatcar')"
  log "PASS: OS is Flatcar (ID=${id})"

  # 2. Verify hostname was applied via Ignition.
  local hostname
  hostname="$(ssh_run "$ip" hostname)"
  [ "$hostname" = "$E2E_LABEL" ] \
    || die "FAIL: hostname='${hostname}' (expected '${E2E_LABEL}')"
  log "PASS: hostname=${hostname}"

  # 3. Verify SSH hardening drop-in is present.
  ssh_run "$ip" 'test -f /etc/ssh/sshd_config.d/99-hardening.conf' \
    || die "FAIL: /etc/ssh/sshd_config.d/99-hardening.conf not found"
  log "PASS: sshd hardening drop-in present"

  # 4. Verify automatic updates are disabled.
  local reboot_strategy
  reboot_strategy="$(ssh_run "$ip" 'grep REBOOT_STRATEGY /etc/flatcar/update.conf 2>/dev/null || true')"
  printf '%s\n' "$reboot_strategy" | grep -q 'off' \
    || die "FAIL: REBOOT_STRATEGY not set to 'off' in /etc/flatcar/update.conf"
  log "PASS: auto-updates disabled"

  # 5. Verify core user can sudo (group membership via Ignition).
  ssh_run "$ip" 'sudo true' \
    || die "FAIL: core user cannot sudo"
  log "PASS: core user has sudo"
}

# ---------------------------------------------------------------------------
# Assert k3s — wait for the cluster to reach Ready
# ---------------------------------------------------------------------------
assert_k3s() {
  log "=== ASSERT: k3s cluster ==="
  local ip="$E2E_INSTANCE_IP"
  local timeout=600 interval=20 elapsed=0

  log "waiting for k3s node Ready (timeout ${timeout}s)..."
  while [ "$elapsed" -lt "$timeout" ]; do
    local node_status
    # shellcheck disable=SC2016 # $2 is awk's field ref, must not expand locally
    node_status="$(ssh_run "$ip" \
      'sudo kubectl get nodes --no-headers 2>/dev/null | awk "{print \$2}"' 2>/dev/null || true)"
    if [ "$node_status" = "Ready" ]; then
      log "PASS: k3s node is Ready"
      break
    fi
    log "  k3s node status: '${node_status:-<not yet available>}' (elapsed ${elapsed}s)"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  [ "$node_status" = "Ready" ] \
    || die "FAIL: k3s node did not reach Ready within ${timeout}s"

  # Verify k3s server config was applied.
  ssh_run "$ip" 'test -f /etc/rancher/k3s/config.yaml' \
    || die "FAIL: /etc/rancher/k3s/config.yaml not found"
  log "PASS: k3s config.yaml present"

  # Verify the k3s-sysext-install service completed.
  local sysext_state
  sysext_state="$(ssh_run "$ip" \
    'systemctl is-active k3s-sysext-install.service 2>/dev/null || true')"
  [ "$sysext_state" = "active" ] \
    || die "FAIL: k3s-sysext-install.service state='${sysext_state}' (expected 'active')"
  log "PASS: k3s-sysext-install.service active"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
preflight
upload_image
render_ignition
deploy
assert_node
[ "$E2E_CLUSTER" = "k3s" ] && assert_k3s

log "=== E2E PASSED (cluster=${E2E_CLUSTER}) ==="
