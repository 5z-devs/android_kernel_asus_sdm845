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
# An object file only proves something when it was compiled from the
# configuration being checked.  A tree that was copied from another build,
# or configured differently and then configured back, still contains objects
# that kbuild is happy to reuse, so "make succeeded" can be true without the
# current configuration ever having been compiled.  $OUT therefore carries a
# stamp naming the fragments and toolchain that produced it, and this script
# refuses any $OUT it cannot show to match instead of reporting a clean
# build from stale objects.
#
# Usage: ./build-check.sh [make targets...]      (default: Image.gz dtbs)
#   OUT=/path      out-of-tree build directory  (default: .build-check,
#                  .build-check-wlan with FORCE_WLAN=1)
#   DEFCONFIG=name base configuration target    (default: defconfig,
#                  vendor/sdm845-perf_defconfig with FORCE_WLAN=1)
#   CROSS_COMPILE= compiler prefix              (default: .toolchains/...)
#   JOBS=n         parallel build jobs          (default: nproc)
#   FRAGMENTS="..." config fragments, space separated, later ones win
#                  (default: Z01R-check.config)
#   CLEAN=1        clean $OUT before configuring it
#   FORCE_WLAN=1   build the CLD WLAN directory with the CFR and direct-buffer-rx
#                  paths forced on, instead of Image.gz/dtbs (default: 0)
#                  (runs on the device configuration, default $OUT is
#                  .build-check-wlan)
#
# FORCE_WLAN exists because none of that code is reachable from the Z01R
# configuration: kbuild never compiles it, so a warning or a break there is
# invisible to the ordinary image build.  The forced switches are make
# variables from qcacld's configs/default_defconfig and never enter .config,
# so a build made with them cannot be told apart from an ordinary one by the
# configuration checksum: the stamp records them, and the default output
# directory is separate, so neither run can quietly reuse the other's objects.
#
# Exit status is 0 only when every requested target was produced from the
# configuration this run checked.

set -eu

STAMP_FORMAT=1

ROOT=$(cd "$(dirname "$0")" && pwd)
CROSS_COMPILE=${CROSS_COMPILE:-$ROOT/.toolchains/aarch64--glibc--stable-2020.08-1/bin/aarch64-linux-}
JOBS=${JOBS:-$(nproc)}
FORCE_WLAN=${FORCE_WLAN:-0}

# The CFR and direct-buffer-rx switches are make variables: they come from
# qcacld's configs/default_defconfig and are never written to .config, so they
# are forced on the make command line.  CONFIG_LITHIUM installs the 11ax HAL
# include path, CONFIG_WMI_DBR_SUPPORT is what makes struct
# direct_buf_rx_metadata visible to target_if_direct_buf_rx_api.h, and the
# CFR/direct-buffer-rx switches decide which of the objects exist at all.
WLAN_FORCE_CONFIG="CONFIG_LITHIUM=y CONFIG_CNSS_QCA6390=y \
CONFIG_WLAN_CFR_ENABLE=y CONFIG_WLAN_ENH_CFR_ENABLE=y \
CONFIG_DIRECT_BUF_RX_ENABLE=y CONFIG_WMI_DBR_SUPPORT=y"

# The forced build runs on the device configuration, not on defconfig plus the
# bring-up fragment: qcacld's Kconfig is only sourced with CONFIG_STAGING, its
# feature set comes from configs/default_defconfig, and the 11ax datapath needs
# the HIF bus and the PE/PMF feature switches the vendor defconfig already gets
# right.  Rebuilding that half of the device configuration in a fragment would
# be inventing a configuration nobody ships, so the forced run mirrors the
# device build and only adds the switches above.
if [ "$FORCE_WLAN" = 1 ]; then
	DEFCONFIG=${DEFCONFIG:-vendor/sdm845-perf_defconfig}
	FRAGMENTS=${FRAGMENTS:-"$ROOT/arch/arm64/configs/vendor/asus/Z01R-check.config $ROOT/arch/arm64/configs/vendor/asus/Z01R.config"}
	OUT=${OUT:-$ROOT/.build-check-wlan}
else
	DEFCONFIG=${DEFCONFIG:-defconfig}
	FRAGMENTS=${FRAGMENTS:-$ROOT/arch/arm64/configs/vendor/asus/Z01R-check.config}
	OUT=${OUT:-$ROOT/.build-check}
