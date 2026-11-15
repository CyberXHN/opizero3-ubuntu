#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 CyberXHN
#
# OrangePi Zero3 (H618) TF card image builder; runs as root inside the arm64
# build container (host entry point: docker/run-card.sh).
#
# Pipeline: preflight assertions -> rootfs staging (ubuntu-base 26.04) ->
#   chroot preconfiguration (official-style login MOTD) -> chroot apt install (linux-image-generic +
#   grub-efi-arm64; optionally frozen to an APT_SNAPSHOT archive snapshot) ->
#   DTB LED patch -> first-run services (SSH host-key + machine-id regen,
#   orangepi_first_run.txt network consumer) -> grub boot chain (grub-install layout
#   pass + BOOTAA64.EFI built by grub-mkimage with an explicit prefix +
#   hand-written minimal grub.cfg + ESP stub cfg) -> chroot finalization ->
#   privileged-free assembly (ESP 256 MiB FAT32 + ext4 3840 MiB, MBR dual
#   partition) -> 16 post-build assertions.
#
# Implementation constraints:
#   - Writes only under build/ (image, staging tree, temporary ESP file); no
#     real block device is ever touched: the image is a plain file assembled
#     with truncate + sfdisk + dd + mkfs.ext4 -E offset -d, and the ESP has no
#     mkfs -d equivalent for FAT, so it is populated with mtools
#     (mformat/mcopy) into a standalone file and dd'd in. No losetup, no
#     kpartx.
#   - The /dev /proc /sys bind mounts MUST be unmounted before mkfs.ext4 -d
#     copies the staging tree, otherwise the whole bind-mounted /proc tree
#     ends up inside the image.
#   - systemd wants links use absolute symlink targets and systemctl is not
#     usable inside the chroot (systemd runs as PID 1 only on the board), so
#     they are created manually; verify with [ -L ] only -- a host-side
#     [ -e ] resolves the target against the build container root instead of
#     the staging tree and misreports every link as dangling.
#   - grub-mkconfig runs grub-probe on / before reading /etc/default/grub,
#     and inside the chroot that probe hits a build-host disk, so the device/
#     UUID/FS overrides are written into the file and BOOTAA64.EFI is rebuilt
#     by grub-mkimage with an explicit prefix rather than trusting
#     grub-install.
#
# Environment variables (optional; defaults are the official Ubuntu behavior):
#   UB_BIN            U-Boot artifact path; empty falls back to
#                     $BUILD/uboot/u-boot-sunxi-with-spl.bin (run-card.sh
#                     forwards it automatically).
#   APT_MIRROR_PORTS  apt mirror base URL; empty (default) keeps the official
#                     sources. When set, every http/https variant of
#                     ports.ubuntu.com/ubuntu-ports, archive.ubuntu.com/ubuntu
#                     and security.ubuntu.com/ubuntu is rewritten to this
#                     value; if apt-get update then fails, the official
#                     sources are restored and the update retried once.
#   APT_SNAPSHOT      snapshot.ubuntu.com snapshot ID (YYYYMMDDTHHMMSSZ);
#                     empty (default) keeps the live archive. When set, all
#                     chroot apt update/install traffic resolves to that
#                     frozen snapshot (the kernel and every package stay
#                     pinned to that day) via the native apt 24.04+
#                     APT::Snapshot mapping. Takes priority over
#                     APT_MIRROR_PORTS (the mirror rewrite is skipped); a
#                     dead snapshot ID aborts the build outright -- no
#                     fallback to the live archive; the 50snapshot conf is
#                     removed before image assembly, so on-board apt is
#                     unaffected.
#   CHROOT_DNS        space-separated DNS servers written as nameserver lines
#                     into the chroot resolv.conf; empty (default) copies the
#                     container /etc/resolv.conf (docker's embedded DNS at
#                     127.0.0.11 is reachable because the chroot shares the
#                     container network namespace). Build-phase only: the
#                     finalize step replaces the file with the
#                     systemd-resolved stub symlink, so no build-host
#                     resolver ever ships in the image.
#   NTP_SERVERS       space-separated NTP servers written to
#                     /etc/systemd/timesyncd.conf.d/90-custom.conf with
#                     FallbackNTP=ntp.ubuntu.com; empty (default) leaves
#                     systemd-timesyncd on the distro defaults.
#   DEBUG             1 = set -x command tracing (PS4: timestamp + file:line);
#                     empty (default) keeps normal verbosity.
#   BUILD_UID/GID     build outputs are chowned back to this host user at the
#                     end (run-card.sh passes them automatically).
#
set -euo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

# DEBUG=1 enables full command tracing (run-card.sh forwards it); the PS4
# prefix carries a timestamp and file:line so CI logs can be correlated
# per phase.
if [ "${DEBUG:-}" = "1" ]; then
  PS4='+ $(date "+%H:%M:%S") ${BASH_SOURCE}:${LINENO}: '
  set -x
fi

ROOT=/work
BUILD="$ROOT/build"
ROOTFS="$BUILD/rootfs"
UB_BIN="${UB_BIN:-$BUILD/uboot/u-boot-sunxi-with-spl.bin}"
TARBALL="$ROOT/downloads/ubuntu-base-26.04.1-base-arm64.tar.gz"
GRUB_CFG="$ROOTFS/boot/grub/grub.cfg"
ESP_TMP="$BUILD/esp.tmp"
APT_MIRROR_PORTS=${APT_MIRROR_PORTS:-}
APT_SNAPSHOT=${APT_SNAPSHOT:-}
CHROOT_DNS=${CHROOT_DNS:-}
NTP_SERVERS=${NTP_SERVERS:-}
BUILD_UID=${BUILD_UID:?BUILD_UID is not set}
BUILD_GID=${BUILD_GID:-$BUILD_UID}

IMG="$BUILD/orangepi-zero3-ubuntu-26.04.img"
CARD_HOSTNAME=orangepizero3
ROOT_UUID=""   # generated in the chroot preconfiguration section; shared by
               # /etc/default/grub, mkfs.ext4 -U and the ESP stub cfg

T_LAST=$(date +%s)
CUR_PHASE=""
phase() {
  if [ -n "$CUR_PHASE" ]; then
    echo ">> [$(date '+%H:%M:%S')] phase [$CUR_PHASE] took $(( $(date +%s) - T_LAST ))s"
  fi
  CUR_PHASE="$1"
  T_LAST=$(date +%s)
  echo "== [$(date '+%H:%M:%S')] phase: $CUR_PHASE =="
}

cleanup() {
  set +e
  for m in sys proc dev; do
    if mountpoint -q "$ROOTFS/$m" 2>/dev/null; then umount "$ROOTFS/$m"; fi
  done
  if [ -d "$ROOTFS" ]; then
    chown -R "$BUILD_UID:$BUILD_GID" "$ROOTFS" 2>/dev/null
  fi
  if [ -f "$IMG" ]; then
    chown "$BUILD_UID:$BUILD_GID" "$IMG" 2>/dev/null
  fi
  if [ -f "$ESP_TMP" ]; then
    chown "$BUILD_UID:$BUILD_GID" "$ESP_TMP" 2>/dev/null
  fi
  set -e
}
trap cleanup EXIT

fail() { echo "!! FAILED: $*" >&2; exit 1; }

