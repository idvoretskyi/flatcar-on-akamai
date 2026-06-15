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
