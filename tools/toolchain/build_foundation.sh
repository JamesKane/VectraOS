#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# FoundationEssentials for the *-vectraos triples (M6g): swift-foundation
# built essentials-only (no ICU, nothing fetched) by our compiler and clang
# against tier 1's sysroot, after build_stdlib.sh, and installed into the
# sysroot beside the stdlib (usr/lib/swift_static: the modules, the
# archives under vectraos/<arch>/), where swiftc finds
# `import FoundationEssentials`. Its files go through our libc's POSIX calls,
# which fdio (system/fdio) serves in a tier 1 program. Adapted from
# swift-on-vectra's build_foundation.sh. Builds in build/foundation-<arch>/,
# the tree's own (it is configured for this tree's sysroot, and worktrees
# share .cache/toolchain). Its C is position-independent, so link_shared.sh
# can make shared libraries of the archives too (D124).
#
#   tools/toolchain/build_foundation.sh [ARCH]      # x86_64 (default)

set -euo pipefail
source "$(dirname "$0")/common.sh"

ARCH=${1:-x86_64}
case $ARCH in
    x86_64) NATIVE=amd64 ;;
    aarch64) NATIVE=arm64 ;;
    riscv64) NATIVE=rv64 ;;
    *) die "no such machine: $ARCH" ;;
esac
T="$ARCH-unknown-vectraos"
SYSROOT="$ROOT/build/$NATIVE/sysroot"
RES="$SYSROOT/usr/lib/swift_static"
BUILD="$ROOT/build/foundation-$ARCH"
# Foundation's macros (#Predicate, #Expression) run in the compiler, on the
# host: FoundationEssentials only declares them, so the build expands none.
MACROS="$HOME/.local/share/swiftly/toolchains/${HOST_SWIFT_VERSION}/usr/lib/swift/host/plugins"
[[ -d "$MACROS" ]] || MACROS=/nonexistent

[[ -f "$RES/vectraos/$ARCH/libswiftCore.a" ]] || die "no stdlib in $RES: run build_stdlib.sh"

mkdir -p "$BUILD"
if [[ ! -f "$BUILD/build.ninja" || "$0" -nt "$BUILD/configured" ]]; then
say "foundation: configuring for $T"
cmake -S "$WORK/swift-foundation" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
    -DCMAKE_C_COMPILER="$OUT/bin/clang" \
    -DCMAKE_C_COMPILER_TARGET="$T" \
    -DCMAKE_Swift_COMPILER="$OUT/bin/swiftc" \
    -DCMAKE_Swift_COMPILER_TARGET="$T" \
    -DCMAKE_Swift_FLAGS="-sdk $SYSROOT -resource-dir $RES -tools-directory $OUT/bin -DNO_C_LOCALE -DNO_LOCALIZATION -DNO_TZFILE" \
    -DCMAKE_C_FLAGS="--sysroot=$SYSROOT -fPIC -ftls-model=initial-exec" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DBUILD_SHARED_LIBS=NO \
    -DSWIFTFOUNDATION_ESSENTIALS_ONLY=YES \
    -D_SwiftCollections_SourceDIR="$WORK/swift-collections" \
    -DSwiftFoundation_MACRO="$MACROS" \
    > "$BUILD/configure.log" 2>&1 \
    || { tail -20 "$BUILD/configure.log" >&2; rm -f "$BUILD/build.ninja"; die "foundation: configure failed, see $BUILD/configure.log"; }
touch "$BUILD/configured"
fi

ninja -C "$BUILD" -k 0 -j "$JOBS" FoundationEssentials > "$BUILD/build.log" 2>&1 \
    || { grep -m40 -E "error:|FAILED" "$BUILD/build.log" >&2; die "foundation: build failed, see $BUILD/build.log"; }

# Into the sysroot: the archives beside the runtime's, each module as
# <Module>.swiftmodule, and _FoundationCShims, which FoundationEssentials
# imports, as a clang module swiftc finds there.
cmake -E copy_if_different "$BUILD"/lib/lib{FoundationEssentials,_FoundationCShims,_FoundationCollections}.a "$RES/vectraos/$ARCH/"
for m in FoundationEssentials _FoundationCollections; do
    cmake -E copy_directory_if_different "$BUILD/swift/$m.swiftmodule" "$RES/vectraos/$m.swiftmodule" 2>/dev/null \
        || cmake -E copy_if_different "$BUILD/swift/$m.swiftmodule" "$RES/vectraos/"
done
# At the resource directory's top, beside shims, as Linux's toolchain has it.
rm -rf "$RES/vectraos/_FoundationCShims"
cmake -E copy_directory_if_different "$WORK/swift-foundation/Sources/_FoundationCShims/include" "$RES/_FoundationCShims"