# Normalize . and .. path components in pure shell (no symlink resolution);
# $1 is deliberately unquoted so it word-splits on /.
norm() {
  local out="" seg
  local IFS=/
  for seg in $1; do
    if [ -z "$seg" ] || [ "$seg" = "." ]; then continue; fi
    if [ "$seg" = ".." ]; then
      out=${out%/*}
    else
      out="$out/$seg"
    fi
  done
  printf '%s\n' "${out:-/}"
}

echo "== OrangePi Zero3 image build (arm64 container) =="
phase "preflight assertions"

# ---- 1. Preflight assertions ----
# U-Boot sanity: SPL magic at offset 4, artifact under 1 MiB (it is dd'd at
# offset 8 KiB).
[ -f "$UB_BIN" ] || fail "missing U-Boot artifact: $UB_BIN"
UB_SZ=$(stat -c%s "$UB_BIN")
[ "$UB_SZ" -lt 1048576 ] || fail "U-Boot is $UB_SZ bytes, must be smaller than 1 MiB"
EGON=$(dd if="$UB_BIN" bs=1 skip=4 count=8 2>/dev/null) \
  || fail "cannot read the U-Boot SPL header region (dd failed)"
grep -aq 'eGON.BT0' <<<"$EGON" || fail "no eGON.BT0 magic at U-Boot offset 4"
echo "U-Boot: $UB_SZ bytes"
sha256sum "$UB_BIN"
[ -f "$TARBALL" ] || fail "missing ubuntu-base tarball: $TARBALL"
echo "tarball: $(stat -c%s "$TARBALL") bytes"

# ---- 2. rootfs staging ----
phase "rootfs staging"

if [ -e "$ROOTFS" ]; then
  # Batch-export all symlinks at once (stat %N carries the target): the tree
  # holds tens of thousands of links, so the analysis below is pure bash with
  # zero forks instead of one process per link.
  SYMS_RAW=$(find "$ROOTFS" -type l -exec stat -c '%n -> %N' {} + 2>/dev/null || true)
  if [ -n "$SYMS_RAW" ]; then
    # Safe recursive-deletion precheck; two real escape channels:
    #  a) mount points / cross-device directories (rm -rf would delete
    #     through the mount into the mounted source);
    #  b) symlinks -- GNU rm never follows them (inside or outside the tree),
    #     and under chroot semantics an absolute target always lands inside
    #     the tree, so single-hop + pure-bash normalization is sufficient;
    #     host-side readlink -m would false-positive on in-tree links such as
    #     /var/lock -> /run/lock or /usr/bin/awk -> /etc/alternatives/awk.
    TOPDEV=$(stat -c%d "$ROOTFS")
    ESCD=$(find "$ROOTFS" -type d -exec stat -c '%d %n' {} + 2>/dev/null | awk -v t="$TOPDEV" '$1 != t {print $2}')
    if [ -n "$ESCD" ]; then
      printf '%s\n' "$ESCD"
      fail "mount point or cross-device directory found in staging; inspect manually before rebuilding"
    fi
    NSYM=0
    ESCAPE=0
    while IFS= read -r line; do
      l=${line%% -> *}
      t=${line#* -> }
      t=${t#\'}
      t=${t%\'}
      if [ -z "$l" ]; then continue; fi
      NSYM=$((NSYM+1))
      p=${l#"$ROOTFS"}
      case "$t" in
        /*) q=$t ;;
        *)  q=${p%/*}/$t ;;
      esac
      q=$(norm "$q")
      case "$ROOTFS$q" in
        "$ROOTFS"|"$ROOTFS"/*) ;;
        *) ESCAPE=1; echo "  escaping symlink: $l -> $t (normalized to $q)" ;;
      esac
    done <<<"$SYMS_RAW"
    if [ "$ESCAPE" = 1 ]; then
      fail "staging symlink target escapes the staging tree; inspect manually before rebuilding"
    fi
    echo ">> staging: $NSYM symlinks all resolve inside the tree (single-hop chroot semantics + pure-bash normalization), no mount points; rebuilding"
  fi
  rm -rf "$ROOTFS"
fi
mkdir -p "$ROOTFS"
tar -xzf "$TARBALL" -C "$ROOTFS"
echo ">> ubuntu-base extracted: $(find "$ROOTFS" -type f | wc -l) files, $(find "$ROOTFS" -type l | wc -l) symlinks, $(du -sh "$ROOTFS" 2>/dev/null | cut -f1)"

# ---- 3. chroot preconfiguration (everything lands before apt install) ----
phase "chroot preconfiguration"

mount --bind /dev  "$ROOTFS/dev"
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys  "$ROOTFS/sys"
echo ">> bind-mounted /dev /proc /sys"

# DNS for the chroot apt phase only (CHROOT_DNS overrides the container
# resolver): the finalize step replaces this file with the
# systemd-resolved stub symlink before image assembly.
if [ -n "$CHROOT_DNS" ]; then
  : > "$ROOTFS/etc/resolv.conf"
  for ns in $CHROOT_DNS; do
    printf 'nameserver %s\n' "$ns" >> "$ROOTFS/etc/resolv.conf"
  done
else
  cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
fi
echo "--- $ROOTFS/etc/resolv.conf ---"
cat "$ROOTFS/etc/resolv.conf"

# apt sources: ubuntu-base ships deb822 .sources and/or classic .list files.
SRC_FILES=()
for f in "$ROOTFS/etc/apt/sources.list" "$ROOTFS"/etc/apt/sources.list.d/*.sources "$ROOTFS"/etc/apt/sources.list.d/*.list; do
  if [ -f "$f" ]; then SRC_FILES+=("$f"); fi
done
[ "${#SRC_FILES[@]}" -gt 0 ] || fail "no apt source file found in staging"
for f in "${SRC_FILES[@]}"; do
  echo "--- $f (original) ---"
  cat "$f"
done
# APT_MIRROR_PORTS rewrites every official variant to the mirror base URL
# (suite and components stay intact); empty keeps the official sources.
# APT_SNAPSHOT takes priority: in snapshot mode the sources keep their
# official URIs and APT::Snapshot (50snapshot, written below) maps them onto
# the frozen snapshot -- rewriting to a live mirror would break the freeze
# and silently un-pin the package set.
if [ -n "$APT_MIRROR_PORTS" ] && [ -z "$APT_SNAPSHOT" ]; then
  sed -i "s|http://ports.ubuntu.com/ubuntu-ports|$APT_MIRROR_PORTS|g; s|https://ports.ubuntu.com/ubuntu-ports|$APT_MIRROR_PORTS|g; s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR_PORTS|g; s|https://archive.ubuntu.com/ubuntu|$APT_MIRROR_PORTS|g; s|http://security.ubuntu.com/ubuntu|$APT_MIRROR_PORTS|g; s|https://security.ubuntu.com/ubuntu|$APT_MIRROR_PORTS|g" "${SRC_FILES[@]}"
  for f in "${SRC_FILES[@]}"; do
    echo "--- $f (rewritten to $APT_MIRROR_PORTS) ---"
    cat "$f"
  done
fi

# Apt archive snapshot freeze (APT_SNAPSHOT): snapshot.ubuntu.com is
# https-only and the ubuntu-base tarball ships no usable CA material, so TLS
# trust is bootstrapped from the live archive over plain http before the
# freeze is armed. Copying the container's store in is NOT sufficient: the
# tarball has no /usr/lib/ssl OPENSSLDIR anchor and the copied cert chains
# dangle without /usr/share/ca-certificates, so snapshot fetches fail
# certificate verification. Installing the real package lays
# down a complete, managed store. APT::Snapshot is native on apt 24.04+ and
# maps every official archive/security URI to
# https://snapshot.ubuntu.com/ubuntu/<id>/dists/...; Check-Valid-Until is
# disabled because a frozen Release carries a Valid-Until date that ages past
# within weeks (GPG signatures are still verified and the snapshot store is
# immutable, so the expiry check is meaningless here).
if [ -n "$APT_SNAPSHOT" ]; then
  chroot "$ROOTFS" apt-get update
  chroot "$ROOTFS" apt-get install -y --no-install-recommends ca-certificates
  mkdir -p "$ROOTFS/etc/apt/apt.conf.d"
  printf 'APT::Snapshot "%s";\nAcquire::Check-Valid-Until "false";\n' "$APT_SNAPSHOT" \
    > "$ROOTFS/etc/apt/apt.conf.d/50snapshot"
  echo "--- 50snapshot (APT::Snapshot $APT_SNAPSHOT) written after live CA bootstrap ---"
fi

# Block service starts during the apt install; must be removed before
# assembly, otherwise it ships in the image and blocks services on the board.
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod 755 "$ROOTFS/usr/sbin/policy-rc.d"

# Keep the linux-image-generic meta package (upstream kernel tracking) while
# staying firmware-free: dpkg skips unpacking every firmware blob, during
# this build and during on-board apt upgrades. The linux-firmware packages
# remain installed in dpkg state (the meta Depends chain stays healthy), but
# their ~770 MB of x86/server blobs never land on disk. regulatory.db stays:
# it belongs to wireless-regdb (a linux-modules Depends) and its absence
# makes the kernel log regulatory warnings. To restore real firmware later:
# remove this file, then: apt install --reinstall linux-firmware-*
mkdir -p "$ROOTFS/etc/dpkg/dpkg.cfg.d"
cat > "$ROOTFS/etc/dpkg/dpkg.cfg.d/01-opizero3-minimal" <<'DPKGMIN'
path-exclude=/usr/lib/firmware/*
path-include=/usr/lib/firmware/regulatory.db
path-include=/usr/lib/firmware/regulatory.db.p7s
# The kernel packages ship their device-tree blobs UNDER /usr/lib/firmware
# (<kver>/device-tree/...): re-include the allwinner subtree, the Zero3 DTB
# is boot-critical. Every other vendor stays excluded.
path-include=/usr/lib/firmware/*/device-tree
path-include=/usr/lib/firmware/*/device-tree/allwinner
path-include=/usr/lib/firmware/*/device-tree/allwinner/*
DPKGMIN
echo "--- /etc/dpkg/dpkg.cfg.d/01-opizero3-minimal (firmware path-exclude) in place ---"

# Written before the kernel install so dpkg treats it as a local conffile and
# the generated initramfs includes the sunxi_mmc host driver.
mkdir -p "$ROOTFS/etc/initramfs-tools"
if ! grep -qx 'sunxi_mmc' "$ROOTFS/etc/initramfs-tools/modules" 2>/dev/null; then
  printf 'sunxi_mmc\n' >> "$ROOTFS/etc/initramfs-tools/modules"
fi
echo "--- /etc/initramfs-tools/modules ---"
cat "$ROOTFS/etc/initramfs-tools/modules"

# initramfs-tools (0.151 in 26.04) creates no device nodes and the kernel no
# longer ships /dev/console in its default cpio: without these nodes PID 1
# loses its three standard fds and the initramfs stays silent. The hook runs
# for every initramfs, including ones regenerated on the board.
mkdir -p "$ROOTFS/etc/initramfs-tools/hooks"
cat > "$ROOTFS/etc/initramfs-tools/hooks/zz-devnodes" <<'HOOK'
#!/bin/sh
# The kernel no longer ships /dev/console in its default cpio; the initramfs
# must carry its own device nodes.
PREREQS=""
prereqs() { echo "$PREREQS"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions
mkdir -p "$DESTDIR/dev"
[ -e "$DESTDIR/dev/console" ] || mknod -m 600 "$DESTDIR/dev/console" c 5 1
[ -e "$DESTDIR/dev/null" ]    || mknod -m 666 "$DESTDIR/dev/null"    c 1 3
[ -e "$DESTDIR/dev/tty" ]     || mknod -m 600 "$DESTDIR/dev/tty"     c 5 0
HOOK
chmod 755 "$ROOTFS/etc/initramfs-tools/hooks/zz-devnodes"
echo "--- /etc/initramfs-tools/hooks/zz-devnodes (device node hook) in place ---"

# Persistent journald storage: the mere existence of /var/log/journal makes
# journald persistent.
mkdir -p "$ROOTFS/var/log/journal"

printf '%s\n' "$CARD_HOSTNAME" > "$ROOTFS/etc/hostname"
if ! grep -q '127.0.1.1' "$ROOTFS/etc/hosts"; then
  printf '127.0.1.1\t%s\n' "$CARD_HOSTNAME" >> "$ROOTFS/etc/hosts"
fi

# Wired network via NetworkManager (manual 3.7: the vendor server image runs
# NM and its nmtui/nmcli workflows are the documented way to manage a
# connection), plus SSH for headless access; the wants links are created
# manually (see header note on absolute targets). systemd-networkd is not
# enabled -- NM manages the NIC, and resolved keeps consuming DNS (NM feeds
# the stub listener natively), so firstrun-provided DNS is still consumed.
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants" \
         "$ROOTFS/etc/NetworkManager/system-connections"
ln -sf /lib/systemd/system/NetworkManager.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
# Default wired DHCP profile: guarantees first-boot DHCP even under a distro
# no-auto-default policy for unprofiled devices, and gives nmtui/nmcli a
# visible connection to edit (manual 3.7 UX). The firstrun static path
# replaces this file when FR_net_use_static=1.
cat > "$ROOTFS/etc/NetworkManager/system-connections/end0-default.nmconnection" <<'NMDEF'
[connection]
id=end0-default
type=ethernet
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
NMDEF
chmod 600 "$ROOTFS/etc/NetworkManager/system-connections/end0-default.nmconnection"
# Debian's NM default (/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf)
# leaves ethernet strictly unmanaged on a netplan-less ubuntu-base; the same-name
# /etc drop-in loads after /usr/lib and wins: manage everything.
mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
cat > "$ROOTFS/etc/NetworkManager/conf.d/10-globally-managed-devices.conf" <<'NMGM'
[keyfile]
unmanaged-devices=none
NMGM
# The package's own enable step is unreliable inside the chroot
# (deb-systemd-helper state), so ssh.service is linked manually as well.
ln -sf /lib/systemd/system/ssh.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service"
# Same for systemd-resolved: the unit file arrives with the package (dangling
# until the apt install, same pattern as ssh), the link makes it the DNS
# consumer for NetworkManager's DHCP-provided and firstrun DNS= servers.
ln -sf /lib/systemd/system/systemd-resolved.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"
# Docker (manual 3.24): preinstalled but DISABLED, exactly like the official
# image -- dockerd + containerd cost RAM and boot time on a 4 GB TF-card
# board, and not every card runs containers. The official image's entry
# point ships too: enable_docker.sh flips the stack on, orangepi is already
# in the docker group at build time.
cat > "$ROOTFS/usr/local/bin/enable_docker.sh" <<'DOK'
#!/bin/sh
# Enable the preinstalled Docker stack (official enable_docker.sh equivalent).
sudo systemctl enable --now docker.service docker.socket containerd.service
DOK
chmod 755 "$ROOTFS/usr/local/bin/enable_docker.sh"
# Manual 3.21 watchdog + 3.18 SPI + 3.13 IR: sunxi_wdt is compatible-matched
# by the DTB but is not auto-loaded on the board; spidev/sunxi_ir_rx bind via
# the DTB patches below. Load all three deterministically at boot.
mkdir -p "$ROOTFS/etc/modules-load.d"
cat > "$ROOTFS/etc/modules-load.d/opizero3-hw.conf" <<'MOD'
sunxi_wdt
spidev
sunxi_ir_rx
MOD

# Zram swap, aligned with the official orangepi-zram-config values: 50% of
# RAM, lzo-rle (the official lzo default resolves to lzo-rle on modern
# kernels), swap priority 5, page-cluster=0 for flash/zram, zswap off. The
# official image also runs a compressed /var/log on a zram device; this image
# mounts /var/log as a plain tmpfs instead (see the fstab entry and the
# opizero3-varlog-journal service below).
ln -sf /lib/systemd/system/zramswap.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/zramswap.service"
cat > "$ROOTFS/etc/default/zramswap" <<'ZRAM'
# Aligned with the official orangepi-zram-config defaults: 50% of RAM as
# zram swap, lzo-rle (the official script picks lzo and falls back to
# lzo-rle), swap priority 5.
ALGO=lzo-rle
PERCENT=50
PRIORITY=5
ZRAM
cat > "$ROOTFS/etc/sysctl.d/90-opizero3-zram.conf" <<'SYSCTL'
# Zram swap tuning, official orangepi-zram-config alignment: no readahead
# batching for swap-in (flash + zram).
vm.page-cluster = 0
SYSCTL
cat > "$ROOTFS/usr/lib/tmpfiles.d/opizero3-zswap.conf" <<'ZSWAP'
# The official config disables zswap so it does not fight zram.
w /sys/module/zswap/parameters/enabled - - - - 0
ZSWAP
mkdir -p "$ROOTFS/etc/systemd/journald.conf.d"
cat > "$ROOTFS/etc/systemd/journald.conf.d/opizero3.conf" <<'JCONF'
[Journal]
# Official alignment: the vendor zram setup caps the journal at 20M; /var/log
# is a 100M tmpfs here, keep the same headroom logic.
SystemMaxUse=20M
JCONF
mkdir -p "$ROOTFS/etc/systemd/system/sysinit.target.wants"
cat > "$ROOTFS/etc/systemd/system/opizero3-varlog-journal.service" <<'VLOG'
[Unit]
Description=opizero3: recreate /var/log/journal on the tmpfs /var/log
DefaultDependencies=no
After=local-fs.target
Before=systemd-journald.service

[Service]
Type=oneshot
ExecStart=/usr/bin/mkdir -p /var/log/journal
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
VLOG
ln -sf /etc/systemd/system/opizero3-varlog-journal.service \
  "$ROOTFS/etc/systemd/system/sysinit.target.wants/opizero3-varlog-journal.service"

mkdir -p "$ROOTFS/etc/default"
if command -v uuidgen >/dev/null 2>&1; then
  ROOT_UUID=$(uuidgen)
else
  # uuidgen lives in the separate uuid-runtime package, absent from this
  # container; the kernel file is an equally valid v4 source.
  ROOT_UUID=$(cat /proc/sys/kernel/random/uuid)
fi
echo ">> ROOT_UUID=$ROOT_UUID (shared by /etc/default/grub, mkfs.ext4 -U and the ESP stub cfg)"
cat > "$ROOTFS/etc/default/grub" <<'GRUBDEF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200 rootwait"
GRUB_DISABLE_OS_PROBER=true
GRUBDEF
# The three overrides must live in the file (grub-probe fact in the header).
# GRUB_FS=ext2 is grub's module name for ext4; a later update-grub on the
# board regenerates the config against /dev/mmcblk0p2 and this same UUID.
{
  printf 'GRUB_DEVICE=/dev/mmcblk0p2\n'
  printf 'GRUB_DEVICE_UUID=%s\n' "$ROOT_UUID"
  printf 'GRUB_FS=ext2\n'
} >> "$ROOTFS/etc/default/grub"
echo "--- /etc/default/grub ---"
cat "$ROOTFS/etc/default/grub"
cat > "$ROOTFS/etc/fstab" <<'FSTAB'
/dev/mmcblk0p2  /          ext4   defaults,noatime    0 1
/dev/mmcblk0p1  /boot/efi  vfat   defaults,umask=0077 0 2
tmpfs           /var/log   tmpfs  defaults,nosuid,mode=0755,size=100M 0 0
FSTAB
echo "--- /etc/fstab (dual partition + /var/log tmpfs) ---"
cat "$ROOTFS/etc/fstab"

# First-boot root filesystem growth, same pattern as the official
# orangepi-resize-filesystem: growpart enlarges p2, online resize2fs extends
# it, then the unit disables itself; both steps tolerate failure.
mkdir -p "$ROOTFS/usr/local/sbin"
cat > "$ROOTFS/usr/local/sbin/opizero3-resize" <<'RSZ'
#!/bin/sh
# growpart enlarges p2 -> online resize2fs -> disable this unit.
ROOTPART=/dev/mmcblk0p2
growpart /dev/mmcblk0 2 || true          # NOCHANGE exits 1, harmless
resize2fs "$ROOTPART" || true
systemctl disable opizero3-resize.service
RSZ
chmod 755 "$ROOTFS/usr/local/sbin/opizero3-resize"
cat > "$ROOTFS/etc/systemd/system/opizero3-resize.service" <<'RSVC'
[Unit]
Description=opizero3 first-boot root filesystem grow (growpart + resize2fs)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/opizero3-resize
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
RSVC
ln -sf /etc/systemd/system/opizero3-resize.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/opizero3-resize.service"
echo "--- opizero3-resize.service + script in place ---"

# LED alignment with the official image (green status heartbeat + red power
# off): the mainline DT has no green LED and leaves red:power lit, so the DTB
# is patched in the boot finalization step and this service reasserts trigger
# and brightness at runtime. A udev rule cannot do this: ledtrig-heartbeat is
# a module, the LEDs coldplug before modules load, and writing the trigger
# then fails with EINVAL; the service modprobes first and only then writes.
# Self-heal: a kernel upgrade ships a fresh unpatched DTB, so the service
# re-applies the fdtput patch in place; effective after reboot.
cat > "$ROOTFS/usr/local/sbin/opizero3-greenled" <<'GLED'
#!/bin/sh
# Green status LED heartbeat + red power LED off, spi0 spidev, IR receiver
# enable. Survives any kernel/DTB change.
modprobe ledtrig-heartbeat 2>/dev/null || true

for d in /sys/class/leds/*status; do
  [ -d "$d" ] || continue
  echo heartbeat > "$d/trigger" 2>/dev/null || true
done

# Red LED off (official behavior: it goes dark once the kernel is up).
for d in /sys/class/leds/*:power; do
  [ -d "$d" ] || continue
  echo none > "$d/trigger" 2>/dev/null || true
  echo 0 > "$d/brightness" 2>/dev/null || true
done

# Self-heal: no *status LED means the running kernel's DTB is unpatched
# (e.g. after an HWE upgrade). Re-apply in place (idempotent), effective
# after reboot; the service never reboots the board itself.
# Requires fdtput (device-tree-compiler).
if ! ls /sys/class/leds/*status >/dev/null 2>&1; then
  command -v fdtput >/dev/null 2>&1 || exit 0
  for dtb in /usr/lib/firmware/*/device-tree/allwinner/sun50i-h618-orangepi-zero3.dtb; do
    [ -f "$dtb" ] || continue
    PH=$(fdtget "$dtb" /leds/led-0 gpios 2>/dev/null | awk '{print $1}')
    [ -n "$PH" ] || continue
    fdtput -c "$dtb" /leds/led-1 2>/dev/null || true
    fdtput -t s "$dtb" /leds/led-1 function status
    fdtput -t u "$dtb" /leds/led-1 color 2
    fdtput -t u "$dtb" /leds/led-1 gpios "$PH" 2 13 0
    fdtput -t s "$dtb" /leds/led-1 linux,default-trigger heartbeat
    fdtput -t s "$dtb" /leds/led-0 default-state off
    fdtput -c "$dtb" /soc/spi@5010000/spidev@0 2>/dev/null || true
    fdtput -t s "$dtb" /soc/spi@5010000/spidev@0 compatible rohm,dh2228fv
    fdtput -t u "$dtb" /soc/spi@5010000/spidev@0 reg 0
    fdtput -t u "$dtb" /soc/spi@5010000/spidev@0 spi-max-frequency 1000000
    fdtput -t s "$dtb" /soc/spi@5010000/flash@0 status disabled 2>/dev/null || true
    fdtput -t s "$dtb" /soc/ir@7040000 status okay
    logger -t opizero3-greenled "hw DTB patch (led/spi0/flash-off/ir) reapplied: $dtb (effective after reboot)"
  done
  # Refresh the /boot/dtb fallback copy from the newest kernel's DTB so a
  # regenerated grub.cfg keeps its devicetree line.
  D_GLOB="/usr/lib/firmware/*/device-tree/allwinner/sun50i-h618-orangepi-zero3.dtb"
  NEWEST=$(ls -v $D_GLOB 2>/dev/null | tail -1)
  [ -n "$NEWEST" ] && cp -f "$NEWEST" /boot/dtb 2>/dev/null
  grep -q devicetree /boot/grub/grub.cfg 2>/dev/null || \
    logger -t opizero3-greenled "warning: grub.cfg has no devicetree line"
fi
exit 0
GLED
chmod 755 "$ROOTFS/usr/local/sbin/opizero3-greenled"
cat > "$ROOTFS/etc/systemd/system/opizero3-greenled.service" <<'GSVC'
[Unit]
Description=opizero3 DTB alignment: LED triggers + spi0 spidev + IR enable (with self-heal)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/opizero3-greenled
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
GSVC
ln -sf /etc/systemd/system/opizero3-greenled.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/opizero3-greenled.service"
echo "--- opizero3-greenled service (LED alignment + DTB self-heal) in place ---"

# ---- first-run services (official orangepi-firstrun / -firstrun-config alignment) ----
# opizero3-firstrun (Before=ssh.service): the build-time SSH host keys and
# machine-id are identical on every flashed card; regenerate both on the
# first boot, then self-disable. sshd never starts on the baked-in keys.
# opizero3-firstrun-config: consumes /boot/efi/orangepi_first_run.txt (the
# ESP, editable from Windows) or /boot/orangepi_first_run.txt (official path,
# on ext4), applies static-IP overrides as a NetworkManager keyfile that
# replaces the shipped default DHCP profile, wipes the file (urandom, credentials
# must not linger) and the sentinel, mirroring the official semantics: the
# /root/.not_logged_in_yet sentinel exists only before the first login.
cat > "$ROOTFS/usr/local/sbin/opizero3-firstrun" <<'FRUN'
#!/bin/sh
# First-boot identity reset, then this unit disables itself.
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A >/dev/null 2>&1
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup >/dev/null 2>&1
ln -sf /etc/machine-id /var/lib/dbus/machine-id
systemctl disable opizero3-firstrun.service
exit 0
FRUN
chmod 755 "$ROOTFS/usr/local/sbin/opizero3-firstrun"
cat > "$ROOTFS/etc/systemd/system/opizero3-firstrun.service" <<'FSVC'
[Unit]
Description=opizero3 first-run: regenerate SSH host keys and machine-id
Before=ssh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/opizero3-firstrun

[Install]
WantedBy=multi-user.target
FSVC
ln -sf /etc/systemd/system/opizero3-firstrun.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/opizero3-firstrun.service"
cat > "$ROOTFS/usr/local/sbin/opizero3-firstrun-config" <<'FCFG'
#!/bin/sh
# First-run optional configuration consumer (official orangepi_first_run.txt
# template format). Config locations, first hit wins:
#   /boot/efi/orangepi_first_run.txt   the ESP (FAT32, editable from Windows)
#   /boot/orangepi_first_run.txt       official path, on the ext4 root
CFG=""
for f in /boot/efi/orangepi_first_run.txt /boot/orangepi_first_run.txt; do
    [ -f "$f" ] && CFG="$f" && break
done
[ -n "$CFG" ] || exit 0
# Official gate: the sentinel exists only before the first login; a board
# someone has already logged into keeps full control.
[ -e /root/.not_logged_in_yet ] || exit 0

# A config authored on Windows carries CRLF line endings; normalize and
# syntax-check before sourcing (the file is executed as shell).
sed -i 's/\r$//' "$CFG"
if ! sh -n "$CFG"; then
    logger -t opizero3-firstrun-config "$CFG failed sh -n, ignored"
    exit 0
fi
. "$CFG"

if [ "${FR_net_change_defaults:-0}" = "1" ]; then
    if [ "${FR_net_wifi_enabled:-0}" = "1" ]; then
        logger -t opizero3-firstrun-config "FR_net_wifi_enabled=1 ignored: onboard UWE5622 has no mainline driver"
    fi
    IFACE=""
    for b in $(ls /sys/class/net 2>/dev/null); do
        [ "$b" = "lo" ] && continue
        case "$b" in
            eth*|en*) IFACE="$b"; break ;;
        esac
    done
    if [ -n "$IFACE" ] && [ "${FR_net_use_static:-0}" = "1" ]; then
        mask2cidr() {
            _n=0
            for _dec in $(echo "$1" | tr '.' ' '); do
                case $_dec in
                    255) _n=$((_n+8)) ;; 254) _n=$((_n+7)) ;; 252) _n=$((_n+6)) ;;
                    248) _n=$((_n+5)) ;; 240) _n=$((_n+4)) ;; 224) _n=$((_n+3)) ;;
                    192) _n=$((_n+2)) ;; 128) _n=$((_n+1)) ;;
                esac
            done
            echo "$_n"
        }
        {
            printf '[connection]\n'
            printf 'id=opizero3-firstrun\n'
            printf 'type=ethernet\n'
            printf 'interface-name=%s\n' "$IFACE"
            printf 'autoconnect=true\n'
            printf '\n[ipv4]\n'
            printf 'method=manual\n'
            printf 'address1=%s/%s,%s\n' "$FR_net_static_ip" "$(mask2cidr "${FR_net_static_mask:-255.255.255.0}")" "$FR_net_static_gateway"
            printf 'dns=%s;\n' "$(echo "$FR_net_static_dns" | tr ' ' ';')"
            printf '\n[ipv6]\n'
            printf 'method=auto\n'
        } > /etc/NetworkManager/system-connections/opizero3-firstrun.nmconnection
        chmod 600 /etc/NetworkManager/system-connections/opizero3-firstrun.nmconnection
        # Two autoconnect profiles on one NIC would race; the static profile
        # replaces the shipped default DHCP one.
        rm -f /etc/NetworkManager/system-connections/end0-default.nmconnection
        nmcli con reload 2>/dev/null || true
        logger -t opizero3-firstrun-config "static IP applied on $IFACE via NetworkManager keyfile"
    fi