fi

if [ "$#" -gt 0 ]; then
	TARGETS=$*
elif [ "$FORCE_WLAN" = 1 ]; then
	TARGETS="drivers/staging/qcacld-3.0/"
else
	TARGETS="Image.gz dtbs"
fi

MAKE="make ARCH=arm64 O=$OUT CROSS_COMPILE=$CROSS_COMPILE"

# Only the build gets the forced symbols: they must not end up in .config,
# which stays the fragments' configuration so it can still be checked against
# the stamp.
BUILD_FLAGS=""
if [ "$FORCE_WLAN" = 1 ]; then
	# Keep going after a broken object: the point of this check is to see
	# everything in the path that does not compile, not just the first one.
	BUILD_FLAGS="-k $WLAN_FORCE_CONFIG"
fi

STAMP=$OUT/.build-check-stamp
LOG=$OUT/.build-check.log
MARKER=$OUT/.build-check-start
EXPECTED=$OUT/.build-check-expected

say() {
	printf 'build-check: %s\n' "$*" >&2
}

die() {
	printf 'build-check: %s\n' "$*" >&2
	exit 1
}

# Nothing but the requested outcome may be reported as success, so a failing
# step always shows why.
on_exit() {
	status=$?
	if [ "$status" -ne 0 ] && [ "${build_started:-0}" = 1 ]; then
		say "failed (status $status); last 40 lines of $LOG:"
		tail -n 40 "$LOG" >&2
	fi
}
trap on_exit EXIT

# What the configuration is derived from.  Cheap enough to compute before
# $OUT/.config is rewritten, so an output directory from another
# configuration is refused instead of being incrementally reused.
inputs() {
	echo "stamp-format $STAMP_FORMAT"
	echo "cross-compile $CROSS_COMPILE"
	echo "defconfig $DEFCONFIG"
	if [ "$FORCE_WLAN" = 1 ]; then
		echo "force-wlan $(echo $WLAN_FORCE_CONFIG)"
	fi
	for frag in $FRAGMENTS; do
		printf 'fragment %s %s\n' "$frag" "$(cksum < "$frag")"
	done
}

# The last mention of a symbol in the fragments is the one that wins, so a
# later fragment disabling what an earlier one enabled is not a conflict.
expected_symbols() {
	: > "$EXPECTED.raw"
	for frag in $FRAGMENTS; do
		cat "$frag" >> "$EXPECTED.raw"
	done
	awk '
		/^CONFIG_[A-Za-z0-9_]+=/ { split($0, f, "="); last[f[1]] = $0 }
		/^# CONFIG_[A-Za-z0-9_]+ is not set$/ { last[$2] = $0 }
		END { for (sym in last) print last[sym] }
	' "$EXPECTED.raw" > "$EXPECTED"
}

# A fragment line that kconfig dropped leaves the objects built from a
# configuration nobody asked for, so it is reported even though it is not a
# stale-object problem: the object set is complete, it is just not the one
# the fragments described.
verify_symbols() {
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		if ! grep -qxF "$line" "$OUT/.config"; then
			say "warning: the fragments ask for '$line' but $OUT/.config does not have it"
		fi
	done < "$EXPECTED"
}

mkdir -p "$OUT"

# A run that refuses to build must not leave the previous run's output behind
# to be mistaken for its own.
: > "$LOG"
build_started=0

cleaned=0

if [ "${CLEAN:-0}" = 1 ]; then
	if [ -d "$OUT" ]; then
		say "CLEAN=1, cleaning $OUT"
		$MAKE mrproper >/dev/null 2>&1 || true
		rm -f "$STAMP" "$MARKER" "$EXPECTED" "$EXPECTED.raw"
		# 'make mrproper' keeps the empty directory skeleton and its
		# Makefile/source stubs, so the presence of files proves nothing.
		# Only output kbuild would reuse means the clean did not happen.
		leftover=$(find "$OUT" \( -name '*.o' -o -name '.config' \
			-o -name 'vmlinux' -o -name 'System.map' \
			-o -name 'built-in.a' \) 2>/dev/null | head -n 1)
		[ -z "$leftover" ] || \
			die "$OUT still holds build output after 'make mrproper' ($leftover); remove it and rerun"
		cleaned=1
	fi
