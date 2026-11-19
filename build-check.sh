#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Build Image.gz and the device trees for the ASUS Z01R (ZS620KL) out of
# tree, using arm64 defconfig plus the extra symbols the built-in vendor
# code needs (arch/arm64/configs/vendor/asus/Z01R-check.config).
#
# The tree has no complete device defconfig, so this is a bring-up build
# check, not the configuration a phone should boot with.
#
# Usage: ./build-check.sh [make targets...]      (default: Image.gz dtbs)
#   OUT=/path      out-of-tree build directory  (default: .build-check)
#   CROSS_COMPILE= compiler prefix              (default: .toolchains/...)
#   JOBS=n         parallel build jobs          (default: nproc)
#   FRAGMENTS="..." config fragments, space separated
#                  (default: Z01R-check.config)

set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$ROOT/.build-check}
CROSS_COMPILE=${CROSS_COMPILE:-$ROOT/.toolchains/aarch64--glibc--stable-2020.08-1/bin/aarch64-linux-}
JOBS=${JOBS:-$(nproc)}
FRAGMENTS=${FRAGMENTS:-$ROOT/arch/arm64/configs/vendor/asus/Z01R-check.config}

if [ "$#" -gt 0 ]; then
	TARGETS=$*
else
	TARGETS="Image.gz dtbs"
fi

MAKE="make ARCH=arm64 O=$OUT CROSS_COMPILE=$CROSS_COMPILE"

mkdir -p "$OUT"
# shellcheck disable=SC2086
$MAKE defconfig

# shellcheck disable=SC2086
"$ROOT/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" \
	$FRAGMENTS

# shellcheck disable=SC2086
$MAKE olddefconfig
# shellcheck disable=SC2086
$MAKE -j"$JOBS" $TARGETS