fi

# Consume the file (urandom overwrite first, so credentials do not linger in
# unallocated blocks) and drop the sentinel.
if [ "${FR_general_delete_this_file_after_completion:-1}" = "1" ]; then
    dd if=/dev/urandom of="$CFG" bs=16K count=1 2>/dev/null
    sync
    rm -f "$CFG"
else
    mv -f "$CFG" "$CFG.old"
fi
rm -f /root/.not_logged_in_yet
exit 0
FCFG
chmod 755 "$ROOTFS/usr/local/sbin/opizero3-firstrun-config"
cat > "$ROOTFS/etc/systemd/system/opizero3-firstrun-config.service" <<'FCSVC'
[Unit]
Description=opizero3 first-run optional configuration (orangepi_first_run.txt)
Wants=network-online.target
After=NetworkManager.service network-online.target
ConditionPathExists=/root/.not_logged_in_yet

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/opizero3-firstrun-config

[Install]
WantedBy=multi-user.target
FCSVC
ln -sf /etc/systemd/system/opizero3-firstrun-config.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/opizero3-firstrun-config.service"
# Template ships in both locations (the ESP copy is dd'd in during assembly).
cat > "$ROOTFS/boot/orangepi_first_run.txt.template" <<'FRST'
#-----------------------------------------------------------------
# OrangePi Zero3 first run configuration (official template format)
#   - Rename this file to orangepi_first_run.txt and place it either on the
#     ESP (root of the FAT32 partition, editable from Windows) or in /boot
#     (ext4, the official path). Applied on the first boot only, before the
#     first login.
#   - The onboard WiFi (UWE5622) has no mainline driver in this image: the
#     FR_net_wifi_* entries are kept for template compatibility but are
#     ignored, and a warning is logged.
#-----------------------------------------------------------------

# 1 = wipe this file after first-run setup completes (default); 0 = keep as .old
FR_general_delete_this_file_after_completion=1

# Networking:
# Set to 1 to apply any network related settings below
FR_net_change_defaults=0

# Ethernet is the only working medium in this image.
# NB: the official image lets WiFi take priority; here WiFi is always ignored.
FR_net_ethernet_enabled=1
FR_net_wifi_enabled=0

# WiFi credentials (ignored on this image, see above)
FR_net_wifi_ssid='MySSID'
FR_net_wifi_key='MyWiFiKEY'
FR_net_wifi_countrycode='GB'

# Static IP settings (used when FR_net_use_static=1; DHCP is the default)
FR_net_use_static=0
FR_net_static_ip='192.168.0.100'
FR_net_static_mask='255.255.255.0'
FR_net_static_gateway='192.168.0.1'
FR_net_static_dns='8.8.8.8 8.8.4.4' # 2 entries max, separated by a space
FRST
mkdir -p "$ROOTFS/boot/efi"
cp -f "$ROOTFS/boot/orangepi_first_run.txt.template" \
  "$ROOTFS/boot/efi/orangepi_first_run.txt.template"
# The gate sentinel: consumed by opizero3-firstrun-config on its first run.
: > "$ROOTFS/root/.not_logged_in_yet"
echo "--- firstrun pair (identity reset + first_run config consumer) + template + sentinel in place ---"

# The Zero3 has no battery-backed RTC: at power-on the clock starts near the
# kernel build date and apt Release validation fails ("not valid yet") until
# a NTP client sets it. systemd-timesyncd ships with the base package set;
# NTP_SERVERS overrides its servers, otherwise the distro defaults apply.
mkdir -p "$ROOTFS/etc/systemd/timesyncd.conf.d"
if [ -n "$NTP_SERVERS" ]; then
  printf '[Time]\nNTP=%s\nFallbackNTP=ntp.ubuntu.com\n' "$NTP_SERVERS" \
    > "$ROOTFS/etc/systemd/timesyncd.conf.d/90-custom.conf"
  echo "--- timesyncd drop-in (90-custom.conf) written ---"
