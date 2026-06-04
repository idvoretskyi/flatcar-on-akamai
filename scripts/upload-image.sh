#!/usr/bin/env bash
#
# upload-image.sh — one-time upload of the official Flatcar Akamai image to your
# Linode account as a private image. Prints the resulting `private/<id>`, which
# you set as IMAGE_ID in .env (and tofu/terraform.tfvars).
#
# This is the only script that uploads anything. It does NOT create instances
# and does NOT cost compute. Custom images do incur a small storage charge.
#
# Usage:  scripts/upload-image.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

load_env
require wget gzip du linode-cli

: "${CHANNEL:=stable}"
: "${ARCH:=amd64}"
: "${REGION:?set REGION in .env}"
: "${LABEL:=flatcar}"

case "$CHANNEL" in
  stable|beta|alpha) ;;
  *) die "CHANNEL must be stable, beta, or alpha (got '${CHANNEL}')" ;;
esac
[ "$ARCH" = "amd64" ] || die "this script currently supports ARCH=amd64 only (got '${ARCH}')"

BUILD_DIR="${REPO_ROOT}/build"
mkdir -p "$BUILD_DIR"

IMG_GZ="flatcar_production_akamai_image.bin.gz"
URL="https://${CHANNEL}.release.flatcar-linux.net/${ARCH}-usr/current/${IMG_GZ}"
DEST="${BUILD_DIR}/${CHANNEL}_${IMG_GZ}"

log "downloading ${URL}"
wget -q --show-progress -O "$DEST" "$URL" || die "download failed"

# Linode image upload limit is 6 GiB (compressed upload payload).
SIZE_BYTES="$(du -b "$DEST" | cut -f1)"
LIMIT=$((6 * 1024 * 1024 * 1024))
log "downloaded $(du -h "$DEST" | cut -f1)"
[ "$SIZE_BYTES" -le "$LIMIT" ] || die "image exceeds Linode's 6 GiB upload limit"

IMAGE_LABEL="${LABEL}-${CHANNEL}-$(date +%Y%m%d)"
log "uploading as image '${IMAGE_LABEL}' to region '${REGION}' (--cloud-init)"

# --cloud-init marks the image as metadata-aware so the Linode Metadata service
# (and thus Afterburn/Ignition user_data) is available to instances built from
# it. The OpenTofu linode_image resource cannot set this flag, which is why the
# upload is done here via linode-cli.
OUT="$(linode-cli image-upload \
  --label "$IMAGE_LABEL" \
  --region "$REGION" \
  --cloud-init \
  --description "Flatcar ${CHANNEL} ${ARCH} (flatcar-on-akamai)" \
  "$DEST" 2>&1)" || die "image-upload failed:\n${OUT}"

printf '%s\n' "$OUT" >&2

IMAGE_ID="$(printf '%s\n' "$OUT" | grep -oE 'private/[0-9]+' | head -n1 || true)"
[ -n "$IMAGE_ID" ] || die "could not parse image id from upload output above; run 'linode-cli images list' to find it"

log "image ready: ${IMAGE_ID}"
log "set this in .env and tofu/terraform.tfvars:"
printf 'IMAGE_ID=%s\n' "$IMAGE_ID"
