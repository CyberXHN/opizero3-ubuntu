# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 CyberXHN
#
# OrangePi Zero3 (H618/sun50i_h616) TF-A BL31 + U-Boot build container.
# Host-side usage: docker/run.sh, or manually:
#   docker build -t opizero3-uboot-builder:latest docker/
#   docker run --rm -v <repo-root>:/work opizero3-uboot-builder:latest
#
# Toolchain: Ubuntu 24.04 (noble) cross gcc-13, within the version range supported
# by the pinned u-boot and TF-A submodule sources. When APT_SNAPSHOT is set, the
# apt package set is frozen to that snapshot.ubuntu.com snapshot (see ARG below).
# gnutls/swig/pyelftools: dependencies of the u-boot host-side tools
# (mkeficapsule / pylibfdt / binman).
FROM ubuntu@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
# ubuntu:24.04 (noble), digest-pinned; multi-arch index digest (amd64 + arm64). Bump to pick up base image updates.

# Optional apt mirror override; empty (default) keeps the official Ubuntu archive.
ARG APT_MIRROR=""
# Optional snapshot.ubuntu.com snapshot ID (YYYYMMDDTHHMMSSZ); freezes the apt
# package set to that UTC timestamp. Takes precedence over APT_MIRROR.
# Coverage note: effective when the container's deb822 sources point at
# archive.ubuntu.com (amd64 manifests). The arm64 manifest of noble points at
# ports.ubuntu.com/ubuntu-ports, which snapshot.ubuntu.com does not serve
# (401) and apt does not snapshot-map -- the conf is a harmless no-op there.
ARG APT_SNAPSHOT=""
# noble uses the deb822 source format (/etc/apt/sources.list.d/ubuntu.sources);
# when APT_SNAPSHOT is set, bootstrap TLS trust from the official http sources
# first (the bare image ships no ca-certificates and snapshot.ubuntu.com is
# https-only), write the snapshot conf, then update+install once against the
# frozen archive; otherwise rewrite the URIs only when a mirror is requested.
# A single update+install follows either branch; set -e keeps failures fatal.
RUN set -e; \
    if [ -n "$APT_SNAPSHOT" ]; then \
      # Bootstrap TLS trust from the official http sources: the bare image
      # ships no ca-certificates and snapshot.ubuntu.com is https-only.
      apt-get update; \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates; \
      printf 'APT::Snapshot "%s";\nAcquire::Check-Valid-Until "false";\n' "$APT_SNAPSHOT" > /etc/apt/apt.conf.d/50snapshot; \
    elif [ -n "$APT_MIRROR" ]; then \
      sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu/|$APT_MIRROR/|g" \
        -e "s|https://archive.ubuntu.com/ubuntu/|$APT_MIRROR/|g" \
        -e "s|http://security.ubuntu.com/ubuntu/|$APT_MIRROR/|g" \
        -e "s|https://security.ubuntu.com/ubuntu/|$APT_MIRROR/|g" \
        /etc/apt/sources.list.d/ubuntu.sources; \
    fi; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      gcc-aarch64-linux-gnu \
      build-essential bc bison flex \
      libssl-dev libgnutls28-dev \
      python3 python3-dev python3-setuptools python3-pyelftools \
      swig device-tree-compiler \
      file git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV LC_ALL=C
WORKDIR /work
COPY build-uboot.sh /usr/local/bin/build-uboot.sh
RUN chmod 755 /usr/local/bin/build-uboot.sh
ENTRYPOINT ["/usr/local/bin/build-uboot.sh"]