fi

# Manual 3.21 alignment: the vendor image ships a watchdog_test binary; this
# shell equivalent opens the hardware watchdog, arms the timeout and feeds it
# on every keypress -- stop feeding (or Ctrl+C) and the board reboots, the
# same contract as the vendor tool.
cat > "$ROOTFS/usr/local/sbin/watchdog_test" <<'WDT'
#!/bin/bash
# watchdog_test [seconds]: arm the hardware watchdog and feed it on every
# keypress. Stop feeding (Ctrl+C closes the fd without the magic 'V') and
# the board reboots -- the vendor tool's exact behavior.
T=${1:-10}
[ -c /dev/watchdog0 ] || { echo "no /dev/watchdog0 -- try: sudo modprobe sunxi_wdt"; exit 1; }
[ -t 0 ] || { echo "run interactively: the dog must be fed from a terminal"; exit 1; }
echo "identity: $(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null || echo unknown)"
echo "arming timeout: ${T}s"
echo "$T" > /sys/class/watchdog/watchdog0/timeout 2>/dev/null || echo "warning: could not set timeout via sysfs (using driver default)"
exec 3>/dev/watchdog0 || { echo "cannot open /dev/watchdog0"; exit 1; }
echo "armed -- press any key to feed; stop feeding and the board reboots in ~${T}s"
while IFS= read -r -n1 -s; do
    printf 'keep alive\n'
    printf 'x' >&3
done
echo "input ended: no more feeding, the board will reboot shortly"
WDT
chmod 755 "$ROOTFS/usr/local/sbin/watchdog_test"

# Official-style login MOTD: the orangepi-bsp-cli script pair (10-header +
# 30-sysinfo, Armbian-derived, GPL-2.0, vendored from official 1.0.8),
# executed by pam_motd from /etc/update-motd.d at every login. Built 755 so
# the banner shows from the first login. VERSION is not pinned in
# /etc/orangepi-release: the header derives the OS release from
# /etc/os-release at login time (base-files refreshes it on every point
# release), so `apt upgrade` flows through to the welcome line.
cat > "$ROOTFS/etc/update-motd.d/10-orangepi-header" <<'OPIMOTDHEADER'
#!/bin/bash
#
# Copyright (c) Authors: https://www.armbian.com/authors
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.

# DO NOT EDIT THIS FILE but add config options to /etc/default/orangepi-motd
# any changes will be lost on board support package update

THIS_SCRIPT="header"
MOTD_DISABLE=""

[[ -f /etc/default/orangepi-motd ]] && . /etc/default/orangepi-motd

for f in $MOTD_DISABLE; do
	[[ $f == $THIS_SCRIPT ]] && exit 0
done

. /etc/os-release
. /etc/orangepi-release

# opizero3-ubuntu: OS release parsed from /etc/os-release at login time
# instead of the upstream build number, so apt point-release upgrades show
# through ("26.04.1" out of "26.04.1 LTS (Resolute Raccoon)").
UB_RELEASE=${VERSION%% *}

KERNELID=$(uname -r)
TERM=linux toilet -f standard -F metal $(echo $BOARD_NAME | sed 's/Orange Pi/OPi/')
echo -e "Welcome to \e[0;91mOrange Pi ${UB_RELEASE} ${DISTRIBUTION_CODENAME^}\x1B[0m with $([[ $BRANCH == edge ]] && echo -e "\e[0;91mbleeding\x1B[0m edge " )\e[0;91mLinux $KERNELID\x1B[0m\n"
OPIMOTDHEADER
cat > "$ROOTFS/etc/update-motd.d/30-orangepi-sysinfo" <<'OPIMOTDSYSINFO'
#!/bin/bash
#
# Copyright (c) Authors: https://www.armbian.com/authors
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#

# DO NOT EDIT THIS FILE but add config options to /etc/default/orangepi-motd
# generate system information

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
THIS_SCRIPT="sysinfo"

# don't change default values - they are lost on upgrades. Use /etc/default/orangepi-motd for your values

MOTD_DISABLE=""
PRIMARY_INTERFACE="eth0"
PRIMARY_DIRECTION="rx"
STORAGE=/dev/sda1
HIDE_IP_PATTERN="^dummy0|^lo"
CPU_TEMP_LIMIT=60
# Temperature offset in Celcius degrees
CPU_TEMP_OFFSET=0
HDD_TEMP_LIMIT=60
AMB_TEMP_LIMIT=40

[[ -f /etc/default/orangepi-motd ]] && . /etc/default/orangepi-motd

for f in $MOTD_DISABLE; do
	[[ $f == $THIS_SCRIPT ]] && exit 0
done

# don't edit below here

function display() {
	# $1=name $2=value $3=red_limit $4=minimal_show_limit $5=unit $6=after $7=acs/desc{
	# battery red color is opposite, lower number
	if [[ "$1" == "Battery" ]]; then local great="<"; else local great=">"; fi
	if [[ -n "$2" && "$2" > "0" && (( "${2%.*}" -ge "$4" )) ]]; then
		printf "%-14s" "$1:"
		if awk "BEGIN{exit ! ($2 $great $3)}"; then echo -ne "\e[0;91m $2"; else echo -ne "\e[0;92m $2"; fi
		printf "%-1s\x1B[0m" "$5"
		printf "%-11s\t" "$6"
		return 1
	fi
} # display

function getboardtemp() {
	if [ -f /etc/orangepimonitor/datasources/soctemp ]; then
		read raw_temp </etc/orangepimonitor/datasources/soctemp 2>/dev/null
		if [ ! -z $(echo "$raw_temp" | grep -o "^[1-9][0-9]*\.\?[0-9]*$") ] && (( $(echo "${raw_temp} < 200" |bc -l) )); then
			# Allwinner legacy kernels output degree C
			board_temp=${raw_temp}
		else
			board_temp=$(awk '{printf("%d",$1/1000)}' <<<${raw_temp})
		fi
	elif [ -f /etc/orangepimonitor/datasources/pmictemp ]; then
		# fallback to PMIC temperature
		board_temp=$(awk '{printf("%d",$1/1000)}' </etc/orangepimonitor/datasources/pmictemp)
	fi
	# Some boards, such as the Orange Pi Zero LTS, report shifted CPU temperatures
	board_temp=$((board_temp + CPU_TEMP_OFFSET))
} # getboardtemp

function batteryinfo() {
	# Battery info for Allwinner
	mainline_dir="/sys/power/axp_pmu"
	legacy_dir="/sys/class/power_supply"
	if [[ -e "$mainline_dir" ]]; then
		read status_battery_connected < $mainline_dir/battery/connected 2>/dev/null
		if [[ "$status_battery_connected" == "1" ]]; then
			read status_battery_charging < $mainline_dir/charger/charging
			read status_ac_connect < $mainline_dir/ac/connected
			read battery_percent< $mainline_dir/battery/capacity
			# dispay charging / percentage
			if [[ "$status_ac_connect" == "1" && "$battery_percent" -lt "100" ]]; then
				status_battery_text=" charging"
			elif [[ "$status_ac_connect" == "1" && "$battery_percent" -eq "100" ]]; then
				status_battery_text=" charged"
			else
				status_battery_text=" discharging"
			fi
		fi
	elif [[ -e "$legacy_dir/axp813-ac" ]]; then
		read status_battery_connected < $legacy_dir/axp20x-battery/present
		if [[ "$status_battery_connected" == "1" ]]; then
			status_battery_text=" "$(awk '{print tolower($0)}' < $legacy_dir/axp20x-battery/status)
			read status_ac_connect < $legacy_dir/axp813-ac/present
			read battery_percent< $legacy_dir/axp20x-battery/capacity
		fi
	elif [[ -e "$legacy_dir/battery" ]]; then
		if [[ (("$(cat $legacy_dir/battery/voltage_now)" -gt "5" )) ]]; then
			status_battery_text=" "$(awk '{print tolower($0)}' < $legacy_dir/battery/status)
			read battery_percent <$legacy_dir/battery/capacity
		fi
	fi
} # batteryinfo

function ambienttemp() {
	# define where w1 usually shows up
        W1_DIR="/sys/devices/w1_bus_master1/"
	if [ -f /etc/orangepimonitor/datasources/ambienttemp ]; then
		read raw_temp </etc/orangepimonitor/datasources/ambienttemp 2>/dev/null
		amb_temp=$(awk '{printf("%d",$1/1000)}' <<<${raw_temp})
		echo $amb_temp
	elif [[ -d $W1_DIR && $ONE_WIRE == yes ]]; then
		device=$(ls -1 $W1_DIR | grep -E '^[0-9]{1,4}' | head -1)
		if [[ -n $device ]]; then
			read raw_temp < ${W1_DIR}${device}/hwmon/$(ls -1 ${W1_DIR}${device}/hwmon)/temp1_input 2>/dev/null
			amb_temp=$(awk '{printf("%d",$1/1000)}' <<<${raw_temp})
			echo $amb_temp
		fi
	else
		# read ambient temperature from USB device if available
		if [[ ! -f /usr/bin/temper ]]; then
			echo ""
			return
		fi
		amb_temp=$(temper -c 2>/dev/null)
		case ${amb_temp} in
			*"find the USB device"*)
				echo ""
				;;
			*)
				amb_temp=$(awk '{print $NF}' <<<$amb_temp |  sed 's/C//g')
				echo -n "scale=1;${amb_temp}/1" | grep -oE "\-?[[:digit:]]+\.[[:digit:]]"
		esac
	fi
} # ambienttemp

function get_ip_addresses() {
	local ips=()
	for f in /sys/class/net/*; do
		local intf=$(basename $f)
		# match only interface names "dummy0" and "lo"
		if [[ $intf =~ $HIDE_IP_PATTERN ]]; then
			continue
		else
			local tmp=$(ip -4 addr show dev $intf | grep -v "$intf:avahi" | awk '/inet/ {print $2}' | cut -d'/' -f1 | head -n 1)

			# add both name and IP - can be informative but becomes ugly with long persistent/predictable device names
			#[[ -n $tmp ]] && ips+=("$intf: $tmp")
			# add IP only
			[[ -n $tmp ]] && ips+=("$tmp")
		fi
	done
	echo "${ips[@]}"
} # get_ip_addresses

function storage_info() {
	# storage info
	RootInfo=$(df -h /)
	root_usage=$(awk '/\// {print $(NF-1)}' <<<${RootInfo} | sed 's/%//g')
	root_total=$(awk '/\// {print $(NF-4)}' <<<${RootInfo})
	StorageInfo=$(df -h $STORAGE 2>/dev/null | grep $STORAGE)
	if [[ -n "${StorageInfo}" && ${RootInfo} != *$STORAGE* ]]; then
		storage_usage=$(awk '/\// {print $(NF-1)}' <<<${StorageInfo} | sed 's/%//g')
		storage_total=$(awk '/\// {print $(NF-4)}' <<<${StorageInfo})
		if [[ -n "$(command -v smartctl)" ]]; then
			DISK="${STORAGE::-1}"
			storage_temp+=$(smartctl -l scttempsts $DISK 2> /dev/null | grep -i 'Current Temperature:' | awk '{print $(NF-1)}')
		fi
	fi
} # storage_info



# query various systems and send some stuff to the background for overall faster execution.
# Works only with ambienttemp and batteryinfo since A20 is slow enough :)
amb_temp=$(ambienttemp &)
ip_address=$(get_ip_addresses &)
batteryinfo
storage_info
getboardtemp
critical_load=80

# get uptime, logged in users and load in one take
UPTIME=$(LC_ALL=C uptime)
UPT1=${UPTIME#*'up '}
UPT2=${UPT1%'user'*}
users=${UPT2//*','}
users=${users//' '}
time=${UPT2%','*}
time=${time//','}
time=$(echo $time | xargs)
load=${UPTIME#*'load average: '}
load=${load//','}
load=$(echo $load | cut -d" " -f1)
[[ $load == 0.0* ]] && load=0.10
cpucount=$(grep -c processor /proc/cpuinfo)

load=$(awk '{printf("%.0f",($1/$2) * 100)}' <<< "$load $cpucount")

# memory and swap
mem_info=$(LC_ALL=C free -w 2>/dev/null | grep "^Mem" || LC_ALL=C free | grep "^Mem")
memory_usage=$(awk '{printf("%.0f",(($2-($4+$6+$7))/$2) * 100)}' <<<${mem_info})
mem_info=$(echo $mem_info | awk '{print $2}')
memory_total=$(( mem_info / 1024 ))
swap_info=$(LC_ALL=C free -m | grep "^Swap")
swap_usage=$( (awk '/Swap/ { printf("%3.0f", $3/$2*100) }' <<<${swap_info} 2>/dev/null || echo 0) | tr -c -d '[:digit:]')
swap_total=$(awk '{print $(2)}' <<<${swap_info})

# display info
display "System load" "${load%% *}" "${critical_load}" "0" "%" ""

printf "Up time:       \x1B[92m%s\x1B[0m\t" "$time"
display "Local users" "${users##* }" "3" "2" ""
echo "" # fixed newline
if [[ ${memory_total} -gt 1000 ]]; then
	memory_total=$(awk '{printf("%.2f",$1/1024)}' <<<${memory_total})"G"
else
	memory_total+="M"
fi

if [[ ${swap_total} -gt 500 ]]; then
	swap_total=$(awk '{printf("%.2f",$1/1024)}' <<<${swap_total})"G"
else
	swap_total+="M"
fi

display "Memory usage" "$memory_usage" "70" "0" "%" " of ${memory_total}"
display "Zram usage" "$swap_usage" "75" "0" "%" " of ${swap_total}"
printf "IP:	       "
printf "\x1B[92m%s\x1B[0m" "$ip_address"
echo "" # fixed newline
display "CPU temp" "$board_temp" $CPU_TEMP_LIMIT "0" "°C" ""
display "Ambient temp" "$amb_temp" $AMB_TEMP_LIMIT "0" "°C" ""
display "Usage of /" "$root_usage" "90" "1" "%" " of $root_total"
echo "" # fixed newline
a=0
display "storage/" "$storage_usage" "90" "1" "%" " of $storage_total" ; a=$((a+$?))
display "storage temp" "$storage_temp" $HDD_TEMP_LIMIT "0" "°C" "" ; a=$((a+$?))
display "Battery" "$battery_percent" "20" "1" "%" "$status_battery_text" ; a=$((a+$?))
(( $a > 0 )) && echo "" # new line only if some value is displayed

# Check whether PRIMARY_INTERFACE exist in /var/lib/vnstat/
PRIMARY_INTERFACE=$(comm -12 <(ls -1 /var/lib/vnstat/ 2> /dev/null) <(echo "$PRIMARY_INTERFACE" | sed 's/+/\n/g') | sed -n -e 'H;${x;s/\n/+/g;s/^+//;p;}')

line=0
if [[ $(command -v vnstat) && -n $PRIMARY_INTERFACE ]]; then
	traffic=$(vnstat -i $PRIMARY_INTERFACE --oneline | cut -d";" -f4,5)
	traffic_rx=$(echo $traffic | cut -d";" -f1,1 | sed -r 's/([0-9]+\.[0-9]{1})[0-9]*/\1/')
	traffic_tx=$(echo $traffic | cut -d";" -f2,2 | sed -r 's/([0-9]+\.[0-9]{1})[0-9]*/\1/')
	[[ "$traffic" == *"Not enough"* ]] && { traffic_tx="n/a	"; traffic_rx="n/a	"; }
	case $PRIMARY_DIRECTION in
		tx)
			printf "TX today:      \x1B[92m%s\x1B[0m  \t"  "$traffic_tx"
			line=$((line+1))
		;;
		rx)
			printf "RX today:      \x1B[92m%s\x1B[0m  \t"  "$traffic_rx"
			line=$((line+1))
		;;
		both)
			printf "TX today:      \x1B[92m%s\x1B[0m  \t"  "$traffic_tx"
			printf "RX today:      \x1B[92m%s\x1B[0m  \t"  "$traffic_rx"
			line=$((line+1))
		;;
		*) #off or whatever
		;;
	esac
