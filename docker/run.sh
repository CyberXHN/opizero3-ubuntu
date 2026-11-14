#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 CyberXHN
#
# Host-side wrapper for the OrangePi Zero3 U-Boot build: builds the container
# image on demand, then runs a one-shot container.
#
# Usage (from anywhere in the repo):
#   docker/run.sh                                        # TF-A BL31 + U-Boot build + smoke assertions in the container
#   JOBS=16 docker/run.sh                                # override parallelism (default: nproc)
#   docker/run.sh > build/run_full.log 2>&1 &            # long task: full log to disk + heartbeat polling
#
# Environment variables:
#   JOBS             parallelism passed into the container (default: nproc)
#   IMAGE            container image tag (default: opizero3-uboot-builder:latest)
#   DEBUG            1 = set -x command tracing inside the container build script
#                    (PS4 carries timestamp + file:line). Empty = normal verbosity.
#   APT_MIRROR_MAIN  optional apt mirror for the U-Boot/TF-A build container (ubuntu archive);
#                    passed to the Dockerfile as --build-arg APT_MIRROR. Empty = official archive.
#   APT_SNAPSHOT     optional snapshot.ubuntu.com snapshot ID (YYYYMMDDTHHMMSSZ) freezing the
#                    container's apt toolchain install; forwarded as --build-arg APT_SNAPSHOT.
#                    Scope: effective only while the container deb822 sources point at
#                    archive.ubuntu.com (amd64 builds); the arm64 noble manifest sources point
#                    at ports.ubuntu.com, which the snapshot service does not cover, so the
#                    conf is a harmless no-op there.
#
set -euo pipefail
export LC_ALL=C

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)

# Local overrides live in docker/local.env (git-ignored, not committed to the repo).
ENV_FILE="$ROOT/docker/local.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

IMAGE=${IMAGE:-opizero3-uboot-builder:latest}

cd "$ROOT"

# Re-exec through the docker group if the current session predates group membership.
if ! docker ps >/dev/null 2>&1; then
  if sg docker -c true 2>/dev/null; then
    exec sg docker -c "exec $(printf '%q ' "$0" "$@")"
  fi
  echo "!! Cannot access docker (is the current user in the docker group?)" >&2
  exit 1
fi

# Always refresh the image: instant when layer cache hits; required after any
# change to build-uboot.sh (it is COPY-ed into the image, plus bind-mounted on top).
# An image build failure must abort: continuing with a stale image only fails
# later inside the container. The full log is teed to the console AND kept in
# build/uboot-img-build.log (CI has no other record; locally the file survives
# terminal scrollback).
mkdir -p build
# --progress=plain keeps the output deterministic (no TTY-sniffing) so CI and
# local logs carry the same complete picture.
if ! docker build --progress=plain \
       --build-arg APT_MIRROR="${APT_MIRROR_MAIN:-}" \
       --build-arg APT_SNAPSHOT="${APT_SNAPSHOT:-}" \
       -t "$IMAGE" docker/ 2>&1 | tee "$ROOT/build/uboot-img-build.log"; then
  echo "!! Image build failed, see build/uboot-img-build.log for the full log (refusing to continue with a stale image)" >&2
  exit 1
fi
echo ">> Image $IMAGE ready"

exec docker run --rm \
  --name opizero3-uboot-build \
  -e JOBS="${JOBS:-$(nproc)}" \
  -e DEBUG="${DEBUG:-}" \
  -e BUILD_UID="$(id -u)" -e BUILD_GID="$(id -g)" \
  -v "$ROOT:/work" \
  -v "$ROOT/docker/build-uboot.sh":/usr/local/bin/build-uboot.sh:ro \
  "$IMAGE"
