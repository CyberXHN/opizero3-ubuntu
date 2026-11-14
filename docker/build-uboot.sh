#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 CyberXHN
#
# OrangePi Zero3 (H618/sun50i_h616) TF-A BL31 + U-Boot build entry point
# (runs inside the container; hosts enter through docker/run.sh).
#
# Flow: TF-A BL31 -> orangepi_zero3_defconfig -> env-backend triple adjustment
#       -> u-boot-sunxi-with-spl.bin -> smoke assertions
#
# Notes:
#   - Everything builds out-of-tree: run.sh bind-mounts the whole repo at /work,
#     and keeping /work/u-boot and /work/arm-trusted-firmware unwritten is what
#     keeps the submodule sources porcelain-clean.
#   - The env-backend triple is a hard requirement of this project: the onboard
#     SPI flash carries factory firmware that saveenv through ENV_IS_IN_SPI_FLASH
#     would overwrite, so SPI and FAT are both disabled and the environment lands
#     in NOWHERE (memory only).
#   - SCP=/dev/null: the H616 has no arisc SCP firmware requirement; feed an
#     empty device explicitly so legacy rules do not look for a firmware file.
#   - TF-A builds out-of-tree via BUILD_BASE, U-Boot via O= (kbuild standard).
#
# Environment variables:
#   JOBS           parallelism, default nproc
#   BUILD_UID/GID  chown build outputs back to the host user at exit (passed by run.sh)
#   DEBUG          1 = set -x command tracing (PS4: timestamp + file:line); empty = normal
#
set -euo pipefail
export LC_ALL=C

# DEBUG=1 enables full command tracing (run.sh forwards it); the PS4 prefix
# carries a timestamp and file:line so CI logs can be correlated per phase.
if [ "${DEBUG:-}" = "1" ]; then
  PS4='+ $(date "+%H:%M:%S") ${BASH_SOURCE}:${LINENO}: '
  set -x
fi

# The container runs as root on a host-owned checkout; let git accept any ownership.
git config --global --add safe.directory '*'

ATF=/work/arm-trusted-firmware
UBOOT=/work/u-boot
BUILD=/work/build
ATF_BUILD="$BUILD/atf"
UB_BUILD="$BUILD/uboot"
XCOMPILE=aarch64-linux-gnu-
JOBS=${JOBS:-$(nproc)}

BL31="$ATF_BUILD/sun50i_h616/release/bl31.bin"
BIN="$UB_BUILD/u-boot-sunxi-with-spl.bin"