fi

if [[ $(command -v zpool) ]]; then
	zpoolstatus="$(zpool status </dev/stdin 2>&1 )"
	if [[ -n $(echo $zpoolstatus | grep 'not loaded') ]]; then
	:
	elif [[ -n $(echo $zpoolstatus | grep 'degraded\|OFFLINE') ]]; then
		printf "ZFS pool:      "
		echo -ne "\e[0;91mDegraded\x1B[0m"
		line=$((line+1))
	elif [[ -n $(echo $zpoolstatus | grep 'no pools available') ]]; then
		printf "ZFS pool:      "
		echo -ne "n/a"
		line=$((line+1))
	else
		printf "ZFS pool:      "
		echo -ne "\e[0;92mOnline\x1B[0m"
		line=$((line+1))
	fi
fi
[[ $line -ne 0 ]] && echo ""
echo ""
OPIMOTDSYSINFO
cat > "$ROOTFS/etc/orangepi-release" <<'OPREL'
# PLEASE DO NOT EDIT THIS FILE
# Board identity for the login MOTD (10-orangepi-header); family labels keep
# the official Zero3 values, the kernel itself is mainline. Sourced after
# /etc/os-release so the welcome line tracks apt point-release upgrades.
BOARD=orangepizero3
BOARD_NAME="OPI Zero3"
BOARDFAMILY=sun50iw9
BUILD_REPOSITORY_URL=https://github.com/CyberXHN/opizero3-ubuntu
LINUXFAMILY=sun50iw9
ARCH=arm64
IMAGE_TYPE=user-built
BOARD_TYPE=conf
INITRD_ARCH=arm64
KERNEL_IMAGE_TYPE=Image
BRANCH=current
# resolved from /etc/os-release at source time
DISTRIBUTION_CODENAME="$VERSION_CODENAME"
OPREL
cat > "$ROOTFS/etc/default/orangepi-motd" <<'OPIDEF'
# add space-separated list of MOTD script names (without number) to exclude them from MOTD
# Example:
# MOTD_DISABLE="header tips updates"
# ONE_WIRE="yes" show 1-wire temperature sensor if attached
# PRIMARY_DIRECTION="rx" show daily traffic stats, options: "rx", "tx", "both", "off", vnstat needs to be installed

MOTD_DISABLE=""
ONE_WIRE=""
HIDE_IP_PATTERN="^dummy0|^lo"
PRIMARY_INTERFACE="$(ls -1 /sys/class/net/ | grep -v lo | egrep "enp|eth" | head -1)"
PRIMARY_DIRECTION="rx"
STORAGE=/dev/sda1

# Temperature offset in Celcius degrees
CPU_TEMP_OFFSET=0

# Define where red color is used
CPU_TEMP_LIMIT=60
HDD_TEMP_LIMIT=60
AMB_TEMP_LIMIT=40
OPIDEF
# Stock Ubuntu MOTD scripts removed: superseded by the official pair
# (50-motd-news phones home at every login).
rm -f "$ROOTFS/etc/update-motd.d/00-header" "$ROOTFS/etc/update-motd.d/10-help-text" \
  "$ROOTFS/etc/update-motd.d/50-motd-news" "$ROOTFS/etc/update-motd.d/60-unminimize"
chmod 755 "$ROOTFS/etc/update-motd.d/10-orangepi-header" "$ROOTFS/etc/update-motd.d/30-orangepi-sysinfo"
# CPU-temperature datasource the sysinfo script reads (thermal_zone0 =
# cpu-thermal on mainline H618; millidegrees, the script divides by 1000).
mkdir -p "$ROOTFS/etc/orangepimonitor/datasources"
ln -sf /sys/devices/virtual/thermal/thermal_zone0/temp \
  "$ROOTFS/etc/orangepimonitor/datasources/soctemp"
# Same link the official bsp postinst creates (the absent target makes
# pam_motd noupdate print nothing).
ln -sf /var/run/motd "$ROOTFS/etc/motd"
echo "--- official-style login MOTD in place (10-orangepi-header + 30-orangepi-sysinfo + orangepi-release + defaults + soctemp) ---"

# ---- 4. chroot apt install ----
phase "chroot apt install (depmod and update-initramfs dominate)"

if [ -n "$APT_SNAPSHOT" ]; then
  # Snapshot freeze: no mirror rewrite, no fallback -- a dead snapshot ID
  # must fail the build loudly; silently unlocking to the live archive would
  # defeat the freeze.
  chroot "$ROOTFS" apt-get update
  # A failed snapshot fetch makes apt ignore the fallback live indexes, so
  # the update can exit 0 with empty lists; fail here with a clear message
  # instead of at the package install with "unable to locate".
  [ -n "$(find "$ROOTFS/var/lib/apt/lists" -name '*Packages*' -print -quit 2>/dev/null)" ] \
    || fail "snapshot apt update produced no package indexes (dead snapshot ID or TLS failure)"
elif [ -n "$APT_MIRROR_PORTS" ]; then
  if ! chroot "$ROOTFS" apt-get update; then
    # The mirror rewrite is the only reason update can fail here; fall back
    # to the official sources and retry once.
    echo ">> apt mirror unreachable, falling back to the official sources"
    sed -i "s|$APT_MIRROR_PORTS|http://ports.ubuntu.com/ubuntu-ports|g" "${SRC_FILES[@]}"
    for f in "${SRC_FILES[@]}"; do
      echo "--- $f (fallback to official sources) ---"
      cat "$f"
    done
    chroot "$ROOTFS" apt-get update
  fi
else
  chroot "$ROOTFS" apt-get update
fi

# --force-confold/confdef keeps the pre-written local conffiles without dpkg
# conffile prompts; the chroot stdin is EOF and a prompt would abort with
# exit 100.
DPKG_OPTS=(-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)
# zstd explicit: --no-install-recommends would otherwise drop it and the
# initramfs falls back to gzip. initramfs-tools explicit: linux-image-generic
# only Recommends it, which --no-install-recommends filters out and no
# initramfs would be generated at all. grub-efi-arm64 brings
# grub-efi-arm64-bin/grub-common (grub-install/grub-mkimage + arm64-efi
# modules). ca-certificates explicit: already installed by the live-archive
# bootstrap above, the frozen install keeps dpkg state coherent with the
# rest of the rootfs.
# Daily-tool tier + manual-alignment tier (manual ch.3): network
# diagnostics, editors/files, monitoring, dev basics -- --no-install-recommends
# keeps it lean; network-manager (3.7, the connection manager the manual's
# nmtui/nmcli workflows assume), docker.io + docker-compose-v2 + docker-buildx
# (3.24, preinstalled + disabled, enable_docker.sh flips it on -- the vendor
# image ships docker-compose-plugin and docker-buildx-plugin from the CE repo,
# this image installs the Ubuntu packages instead),
# i2c-tools / ir-keytable / lm-sensors / v4l-utils / cmake / python3-spidev
# (3.13/3.14/3.18/3.28), build-essential + swig + python3-dev (3.17/3.20/3.34),
# linux-headers-generic (3.33), gpiod (mainline GPIO), locales (3.29), zram-tools
# (official zram swap: 50% RAM, lzo-rle, priority 5), bc + toilet
# (login MOTD: sysinfo arithmetic + the ASCII-art logo). Every
# package is DFSG-free from main/universe (see README "Licenses and
# redistribution"). systemd-resolved is the DNS consumer: NM's DHCP-provided
# DNS and the firstrun static DNS feed it, and the stub resolv.conf makes the
# shipped image independent of any build-host resolver (the CI runner's
# internal DNS cannot reach the board's LAN and must never ship).
PKGS="ca-certificates linux-image-generic linux-modules-extra-generic grub-efi-arm64 initramfs-tools cloud-guest-utils iproute2 device-tree-compiler systemd-timesyncd systemd-resolved dbus zstd openssh-server sudo systemd-sysv iputils-ping bind9-dnsutils mtr-tiny netcat-openbsd traceroute tcpdump ethtool net-tools curl wget vim nano less tree file htop iotop lsof sysstat rsync bash-completion man-db unzip zip jq usbutils pciutils git python3-pip python3-venv docker.io docker-compose-v2 docker-buildx i2c-tools ir-keytable lm-sensors build-essential swig python3-dev linux-headers-generic gpiod locales network-manager v4l-utils cmake python3-spidev zram-tools bc toilet"
if ! chroot "$ROOTFS" apt-get install -y --no-install-recommends "${DPKG_OPTS[@]}" $PKGS; then
  # The full set fails as a whole when linux-modules-extra-generic has no
  # matching build for the base release; retry without it.
  echo ">> install failed, retrying without linux-modules-extra-generic"
  chroot "$ROOTFS" apt-get install -y --no-install-recommends "${DPKG_OPTS[@]}" \
    ca-certificates linux-image-generic grub-efi-arm64 initramfs-tools cloud-guest-utils iproute2 device-tree-compiler systemd-timesyncd systemd-resolved dbus zstd openssh-server sudo systemd-sysv iputils-ping bind9-dnsutils mtr-tiny netcat-openbsd traceroute tcpdump ethtool net-tools curl wget vim nano less tree file htop iotop lsof sysstat rsync bash-completion man-db unzip zip jq usbutils pciutils git python3-pip python3-venv docker.io docker-compose-v2 docker-buildx i2c-tools ir-keytable lm-sensors build-essential swig python3-dev linux-headers-generic gpiod locales network-manager v4l-utils cmake python3-spidev zram-tools bc toilet
fi
# Defensive: if cloud-initramfs-growroot still ended up installed (dependency
# drag), purge it and rebuild the initrd; this image grows the root via the
# first-boot service instead of an initramfs hook.
if chroot "$ROOTFS" dpkg -s cloud-initramfs-growroot >/dev/null 2>&1; then
  chroot "$ROOTFS" apt-get purge -y cloud-initramfs-growroot
  chroot "$ROOTFS" update-initramfs -u
fi
echo "--- /boot kernel artifacts ---"
ls -lh "$ROOTFS"/boot

# ---- 5. DTB discovery, LED patch and boot finalization ----
phase "DTB discovery and boot finalization"