fi

if [ "$cleaned" = 1 ]; then
	fresh=1
elif [ -n "$(ls -A "$OUT" 2>/dev/null | grep -v '^\.build-check')" ]; then
	if [ ! -f "$STAMP" ]; then
		die "$OUT holds build output but no $(basename "$STAMP"), so it was not produced here from a matching configuration (a copied or hand-built tree cannot be reused); rerun with CLEAN=1"
	fi
	if [ "$(grep -v '^config ' "$STAMP")" != "$(inputs)" ]; then
		die "$OUT was built from different fragments, forced WLAN symbols or a different compiler; rerun with CLEAN=1"
	fi
	fresh=0
else
	fresh=1
fi

# shellcheck disable=SC2086
$MAKE $DEFCONFIG >> "$LOG" 2>&1

# shellcheck disable=SC2086
"$ROOT/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" \
	$FRAGMENTS >> "$LOG" 2>&1

# shellcheck disable=SC2086
$MAKE olddefconfig >> "$LOG" 2>&1

expected_symbols
verify_symbols

if [ "$fresh" = 0 ]; then
	if [ "$(sed -n 's/^config //p' "$STAMP")" != "$(cksum < "$OUT/.config")" ]; then
		die "$OUT/.config differs from the one its objects were built with; rerun with CLEAN=1"
	fi
fi

: > "$MARKER"
build_started=1

# shellcheck disable=SC2086
$MAKE -j"$JOBS" $BUILD_FLAGS $TARGETS >> "$LOG" 2>&1

# Only artefacts that exist as files can be checked directly; dtbs and
# modules are counted instead.
ARTEFACTS=""
case " $TARGETS " in
*" Image.gz "*) ARTEFACTS="$ARTEFACTS arch/arm64/boot/Image.gz" ;;
esac
case " $TARGETS " in
*" Image "*) ARTEFACTS="$ARTEFACTS arch/arm64/boot/Image" ;;
esac
case " $TARGETS " in
*" vmlinux "*) ARTEFACTS="$ARTEFACTS vmlinux" ;;
esac

if [ "$FORCE_WLAN" = 1 ]; then
	# The objects the forced symbols exist for: the CFR dispatcher, the HDD
	# CFR glue, and the direct-buffer-rx code whose HAL include previously
	# kept the whole path from compiling.
	ARTEFACTS="$ARTEFACTS \
		drivers/staging/qca-wifi-host-cmn/target_if/cfr/src/target_if_cfr_6018.o \
		drivers/staging/qca-wifi-host-cmn/target_if/direct_buf_rx/src/target_if_direct_buf_rx_api.o \
		drivers/staging/qca-wifi-host-cmn/target_if/direct_buf_rx/src/target_if_direct_buf_rx_main.o \
		drivers/staging/qcacld-3.0/core/hdd/src/wlan_hdd_cfr.o"
fi

incomplete=0

for art in $ARTEFACTS; do
	if [ ! -e "$OUT/$art" ]; then
		say "$art was not produced"
		incomplete=1
		continue
	fi
	if [ "$fresh" = 1 ] && [ ! "$OUT/$art" -nt "$MARKER" ]; then
		say "$art predates this run, so it did not come from this configuration"
		incomplete=1
		continue
	fi
	say "$art ($(wc -c < "$OUT/$art") bytes)"
done

for kind in dtb ko; do
	case " $TARGETS " in
	*" dtbs "*) [ "$kind" = dtb ] || continue ;;
	*" modules "*) [ "$kind" = ko ] || continue ;;
	*) continue ;;
	esac
	total=$(find "$OUT" -name "*.$kind" 2>/dev/null | wc -l)
	built=$(find "$OUT" -name "*.$kind" -newer "$MARKER" 2>/dev/null | wc -l)
	say "$total .$kind file(s) present, $built built by this run"
	if [ "$fresh" = 1 ] && [ "$built" -eq 0 ]; then
		say "no .$kind was produced from this configuration"
		incomplete=1
	fi
done

[ "$incomplete" = 0 ] || die "the build did not produce what was asked for"

{
	inputs
	echo "config $(cksum < "$OUT/.config")"
} > "$STAMP.tmp"
mv "$STAMP.tmp" "$STAMP"

say "targets '$TARGETS' built from the current configuration"
