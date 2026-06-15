#!/usr/bin/env bash
# Pinned tool versions — single source of truth for all scripts and CI.
# Sourced by common.sh. Values can be overridden by exporting the variable
# before sourcing, or by setting them in .env.

# Standalone butane release to use when the binary is not already on PATH.
# Override via BUTANE_VERSION in .env or the environment.
: "${BUTANE_VERSION:=v0.23.0}"

# Release asset suffix (architecture + OS). The upstream project only publishes
# linux-gnu assets; CI and the download helper both run on Linux.
: "${BUTANE_ARCH:=x86_64-unknown-linux-gnu}"

# SHA-256 checksums for each supported asset, keyed by BUTANE_ARCH.
# Computed from the official GitHub release assets; verified by two independent
# downloads. Update both BUTANE_VERSION and the matching checksum together.
# To add a new arch: download the asset and run: shasum -a 256 <file>
# shellcheck disable=SC2034  # used in common.sh after sourcing
BUTANE_SHA256_x86_64_unknown_linux_gnu="5833ce9f9c2932d9b02bc05821ffb6927d1e896a524c8dd53a4c9d2d90c47e2c"

# Resolve the expected checksum for the configured BUTANE_ARCH.
# Converts hyphens to underscores to form a valid shell variable name.
_butane_arch_var="BUTANE_SHA256_$(printf '%s' "$BUTANE_ARCH" | tr '-' '_')"
# shellcheck disable=SC2034  # used in common.sh after sourcing
BUTANE_SHA256="${!_butane_arch_var:-}"
unset _butane_arch_var