DTB_HOST=$(find "$ROOTFS/usr/lib" -name 'sun50i-h618-orangepi-zero3.dtb' -print -quit 2>/dev/null || true)
[ -n "$DTB_HOST" ] || fail "sun50i-h618-orangepi-zero3.dtb not found in staging"
DTB_REL=${DTB_HOST#"$ROOTFS"}
echo ">> Ubuntu DTB path: $DTB_REL"

# Mainline DT has no green LED and leaves red:power lit; add led-1 as
# green:status (color 2, heartbeat, GPIO phandle taken from led-0 = PC13,
# active-high) and led-0 default-state=off. A kernel upgrade ships a fresh
# unpatched DTB; the opizero3-greenled service re-applies the patch on board.
PIO_PH=$(fdtget "$DTB_HOST" /leds/led-0 gpios | awk '{print $1}')
[ -n "$PIO_PH" ] || fail "cannot resolve led-0 gpios phandle (mainline DT structure changed?)"
fdtput -c "$DTB_HOST" /leds/led-1 2>/dev/null || true   # idempotent: ignore an existing node
fdtput -t s "$DTB_HOST" /leds/led-1 function status
fdtput -t u "$DTB_HOST" /leds/led-1 color 2
fdtput -t u "$DTB_HOST" /leds/led-1 gpios "$PIO_PH" 2 13 0
fdtput -t s "$DTB_HOST" /leds/led-1 linux,default-trigger heartbeat
fdtput -t s "$DTB_HOST" /leds/led-0 default-state off
# SPI0 user access (manual 3.18): the controller ships okay with its pinctrl
# wired, but with no user-space device; a spidev child (the spidev driver
# binds to the legacy "rohm,dh2228fv" compatible) makes /dev/spidev0.0 appear.
fdtput -c "$DTB_HOST" /soc/spi@5010000/spidev@0 2>/dev/null || true
fdtput -t s "$DTB_HOST" /soc/spi@5010000/spidev@0 compatible rohm,dh2228fv
fdtput -t u "$DTB_HOST" /soc/spi@5010000/spidev@0 reg 0
fdtput -t u "$DTB_HOST" /soc/spi@5010000/spidev@0 spi-max-frequency 1000000
# Upstream flash@0 (jedec,spi-nor) collides with spidev@0 on the same CS;
# disable it so spidev@0 owns CS0.
fdtput -t s "$DTB_HOST" /soc/spi@5010000/flash@0 status disabled 2>/dev/null || true
# IR receiver (manual 3.13): the node ships disabled with its pinctrl already
# wired; status=okay is all it needs (sunxi_ir_rx binds via OF modalias).
fdtput -t s "$DTB_HOST" /soc/ir@7040000 status okay
# /boot/dtb fallback copy: Ubuntu's 10_linux only emits a devicetree line for
# a dtb under /boot, so the patched copy keeps the devicetree line even after
# an HWE upgrade regenerates the config (BOOTAA64.EFI embeds the fdt module).
cp -f "$DTB_HOST" "$ROOTFS/boot/dtb"
[ "$(fdtget "$DTB_HOST" /soc/spi@5010000/spidev@0 compatible 2>/dev/null)" = "rohm,dh2228fv" ] \
  || fail "spidev DTB patch verification failed"
[ "$(fdtget "$DTB_HOST" /soc/spi@5010000/flash@0 status 2>/dev/null)" = "disabled" ] \
  || fail "flash@0 DTB disable verification failed"
[ "$(fdtget "$DTB_HOST" /soc/ir@7040000 status 2>/dev/null)" = "okay" ] \
  || fail "ir DTB patch verification failed"
echo ">> DTB patched: led-1 heartbeat + led-0 off + spi0 spidev (flash@0 off) + ir status=okay + /boot/dtb copy (pio=$PIO_PH)"

# Kernel version discovery (feeds the grub.cfg template).
KVER=""
for f in "$ROOTFS"/boot/vmlinuz-*; do
  if [ -e "$f" ]; then KVER=${f##*/vmlinuz-}; break; fi
done
[ -n "$KVER" ] || fail "no vmlinuz-* in staging /boot"
echo ">> kernel version: $KVER"

# grub-efi boot chain (policy-rc.d still in place).
# Step 1: grub-install -- the chroot has no EFI variables and no target block
# device, and grub-probe would resolve the EFI dir to a build-host disk, so
# --removable --no-nvram only lays down files (/boot/grub arm64-efi module
# directory). Failure is non-fatal: BOOTAA64.EFI is rebuilt deterministically
# in step 2, which is the authoritative artifact.
mkdir -p "$ROOTFS/boot/efi"
if ! chroot "$ROOTFS" grub-install --target=arm64-efi --efi-directory=/boot/efi --removable \
     --no-nvram \
     --modules="ext2 fat part_msdos search search_fs_uuid configfile normal echo linux fdt"; then
  echo ">> warning: grub-install failed inside the chroot (see above); BOOTAA64.EFI will be built by grub-mkimage"
fi
# Step 2: grub-mkimage builds BOOTAA64.EFI with the prefix embedded verbatim
# ('(,msdos1)/EFI/BOOT' = partition 1 of the card the firmware loaded from;
# the ESP stub then hops to the ext4 root). Explicit module list: mkimage
# would otherwise guess partition modules from the host's GPT, while the
# target card is MBR (part_msdos + ext2 mandatory). fdt provides the
# devicetree command (no devicetree.mod; fdt.mod exists in the
# grub-efi-arm64-bin file list). EFI/BOOT is created explicitly: an early
# grub-install failure can leave it missing and mkimage -o would abort.
mkdir -p "$ROOTFS/boot/efi/EFI/BOOT"
chroot "$ROOTFS" grub-mkimage -O arm64-efi -o /boot/efi/EFI/BOOT/BOOTAA64.EFI \
  -p '(,msdos1)/EFI/BOOT' \
  ext2 fat part_msdos search search_fs_uuid configfile normal echo linux fdt
# Step 3: hand-written minimal grub.cfg -- the Ubuntu generic header calls
# commands BOOTAA64.EFI is not built with (load_env/save_env/loadfont/
# fwsetup); five elements only: menuentry + search.fs_uuid + linux + initrd +
# devicetree, timeout 2s.
[ -f "$ROOTFS/boot/vmlinuz-$KVER" ]    || fail "vmlinuz-$KVER missing from staging"
[ -f "$ROOTFS/boot/initrd.img-$KVER" ] || fail "initrd.img-$KVER missing from staging"
cat > "$GRUB_CFG" <<GCFG
set default=0
set timeout=2

menuentry 'Ubuntu 26.04 (OrangePi Zero3)' {
	search.fs_uuid $ROOT_UUID root
	linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID console=ttyS0,115200 rootwait
	initrd /boot/initrd.img-$KVER
	devicetree $DTB_REL
}
GCFG
echo "--- /boot/grub/grub.cfg (hand-written minimal) ---"
cat "$GRUB_CFG"
# Step 4: ESP stub cfg (Ubuntu live image hop pattern) -- the embedded prefix
# points at the EFI binary's own directory, so the stub finds the ext4 root
# by UUID and loads the real config; a grub that reads /boot/grub/grub.cfg
# directly also boots.
cat > "$ROOTFS/boot/efi/EFI/BOOT/grub.cfg" <<STUB
search.fs_uuid $ROOT_UUID root
set prefix=(\$root)'/boot/grub'
configfile \$prefix/grub.cfg
STUB
echo "--- /boot/efi/EFI/BOOT/grub.cfg (ESP stub) ---"
cat "$ROOTFS/boot/efi/EFI/BOOT/grub.cfg"

# ---- 6. chroot finalization ----
phase "chroot finalization"

rm -f "$ROOTFS/usr/sbin/policy-rc.d"
# The snapshot conf must not ship in the image: it would freeze the board's
# own future apt upgrades to this build's snapshot forever.
rm -f "$ROOTFS/etc/apt/apt.conf.d/50snapshot"
# The chroot resolv.conf held the build container's resolver (or CHROOT_DNS)
# for the apt phase; it must not ship either -- on the CI runner that file
# points at the runner's internal DNS, unreachable from any real LAN. The
# image ships the systemd-resolved stub instead: resolved creates
# /run/systemd/resolve/stub-resolv.conf on the board at boot and consumes
# NM's DHCP-provided DNS plus every NM connection profile (firstrun static
# config included).
rm -f "$ROOTFS/etc/resolv.conf"
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
# Manual 3.29 (server part): pre-generate the UTF-8 locales, zh_CN included
# (the desktop IME components of the manual chapter are N/A on this headless
# image).
sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/; s/^# zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' "$ROOTFS/etc/locale.gen"
chroot "$ROOTFS" locale-gen
# Official user model: orangepi (uid 1000, sudo+docker groups) with password
# "orangepi", root password also "orangepi" (serial rescue only; sshd keeps
# its default prohibit-password for root).
printf 'root:orangepi\n' | chroot "$ROOTFS" chpasswd
chroot "$ROOTFS" useradd -m -u 1000 -s /bin/bash -G sudo,docker orangepi
printf 'orangepi:orangepi\n' | chroot "$ROOTFS" chpasswd
# docker.io postinst creates the enable links at install time; strip (manual 3.24).
rm -f "$ROOTFS/etc/systemd/system/multi-user.target.wants/docker.service" \
      "$ROOTFS/etc/systemd/system/multi-user.target.wants/containerd.service" \
      "$ROOTFS/etc/systemd/system/sockets.target.wants/docker.socket"
chroot "$ROOTFS" apt-get clean
rm -rf "$ROOTFS/var/lib/apt/lists/"*
echo ">> policy-rc.d removed / snapshot conf removed / resolv.conf -> resolved stub / root+orangepi passwords set / user orangepi (uid 1000) created / docker enable links stripped / apt cache and lists cleaned"
# dpkg still creates the directory and symlink entries of excluded firmware
# paths (only the file CONTENTS are filtered): prune the empty dirs and the
# compat symlinks so only real content remains under /usr/lib/firmware
# (regulatory.db + the allwinner device-tree). On-board upgrades may recreate
# a few empty dirs; that is cosmetic.
find "$ROOTFS/usr/lib/firmware" -type l -delete 2>/dev/null || true
find "$ROOTFS/usr/lib/firmware" -depth -mindepth 1 -type d -empty -delete 2>/dev/null || true
echo ">> pruned empty firmware dirs and firmware compat symlinks under /usr/lib/firmware"

# ---- 7. Privileged-free image assembly ----
phase "image assembly (truncate + sfdisk + dd + mkfs.ext4, no block device)"

# Bind mounts must be released before mkfs.ext4 -d copies the staging tree.
for m in proc sys dev; do
  if mountpoint -q "$ROOTFS/$m"; then umount "$ROOTFS/$m"; fi
done

truncate -s 4097MiB "$IMG"
# p1: ESP 256 MiB (FAT32, bootable) at sector 2048; p2: ext4 at sector 526336
# (the gap leaves room for U-Boot dd'd at 8 KiB).
sfdisk "$IMG" <<'SFDISK'
label: dos
start=2048, size=524288, type=ef, bootable
start=526336, type=83
SFDISK
dd if="$UB_BIN" of="$IMG" bs=1024 seek=8 conv=notrunc
# p2 root: UUID matches /etc/default/grub and the ESP stub (offset =
# sector 526336 x 512).
mkfs.ext4 -F -U "$ROOT_UUID" -E offset=269484032 -L opizero3 -d "$ROOTFS" "$IMG" 3840m
# p1 ESP: standalone file populated with mtools, then dd'd in.
truncate -s 256MiB "$ESP_TMP"
mformat -i "$ESP_TMP" -F ::
mcopy -i "$ESP_TMP" -s "$ROOTFS/boot/efi/EFI" ::/
mcopy -i "$ESP_TMP" "$ROOTFS/boot/efi/orangepi_first_run.txt.template" ::orangepi_first_run.txt.template
dd if="$ESP_TMP" of="$IMG" bs=1MiB seek=1 conv=notrunc

# ---- 8. Post-build assertions ----
phase "post-build assertions"

# [1/16] hand-written grub.cfg skeleton (timeout 2s, no Ubuntu generic header).
[ -f "$GRUB_CFG" ] || fail "[1/16] grub.cfg missing"
grep -q '^set timeout=2$' "$GRUB_CFG" || fail "[1/16] grub.cfg has no set timeout=2"
grep -qE '^[[:space:]]*menuentry ' "$GRUB_CFG" || fail "[1/16] grub.cfg has no menuentry"
grep -qE "^[[:space:]]*search.fs_uuid $ROOT_UUID root\$" "$GRUB_CFG" || fail "[1/16] grub.cfg has no search.fs_uuid $ROOT_UUID"
LINUX_LINES=$(grep -E '^[[:space:]]*linux[[:space:]]' "$GRUB_CFG" || true)
grep -q "root=UUID=$ROOT_UUID" <<<"$LINUX_LINES"  || fail "[1/16] linux line has no root=UUID=$ROOT_UUID"
grep -q 'console=ttyS0,115200' <<<"$LINUX_LINES"  || fail "[1/16] linux line has no console=ttyS0,115200"
grep -q 'rootwait' <<<"$LINUX_LINES"              || fail "[1/16] linux line has no rootwait"
grep -qE "^[[:space:]]*initrd[[:space:]]+/boot/initrd.img-$KVER\$" "$GRUB_CFG" || fail "[1/16] initrd line does not match kernel version"
if grep -q 'load_env\|save_env\|loadfont\|fwsetup' "$GRUB_CFG"; then
  fail "[1/16] grub.cfg still contains Ubuntu generic header commands"
fi
echo "[1/16] grub.cfg: timeout=2 + menuentry + search.fs_uuid + linux(root=UUID+console+rootwait) + initrd, no generic header"

# [2/16] boot artifacts exist and the config references match.
[ -f "$ROOTFS/boot/vmlinuz-$KVER" ]    || fail "[2/16] vmlinuz-$KVER missing from staging"
[ -f "$ROOTFS/boot/initrd.img-$KVER" ] || fail "[2/16] initrd.img-$KVER missing from staging"
[ -f "$ROOTFS$DTB_REL" ] || fail "[2/16] devicetree target missing from staging: $ROOTFS$DTB_REL"
grep -qE "^[[:space:]]*devicetree $DTB_REL\$" "$GRUB_CFG" || fail "[2/16] grub.cfg has no devicetree $DTB_REL line"
echo "[2/16] vmlinuz/initrd.img-$KVER present + dtb present ($DTB_REL) + cfg devicetree reference consistent"

# [3/16] initrd checks: no growroot hook, dev/console present, sunxi_mmc listed.
INITRDS=("$ROOTFS"/boot/initrd.img-*)
[ -e "${INITRDS[0]}" ] || fail "[3/16] no initrd.img-* in staging"
INITRD_REL="/boot/$(basename "${INITRDS[0]}")"
if chroot "$ROOTFS" sh -c 'command -v lsinitramfs >/dev/null 2>&1'; then
  # Ubuntu's list tool is lsinitramfs (lsinitrd belongs to dracut).
  LSOUT=$(chroot "$ROOTFS" lsinitramfs "$INITRD_REL")
else
  # Fallback: unpack and normalize to lsinitramfs-style relative paths; the
  # unpack path lives inside the chroot, so find must run on the same side.
  chroot "$ROOTFS" unmkinitramfs "$INITRD_REL" /tmp/irx
  LSOUT=$(cd "$ROOTFS/tmp/irx" && find . -mindepth 1 | sed 's|^\./||')
  rm -rf "$ROOTFS/tmp/irx"
fi
echo "--- initramfs content: $(wc -l <<<"$LSOUT") entries ---"
N_GROW=$(grep -c growroot <<<"$LSOUT" || true)
[ "$N_GROW" -eq 0 ] || fail "[3/16] initrd still contains growroot x$N_GROW"
grep -qx 'dev/console' <<<"$LSOUT" || fail "[3/16] initrd has no dev/console (PID 1 loses its console fd)"
grep -qE '(^|/)sunxi[-_]mmc' <<<"$LSOUT" || fail "[3/16] initrd has no sunxi_mmc"
echo "[3/16] initrd checks passed: growroot=0 + dev/console listed + sunxi_mmc listed ($INITRD_REL)"

# [4/16] first-boot resize trio (unit + wants link + script) and dependencies.
[ -f "$ROOTFS/etc/systemd/system/opizero3-resize.service" ] || fail "[4/16] opizero3-resize.service unit missing"
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/opizero3-resize.service" ] || fail "[4/16] opizero3-resize.service not enabled (wants link missing)"
[ -x "$ROOTFS/usr/local/sbin/opizero3-resize" ] || fail "[4/16] /usr/local/sbin/opizero3-resize missing or not executable"
grep -q 'growpart /dev/mmcblk0 2' "$ROOTFS/usr/local/sbin/opizero3-resize" || fail "[4/16] resize script has no growpart step"
grep -q 'resize2fs' "$ROOTFS/usr/local/sbin/opizero3-resize" || fail "[4/16] resize script has no resize2fs step"
grep -q 'systemctl disable opizero3-resize.service' "$ROOTFS/usr/local/sbin/opizero3-resize" || fail "[4/16] resize script has no self-disable step"
ls "$ROOTFS/usr/bin/growpart" >/dev/null 2>&1 || fail "[4/16] growpart missing (cloud-guest-utils not installed?)"
ls "$ROOTFS/sbin/resize2fs"  >/dev/null 2>&1 || fail "[4/16] resize2fs missing (e2fsprogs?)"
echo "[4/16] opizero3-resize: unit + wants + script (growpart->resize2fs->self-disable) + growpart/resize2fs present"

# [5/16] LED alignment: DTB led-1/led-0 patch + self-heal service + fdtput.
[ "$(fdtget "$DTB_HOST" /leds/led-1 color 2>/dev/null)" = "2" ] || fail "[5/16] DTB led-1 color is not 2 (green:status naming failed)"
[ "$(fdtget "$DTB_HOST" /leds/led-1 linux,default-trigger 2>/dev/null)" = "heartbeat" ] || fail "[5/16] DTB led-1 has no heartbeat default trigger"
[ "$(fdtget "$DTB_HOST" /leds/led-0 default-state 2>/dev/null)" = "off" ] || fail "[5/16] DTB led-0 default-state is not off (red LED not disabled)"
[ -x "$ROOTFS/usr/local/sbin/opizero3-greenled" ] || fail "[5/16] greenled script missing or not executable"
grep -q heartbeat "$ROOTFS/usr/local/sbin/opizero3-greenled" || fail "[5/16] greenled script has no heartbeat write"
grep -q '\*:power' "$ROOTFS/usr/local/sbin/opizero3-greenled" || fail "[5/16] greenled script has no red LED off section"
grep -q fdtput "$ROOTFS/usr/local/sbin/opizero3-greenled" || fail "[5/16] greenled script has no DTB self-heal section"
[ -x "$ROOTFS/usr/bin/fdtput" ] || fail "[5/16] fdtput missing from rootfs (device-tree-compiler not installed?)"
[ "$(fdtget "$ROOTFS/boot/dtb" /leds/led-0 default-state 2>/dev/null)" = "off" ] || fail "[5/16] /boot/dtb fallback copy missing or unpatched"
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/opizero3-greenled.service" ] || fail "[5/16] greenled service not enabled (wants link missing)"
echo "[5/16] LED alignment: DTB led-1 (green:status/heartbeat) + led-0 (off) + self-heal service + fdtput"

# [6/16] /sbin/init exists and resolves to systemd (ubuntu-base ships no
# systemd-sysv; without it the board panics). Under usr-merge the host-side
# readlink -f stays inside the staging tree.
INIT_T=$(readlink -f "$ROOTFS/sbin/init")
[ -x "$ROOTFS/sbin/init" ] || fail "[6/16] /sbin/init missing (systemd-sysv not installed?)"
[ "$INIT_T" = "$ROOTFS/usr/lib/systemd/systemd" ] || fail "[6/16] /sbin/init resolves to $INIT_T, expected usr/lib/systemd/systemd"
echo "[6/16] /sbin/init -> /usr/lib/systemd/systemd (executable)"

# [7/16] official user model: orangepi (uid 1000) + non-locked password hashes.
grep -qE '^orangepi:[^:]*:1000:1000::/home/orangepi:/bin/bash$' "$ROOTFS/etc/passwd" \
  || fail "[7/16] /etc/passwd orangepi line does not match the official shape (uid=1000/home/bash)"
SH_OPI=$(awk -F: '$1=="orangepi"{print $2}' "$ROOTFS/etc/shadow")
SH_ROOT=$(awk -F: '$1=="root"{print $2}' "$ROOTFS/etc/shadow")
[ -n "$SH_OPI" ]  || fail "[7/16] shadow has no orangepi entry"
[ -n "$SH_ROOT" ] || fail "[7/16] shadow has no root entry"
case "$SH_OPI"   in '!'*|'*'*) fail "[7/16] orangepi password hash is locked: $SH_OPI" ;; esac
case "$SH_ROOT"  in '!'*|'*'*) fail "[7/16] root password hash is locked: $SH_ROOT" ;; esac
echo "[7/16] orangepi (uid=1000, sudo group) + root/orangepi password hashes in place (root for serial rescue only)"

