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
#   OUT=/path      out-of-tree build directory  (default: .build-check)
#   CROSS_COMPILE= compiler prefix              (default: .toolchains/...)
#   JOBS=n         parallel build jobs          (default: nproc)
#   FRAGMENTS="..." config fragments, space separated, later ones win
#                  (default: Z01R-check.config)
#   CLEAN=1        clean $OUT before configuring it
#
# Exit status is 0 only when every requested target was produced from the
# configuration this run checked.

set -eu

STAMP_FORMAT=1

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

if [ "${CLEAN:-0}" = 1 ]; then
	if [ -d "$OUT" ]; then
		say "CLEAN=1, cleaning $OUT"
		$MAKE mrproper >/dev/null 2>&1 || true
		rm -f "$STAMP" "$MARKER" "$EXPECTED" "$EXPECTED.raw"
		[ -z "$(ls -A "$OUT" 2>/dev/null | grep -v '^\.build-check')" ] || \
			die "$OUT still holds files after 'make mrproper'; remove it and rerun"
	fi
fi

if [ -n "$(ls -A "$OUT" 2>/dev/null | grep -v '^\.build-check')" ]; then
	if [ ! -f "$STAMP" ]; then
		die "$OUT holds build output but no $(basename "$STAMP"), so it was not produced here from a matching configuration (a copied or hand-built tree cannot be reused); rerun with CLEAN=1"
	fi
	if [ "$(grep -v '^config ' "$STAMP")" != "$(inputs)" ]; then
		die "$OUT was built from different fragments or a different compiler; rerun with CLEAN=1"
	fi
	fresh=0
else
	fresh=1
fi

# shellcheck disable=SC2086
$MAKE defconfig >> "$LOG" 2>&1

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
$MAKE -j"$JOBS" $TARGETS >> "$LOG" 2>&1

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