cleanup() {
  # The container runs as root; hand written directories back to the host user
  # at exit, otherwise host-side cleanup would need sudo.
  if [ -n "${BUILD_UID:-}" ]; then
    chown -R "${BUILD_UID}:${BUILD_GID:-$BUILD_UID}" "$BUILD" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() { echo "!! FAILED: $*" >&2; exit 1; }

echo "== OrangePi Zero3 U-Boot build (container) =="
echo "TF-A:   $ATF ($(git -C "$ATF" describe --tags 2>/dev/null || echo '?'))"
echo "U-Boot: $UBOOT ($(git -C "$UBOOT" describe --tags 2>/dev/null || echo '?'))"
echo "Jobs:   $JOBS"

# ---- 1. TF-A BL31 ----
# TF-A v2.15 does not accept kbuild-style O=; out-of-tree output is controlled by
# BUILD_BASE (its Makefile defaults to ./build), so BUILD_BASE= must be passed to
# keep the source tree clean.
echo ">> make -C arm-trusted-firmware BUILD_BASE=build/atf PLAT=sun50i_h616 DEBUG=0"
make -C "$ATF" BUILD_BASE="$ATF_BUILD" PLAT=sun50i_h616 DEBUG=0 CROSS_COMPILE="$XCOMPILE" -j"$JOBS" all
[ -s "$BL31" ] || fail "BL31 missing or empty: $BL31"

# ---- 2. U-Boot defconfig ----
make -C "$UBOOT" O="$UB_BUILD" CROSS_COMPILE="$XCOMPILE" orangepi_zero3_defconfig

# ---- 3. Env-backend triple (hard requirement; verify before compiling) ----
"$UBOOT/scripts/config" --file "$UB_BUILD/.config" \
  -e ENV_IS_NOWHERE -d ENV_IS_IN_FAT -d ENV_IS_IN_SPI_FLASH
make -C "$UBOOT" O="$UB_BUILD" CROSS_COMPILE="$XCOMPILE" olddefconfig

grep -qx 'CONFIG_ENV_IS_NOWHERE=y'                 "$UB_BUILD/.config" || fail ".config missing CONFIG_ENV_IS_NOWHERE=y"
grep -qx '# CONFIG_ENV_IS_IN_FAT is not set'       "$UB_BUILD/.config" || fail ".config missing '# CONFIG_ENV_IS_IN_FAT is not set'"
grep -qx '# CONFIG_ENV_IS_IN_SPI_FLASH is not set' "$UB_BUILD/.config" || fail ".config missing '# CONFIG_ENV_IS_IN_SPI_FLASH is not set'"
echo ">> env-backend triple applied and verified"

# ---- 4. U-Boot build ----
echo ">> make -C u-boot O=build/uboot BL31=$BL31 SCP=/dev/null"
make -C "$UBOOT" O="$UB_BUILD" CROSS_COMPILE="$XCOMPILE" BL31="$BL31" SCP=/dev/null -j"$JOBS" all
[ -f "$BIN" ] || fail "u-boot-sunxi-with-spl.bin missing: $BIN"

# ---- 5. Smoke assertions ----
echo
echo "== smoke assertions =="

# [1] BL31 is non-empty
BL31SZ=$(stat -c%s "$BL31")
[ "$BL31SZ" -gt 0 ] || fail "[1/7] BL31 is empty"
echo "[1/7] BL31 non-empty: $BL31SZ bytes ($BL31)"

# [2] ENV triple (asserted early in step 3; re-checked here under the numbered scheme)
grep -qx 'CONFIG_ENV_IS_NOWHERE=y'                 "$UB_BUILD/.config" || fail "[2/7] CONFIG_ENV_IS_NOWHERE=y missing"
grep -qx '# CONFIG_ENV_IS_IN_FAT is not set'       "$UB_BUILD/.config" || fail "[2/7] ENV_IS_IN_FAT not disabled"
grep -qx '# CONFIG_ENV_IS_IN_SPI_FLASH is not set' "$UB_BUILD/.config" || fail "[2/7] ENV_IS_IN_SPI_FLASH not disabled"
echo "[2/7] ENV triple all matched: NOWHERE=y / FAT not set / SPI_FLASH not set"

# [3] eGON magic: the SPL eGON.BT0 signature sits at fixed offset 4
od -A x -t x1z -j 4 -N 8 "$BIN"
EGON=$(dd if="$BIN" bs=1 skip=4 count=8 2>/dev/null) \
  || fail "[3/7] cannot read the SPL header region (dd failed)"
grep -aq 'eGON.BT0' <<<"$EGON" || fail "[3/7] eGON.BT0 magic not found at offset 0x4"
echo "[3/7] eGON magic: offset 0x4 = 65 47 4f 4e 2e 42 54 30 (eGON.BT0)"

# [4] Size < 1 MiB (TF-card partition-start constraint: the image must fit
#     entirely within the 1 MiB leading gap)
SZ=$(stat -c%s "$BIN")
[ "$SZ" -lt 1048576 ] || fail "[4/7] image $SZ bytes >= 1 MiB, partition-start constraint violated"
echo "[4/7] size: $SZ bytes < 1048576 (1 MiB)"
ls -lh "$BIN"

# [5] SPL header DT name: mkimage stamps DEFAULT_DEVICE_TREE (with the allwinner/
#     prefix) into the eGON header string pool, at an offset < 0x8000
DTHIT=$(strings -t d "$BIN" | awk '$1 < 32768 && /sun50i-h618-orangepi-zero3/')
grep -q 'allwinner/sun50i-h618-orangepi-zero3' <<<"$DTHIT" \
  || fail "[5/7] DT name not found within the first 32 KiB of the SPL header (got: ${DTHIT:-no match})"
echo "[5/7] SPL header DT name: $(head -1 <<<"$DTHIT")"

# [6] FIT magic (informational, non-blocking): binman layout = SPL blob + U-Boot
#     FIT; the FIT start moves with the actual SPL size, so locate it automatically
FITOFF=$(grep -abo $'\xd0\x0d\xfe\xed' "$BIN" | head -1 | cut -d: -f1)
if [ -n "$FITOFF" ]; then
  echo "[6/7] FIT magic d0 0d fe ed @ offset $FITOFF (binman layout: SPL + FIT, informational)"
else
  echo "[6/7] FIT magic d0 0d fe ed not found (non-blocking, check the binman layout manually)"
fi

# [7] Closing info
echo "[7/7] version and artifact info:"
echo "  u-boot source: $(git -C "$UBOOT" describe --tags 2>/dev/null || echo '?')"
echo "  atf source:    $(git -C "$ATF" describe --tags 2>/dev/null || echo '?')"
echo -n "  cross compiler: "; aarch64-linux-gnu-gcc --version | head -1 || true
sha256sum "$BIN" "$BL31" | sed 's/^/  /'
echo "  --- key .config items ---"
grep -E 'ENV_IS_|OF_UPSTREAM|SPL_LOAD_FIT|DEFAULT_DEVICE_TREE|BOOTCOMMAND|BOOTSTD' "$UB_BUILD/.config" | sed 's/^/  /' || true
echo "  --- output tree (uboot top level / atf release) ---"
ls -lh "$UB_BUILD" | sed 's/^/  /'
ls -lh "$ATF_BUILD/sun50i_h616/release" | sed 's/^/  /'

echo
echo "== all smoke assertions passed =="