# [8/16] reverse checks: nothing from other boot stacks may survive. A
# leftover extlinux.conf would be picked up by the U-Boot distro scan ahead
# of the EFI bootloader.
EXTLINUX_LEFT=$(find "$ROOTFS" -name extlinux.conf -print -quit 2>/dev/null || true)
[ -z "$EXTLINUX_LEFT" ] || fail "[8/16] leftover extlinux.conf in staging (U-Boot distro scan would hit it first): $EXTLINUX_LEFT"
if chroot "$ROOTFS" dpkg -s flash-kernel >/dev/null 2>&1; then
  fail "[8/16] flash-kernel is installed (must not coexist with the grub-efi boot chain)"
fi
SCR_LEFT=$(find "$ROOTFS/boot" -maxdepth 1 -name '*.scr' -print -quit 2>/dev/null || true)
[ -z "$SCR_LEFT" ] || fail "[8/16] U-Boot script image present in /boot: $SCR_LEFT"
if [ -e "$ROOTFS/boot/orangepiEnv.txt" ]; then fail "[8/16] /boot/orangepiEnv.txt exists"; fi
if [ -e "$ROOTFS/usr/bin/u-boot-update" ] || [ -e "$ROOTFS/etc/default/u-boot" ]; then
  fail "[8/16] U-Boot menu tooling present in staging (conflicts with the grub-efi boot chain)"
fi
echo "[8/16] no extlinux.conf / flash-kernel absent / no U-Boot script image or env file / no U-Boot menu tooling"

# [9/16] ESP contents verified via mtools; mdir renders long names in two
# 8.3-style columns, so files are mcopy'd back and compared byte-for-byte.
MDIR_OUT=$(mdir -i "$ESP_TMP" ::/EFI/BOOT)
echo "--- mdir ::/EFI/BOOT ---"
echo "$MDIR_OUT"
ESP_CHECK="$BUILD/esp-readback.tmp"
mcopy -i "$ESP_TMP" ::/EFI/BOOT/BOOTAA64.EFI "$ESP_CHECK" \
  || fail "[9/16] ESP readback of BOOTAA64.EFI failed (file not on ESP?): $MDIR_OUT"
cmp -s "$ESP_CHECK" "$ROOTFS/boot/efi/EFI/BOOT/BOOTAA64.EFI" \
  || fail "[9/16] ESP BOOTAA64.EFI differs from staging (byte-level cmp)"
mcopy -i "$ESP_TMP" ::/EFI/BOOT/grub.cfg "$ESP_CHECK" \
  || fail "[9/16] ESP readback of grub.cfg failed (file not on ESP?): $MDIR_OUT"
grep -q "search.fs_uuid $ROOT_UUID root" "$ESP_CHECK" \
  || fail "[9/16] ESP stub cfg has no search.fs_uuid $ROOT_UUID"
mcopy -i "$ESP_TMP" ::/orangepi_first_run.txt.template "$ESP_CHECK" \
  || fail "[9/16] ESP readback of orangepi_first_run.txt.template failed (not on ESP?)"
cmp -s "$ESP_CHECK" "$ROOTFS/boot/efi/orangepi_first_run.txt.template" \
  || fail "[9/16] ESP firstrun template differs from staging"
rm -f "$ESP_CHECK"
echo "[9/16] ESP: BOOTAA64.EFI readback cmp equal + stub (search.fs_uuid match) + grub.cfg in place"

