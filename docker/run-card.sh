#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 CyberXHN
#
# Host-side wrapper for the OrangePi Zero3 TF-card image build: builds the arm64
# container image on demand, then runs a one-shot container.
#
# Usage (from anywhere in the repo):
#   docker/run-card.sh                                   # build the TF-card image in an arm64 container
#   UB_BIN=build/uboot/u-boot-sunxi-with-spl.bin docker/run-card.sh   # override the U-Boot binary path used by build-card.sh
#   docker/run-card.sh > build/card_full.log 2>&1 &      # long task: full log to disk + heartbeat polling
#
# Environment variables:
#   IMAGE             container image tag (default: opizero3-card-builder:latest)
#   UB_BIN            U-Boot binary path (relative to the repo root) passed to build-card.sh; empty = container default
#   APT_MIRROR_PORTS  optional apt mirror for this container AND the chroot apt phase (ubuntu-ports);
#                     passed to Dockerfile.rootfs as --build-arg APT_MIRROR and into the container
#                     for the chroot apt phase. Empty = official archive.
#   APT_SNAPSHOT      optional snapshot.ubuntu.com snapshot ID (YYYYMMDDTHHMMSSZ) forwarded into
#                     the container for the chroot apt phase of build-card.sh. Empty = live
#                     archive. Dockerfile.rootfs takes no ARG for it: this container
#                     is always arm64 and its sources point at ports.ubuntu.com, which the
#                     snapshot service does not cover, so the image-build toolchain
#                     (e2fsprogs/mtools/...) stays live (low risk; the base image is already
#                     digest-locked).
#   DOCKER_DNS        optional space-separated DNS servers appended as --dns flags. Empty = docker default.
#   CHROOT_DNS        DNS servers written into the image chroot resolv.conf by build-card.sh.
#                     Empty = copy the container resolv.conf.
#   NTP_SERVERS       NTP servers written into the image (systemd-timesyncd drop-in) by build-card.sh.
#                     Empty = distro default.
#   DEBUG             1 = set -x command tracing inside the container build script
#                     (PS4 carries timestamp + file:line). Empty = normal verbosity.
#
set -euo pipefail
export LC_ALL=C

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)

# Local overrides live in docker/local.env (git-ignored, not committed to the repo).
ENV_FILE="$ROOT/docker/local.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

IMAGE=${IMAGE:-opizero3-card-builder:latest}

cd "$ROOT"

# Re-exec through the docker group if the current session predates group membership.
if ! docker ps >/dev/null 2>&1; then
  if sg docker -c true 2>/dev/null; then
    exec sg docker -c "exec $(printf '%q ' "$0" "$@")"
  fi
  echo "!! Cannot access docker (is the current user in the docker group?)" >&2
  exit 1
fi

# Extra docker run args: one --dns flag per DOCKER_DNS entry (space-separated).
EXTRA_ARGS=()
if [ -n "${DOCKER_DNS:-}" ]; then
  for srv in $DOCKER_DNS; do
    EXTRA_ARGS+=(--dns "$srv")
  done
fi

# Always refresh the image: instant when layer cache hits; required after any
# change to build-card.sh (it is COPY-ed into the image, plus bind-mounted on top).
# An image build failure must abort: continuing with a stale image only fails
# later inside the container. The full log is teed to the console AND kept in
# build/img-build.log (CI has no other record; locally the file survives
# terminal scrollback).
mkdir -p build
# --progress=plain keeps the output deterministic (no TTY-sniffing) so CI and
# local logs carry the same complete picture.
if ! docker build --network=host --platform linux/arm64 --progress=plain \
       --build-arg APT_MIRROR="${APT_MIRROR_PORTS:-}" \
       -f docker/Dockerfile.rootfs -t "$IMAGE" docker/ 2>&1 | tee "$ROOT/build/img-build.log"; then
  echo "!! Image build failed, see build/img-build.log for the full log (refusing to continue with a stale image)" >&2
  exit 1
fi
echo ">> Image $IMAGE ready"

# Run containers on the host network so DNS resolution follows the host; needed
# behind local proxies that rewrite /etc/resolv.conf.
# --platform linux/arm64: arm64 container; on amd64 hosts requires qemu-user
# binfmt with the fix-binary flag, native on arm64.
# --privileged: required for mount --bind of /proc /sys /dev inside the chroot.
# Remove a leftover container from a previous run whose --rm cleanup has not
# finished yet, otherwise startup fails with a name conflict.
docker rm -f opizero3-card-build >/dev/null 2>&1 || true
exec docker run --rm \
  --privileged \
  --platform linux/arm64 \
  "${EXTRA_ARGS[@]}" \
  --name opizero3-card-build \
  -e BUILD_UID="$(id -u)" -e BUILD_GID="$(id -g)" \
  -e UB_BIN="${UB_BIN:-}" \
  -e APT_MIRROR_PORTS="${APT_MIRROR_PORTS:-}" \
  -e APT_SNAPSHOT="${APT_SNAPSHOT:-}" \
  -e CHROOT_DNS="${CHROOT_DNS:-}" \
  -e NTP_SERVERS="${NTP_SERVERS:-}" \
  -e DEBUG="${DEBUG:-}" \
  -v "$ROOT:/work" \
  -v "$ROOT/docker/build-card.sh":/usr/local/bin/build-card.sh:ro \
  "$IMAGE"