# [10/16] image byte level (dual partition).
S55=$(dd if="$IMG" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n') \
  || fail "[10/16] cannot read the MBR boot signature (dd failed)"
[ "$S55" = "55aa" ] || fail "[10/16] MBR 55AA@510 got $S55"
SD=$(sfdisk -d "$IMG")
P1_LINE=$(grep -E 'start=[[:space:]]*2048' <<<"$SD" || true)
P2_LINE=$(grep -E 'start=[[:space:]]*526336' <<<"$SD" || true)
grep -q 'type=ef' <<<"$P1_LINE"  || fail "[10/16] p1 type is not ef: $SD"
grep -q 'bootable' <<<"$P1_LINE" || fail "[10/16] p1 has no bootable flag: $SD"
grep -q 'type=83' <<<"$P2_LINE"  || fail "[10/16] p2 is not at 526336 or type is not 83: $SD"
EGON_IMG=$(dd if="$IMG" bs=1 skip=$((8192+4)) count=8 2>/dev/null) \
  || fail "[10/16] cannot read the U-Boot embed region (dd failed)"
grep -aq 'eGON.BT0' <<<"$EGON_IMG" || fail "[10/16] no eGON.BT0 at 8KiB+4"
FAT55=$(dd if="$IMG" bs=1 skip=1049086 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n') \
  || fail "[10/16] cannot read the FAT boot signature (dd failed)"
[ "$FAT55" = "55aa" ] || fail "[10/16] FAT boot sector 55AA@1048576+510 got $FAT55"
# ext4 superblock s_uuid (root offset + 1024 + 104, 16 bytes) must equal
# ROOT_UUID -- the single UUID shared by grub.cfg, the ESP stub and mkfs -U.
UUID_RAW=$(dd if="$IMG" bs=1 skip=$((269484032+1024+104)) count=16 2>/dev/null | od -An -tx1 | tr -d ' \n') \
  || fail "[10/16] cannot read the ext4 superblock UUID (dd failed)"
IMG_UUID=${UUID_RAW:0:8}-${UUID_RAW:8:4}-${UUID_RAW:12:4}-${UUID_RAW:16:4}-${UUID_RAW:20:12}
[ "$IMG_UUID" = "$ROOT_UUID" ] || fail "[10/16] ext4 superblock UUID $IMG_UUID does not match ROOT_UUID $ROOT_UUID"
MAGIC=$(dd if="$IMG" bs=1 skip=269485112 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n') \
  || fail "[10/16] cannot read the ext4 magic (dd failed)"
[ "$MAGIC" = "53ef" ] || fail "[10/16] ext4 magic at 269484032+1024+56 got $MAGIC (expected 53 ef = 0xEF53 little endian)"
echo "[10/16] MBR 55AA@510 / p1 ef+bootable@2048 / p2 83@526336 / eGON.BT0@8KiB+4 / FAT 55AA@1049086 / ext4 53ef@269485112 all hit"

# [11/16] size and hash.
IMG_SZ=$(stat -c%s "$IMG")
EXPECT=$(( 1048576 + 4294967296 ))
[ "$IMG_SZ" = "$EXPECT" ] || fail "[11/16] image is $IMG_SZ bytes, expected $EXPECT (1MiB+4096MiB)"
echo "[11/16] size $IMG_SZ = 1MiB+4096MiB; du actual usage: $(du -h "$IMG" | cut -f1) (sparse file)"
sha256sum "$IMG"
echo "      U-Boot source sha256: $(sha256sum "$UB_BIN" | cut -d' ' -f1)"

# [12/16] chroot final state.
if [ -e "$ROOTFS/usr/sbin/policy-rc.d" ]; then fail "[12/16] policy-rc.d not removed (no service would start on the board)"; fi
LEFT=$(find "$ROOTFS/var/lib/apt/lists" -type f -print -quit 2>/dev/null || true)
[ -z "$LEFT" ] || fail "[12/16] apt lists not cleaned: $LEFT"
[ "$(readlink "$ROOTFS/etc/resolv.conf")" = "/run/systemd/resolve/stub-resolv.conf" ] \
  || fail "[12/16] /etc/resolv.conf is not the systemd-resolved stub symlink (build-host resolver leaked?)"
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" ] \
  || fail "[12/16] systemd-resolved not enabled (wants link missing)"
[ -x "$ROOTFS/sbin/init" ] || fail "[12/16] /sbin/init missing (systemd-sysv not installed?)"
[ -d "$ROOTFS/var/log/journal" ] || fail "[12/16] /var/log/journal directory missing (persistent journald)"
echo "[12/16] policy-rc.d removed / apt lists cleaned / resolv.conf -> resolved stub / resolved enabled / /sbin/init present / var/log/journal precreated"

# [13/16] SSH/network/user (headless access); wants links verified with
# [ -L ], unit files with staging-relative [ -f ] (see header note).
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/ssh.service" ]            || fail "[13/16] ssh.service not enabled"
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/NetworkManager.service" ] || fail "[13/16] NetworkManager not enabled"
[ -f "$ROOTFS/lib/systemd/system/ssh.service" ]                                    || fail "[13/16] ssh.service unit missing"
[ -f "$ROOTFS/lib/systemd/system/NetworkManager.service" ]                         || fail "[13/16] NetworkManager.service unit missing"
[ -f "$ROOTFS/etc/NetworkManager/system-connections/end0-default.nmconnection" ]   || fail "[13/16] NM default DHCP keyfile missing"
grep -q '^unmanaged-devices=none$' "$ROOTFS/etc/NetworkManager/conf.d/10-globally-managed-devices.conf" \
  || fail "[13/16] NM globally-managed override missing (devices stay strictly unmanaged without netplan)"
[ -f "$ROOTFS/usr/local/sbin/watchdog_test" ]                                      || fail "[13/16] watchdog_test helper missing"
[ ! -e "$ROOTFS/etc/systemd/network/10-dhcp.network" ]                             || fail "[13/16] stale networkd 10-dhcp.network (networkd must stay disabled)"
ls "$ROOTFS"/etc/ssh/ssh_host_ed25519_key >/dev/null 2>&1                            || fail "[13/16] ssh host key not generated (openssh postinst should have created it)"
chroot "$ROOTFS" id orangepi >/dev/null 2>&1                                         || fail "[13/16] user orangepi not created"
chroot "$ROOTFS" dpkg -s openssh-server sudo iproute2 cloud-guest-utils systemd-timesyncd dbus systemd-resolved iputils-ping bind9-dnsutils curl wget git python3-pip docker.io docker-compose-v2 docker-buildx i2c-tools lm-sensors build-essential linux-headers-generic locales network-manager v4l-utils cmake python3-spidev zram-tools >/dev/null 2>&1 || fail "[13/16] core packages not installed (openssh-server/sudo/iproute2/systemd-resolved/network-manager/docker.io/...)"
# [ ! -L ] not [ ! -e ]: the deb links dangle in the build container and -e follows them.
[ ! -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/docker.service" ] || fail "[13/16] docker.service must ship disabled (manual 3.24 alignment)"
[ ! -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/containerd.service" ] || fail "[13/16] containerd.service must ship disabled (manual 3.24 alignment)"
[ ! -L "$ROOTFS/etc/systemd/system/sockets.target.wants/docker.socket" ] || fail "[13/16] docker.socket must ship disabled (manual 3.24 alignment)"
[ -x "$ROOTFS/usr/local/bin/enable_docker.sh" ] || fail "[13/16] enable_docker.sh missing (manual 3.24 entry point)"
chroot "$ROOTFS" getent group docker >/dev/null 2>&1 || fail "[13/16] docker group missing (docker.io postinst failed?)"
chroot "$ROOTFS" id -nG orangepi 2>/dev/null | grep -qw docker || fail "[13/16] orangepi not in the docker group"
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/zramswap.service" ] || fail "[13/16] zramswap.service not enabled"
grep -q '^ALGO=lzo-rle' "$ROOTFS/etc/default/zramswap" || fail "[13/16] zramswap config has no lzo-rle (official alignment)"
[ -f "$ROOTFS/etc/systemd/journald.conf.d/opizero3.conf" ] || fail "[13/16] journald SystemMaxUse drop-in missing"
[ -f "$ROOTFS/usr/lib/tmpfiles.d/opizero3-zswap.conf" ] || fail "[13/16] zswap-off tmpfiles drop-in missing"
[ -L "$ROOTFS/etc/systemd/system/sysinit.target.wants/opizero3-varlog-journal.service" ] || fail "[13/16] varlog-journal tmpfs service not enabled"
if [ -n "$NTP_SERVERS" ]; then
  [ -f "$ROOTFS/etc/systemd/timesyncd.conf.d/90-custom.conf" ] || fail "[13/16] timesyncd NTP drop-in missing"
fi
# [13/16] login MOTD: scripts executable, orangepi-release without a pinned
# VERSION, soctemp symlink, stock scripts removed, deps installed.
[ -x "$ROOTFS/etc/update-motd.d/10-orangepi-header" ] || fail "[13/16] 10-orangepi-header missing or not executable"
[ -x "$ROOTFS/etc/update-motd.d/30-orangepi-sysinfo" ] || fail "[13/16] 30-orangepi-sysinfo missing or not executable"
grep -q 'BOARD_NAME="OPI Zero3"' "$ROOTFS/etc/orangepi-release" || fail "[13/16] /etc/orangepi-release missing or has no BOARD_NAME"
if grep -q '^VERSION=' "$ROOTFS/etc/orangepi-release"; then
  fail "[13/16] orangepi-release pins VERSION (must stay os-release-tracked for apt upgrades)"
fi
[ "$(readlink "$ROOTFS/etc/orangepimonitor/datasources/soctemp")" = "/sys/devices/virtual/thermal/thermal_zone0/temp" ] \
  || fail "[13/16] soctemp datasource symlink missing or wrong target"
for f in 00-header 10-help-text 50-motd-news 60-unminimize; do
  if [ -e "$ROOTFS/etc/update-motd.d/$f" ]; then fail "[13/16] stock Ubuntu MOTD script survived: $f"; fi
done
[ "$(readlink "$ROOTFS/etc/motd")" = "/var/run/motd" ] || fail "[13/16] /etc/motd is not the official /var/run/motd symlink"
chroot "$ROOTFS" dpkg -s bc toilet >/dev/null 2>&1 || fail "[13/16] bc/toilet missing (login MOTD deps not installed?)"
echo "[13/16] ssh.service + NetworkManager (DHCP keyfile + globally-managed override) + resolved + docker preinstalled (enable links stripped, enable_docker.sh) + host key + user orangepi + core packages + official-style login MOTD in place"

# [14/16] fstab / grub defaults / hostname.
grep -qE '^/dev/mmcblk0p2[[:space:]]+/[[:space:]]+ext4[[:space:]]+defaults,noatime[[:space:]]+0[[:space:]]+1$' \
  "$ROOTFS/etc/fstab" || fail "[14/16] fstab has no root partition line"
grep -qE '^/dev/mmcblk0p1[[:space:]]+/boot/efi[[:space:]]+vfat[[:space:]]+defaults,umask=0077[[:space:]]+0[[:space:]]+2$' \
  "$ROOTFS/etc/fstab" || fail "[14/16] fstab has no ESP line"
grep -q 'console=ttyS0' "$ROOTFS/etc/default/grub" || fail "[14/16] /etc/default/grub has no console=ttyS0"
grep -qx "$CARD_HOSTNAME" "$ROOTFS/etc/hostname"   || fail "[14/16] hostname mismatch (expected $CARD_HOSTNAME)"
grep -qE '^tmpfs[[:space:]]+/var/log[[:space:]]+tmpfs' "$ROOTFS/etc/fstab" || fail "[14/16] fstab has no /var/log tmpfs entry"
echo "[14/16] fstab dual-partition + /var/log tmpfs lines / /etc/default/grub console=ttyS0 / hostname=$CARD_HOSTNAME all hit"

# [15/16] dpkg firmware path-exclude drop-in + first-run services + template.
DPKGCFG="$ROOTFS/etc/dpkg/dpkg.cfg.d/01-opizero3-minimal"
[ -f "$DPKGCFG" ] || fail "[15/16] dpkg path-exclude drop-in missing"
grep -q '^path-exclude=/usr/lib/firmware/\*$' "$DPKGCFG" || fail "[15/16] drop-in has no firmware path-exclude"
grep -q '^path-include=/usr/lib/firmware/regulatory.db$' "$DPKGCFG" || fail "[15/16] drop-in does not keep regulatory.db"
grep -q '^path-include=/usr/lib/firmware/\*/device-tree/allwinner/\*$' "$DPKGCFG" || fail "[15/16] drop-in does not re-include the allwinner device-tree subtree"
[ -f "$ROOTFS/usr/local/sbin/opizero3-firstrun" ] || fail "[15/16] firstrun script missing"
[ -f "$ROOTFS/usr/local/sbin/opizero3-firstrun-config" ] || fail "[15/16] firstrun-config script missing"
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/opizero3-firstrun.service" ] || fail "[15/16] firstrun service not enabled"
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/opizero3-firstrun-config.service" ] || fail "[15/16] firstrun-config service not enabled"
grep -q 'ssh-keygen -A' "$ROOTFS/usr/local/sbin/opizero3-firstrun" || fail "[15/16] firstrun has no ssh-keygen step"
grep -q 'machine-id' "$ROOTFS/usr/local/sbin/opizero3-firstrun" || fail "[15/16] firstrun has no machine-id reset"
grep -q 'opizero3-firstrun.nmconnection' "$ROOTFS/usr/local/sbin/opizero3-firstrun-config" || fail "[15/16] firstrun-config has no NM keyfile writer"
[ -f "$ROOTFS/boot/orangepi_first_run.txt.template" ] || fail "[15/16] firstrun template missing from /boot"
[ -f "$ROOTFS/boot/efi/orangepi_first_run.txt.template" ] || fail "[15/16] firstrun template missing from staging ESP tree"
[ -e "$ROOTFS/root/.not_logged_in_yet" ] || fail "[15/16] .not_logged_in_yet sentinel missing"
echo "[15/16] firmware path-exclude drop-in + firstrun pair (ssh-keygen -A + machine-id + NM keyfile) + template in both locations + sentinel"

# [16/16] firmware-free reality: dpkg state healthy (meta chain intact), the
# Zero3 DTB survives the exclusion (it lives under /usr/lib/firmware), and no
# firmware blob content landed on disk outside the allwinner device-tree.
chroot "$ROOTFS" dpkg -s linux-image-generic >/dev/null 2>&1 || fail "[16/16] linux-image-generic meta not installed (upstream tracking broken?)"
chroot "$ROOTFS" dpkg -s linux-firmware >/dev/null 2>&1 || fail "[16/16] linux-firmware meta not installed (Depends chain broken?)"
[ -f "$ROOTFS/usr/lib/firmware/regulatory.db" ] || fail "[16/16] regulatory.db missing from firmware dir"
ZERO3_DTB=$(find "$ROOTFS/usr/lib/firmware" -path '*/device-tree/allwinner/sun50i-h618-orangepi-zero3.dtb' -print -quit 2>/dev/null)
[ -n "$ZERO3_DTB" ] || fail "[16/16] kernel device-tree lost to the path-exclude (sun50i-h618-orangepi-zero3.dtb missing)"
for blobdir in qcom nvidia amdgpu i915 mellanox marvell; do
  if find "$ROOTFS/usr/lib/firmware/$blobdir" -type f -print -quit 2>/dev/null | grep -q .; then
    fail "[16/16] firmware blob content landed in the image: /usr/lib/firmware/$blobdir"
  fi
done
NSYM=$(find "$ROOTFS/usr/lib/firmware" -type l 2>/dev/null | wc -l)
[ "$NSYM" -eq 0 ] || fail "[16/16] $NSYM firmware compat symlinks remain under /usr/lib/firmware (prune step missing?)"
FW_N=$(find "$ROOTFS/usr/lib/firmware" -type f ! -path '*/device-tree/*' 2>/dev/null | wc -l)
FW_BYTES=$(find "$ROOTFS/usr/lib/firmware" -type f ! -path '*/device-tree/*' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
[ "$FW_BYTES" -lt 1048576 ] || fail "[16/16] non-device-tree firmware content is $FW_BYTES bytes (path-exclude not effective?)"
echo "[16/16] firmware-free rootfs: metas installed + Zero3 DTB kept + blob dirs absent + $FW_N files ($FW_BYTES bytes) outside device-tree"

rm -f "$ESP_TMP"
echo ">> ESP temporary file removed: $ESP_TMP"

phase "done"
echo
echo "== OrangePi Zero3 image build passed all assertions =="
