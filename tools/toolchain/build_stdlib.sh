#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# The Swift standard library and runtime for the *-vectraos triples (M6e):
# static libraries built by our compiler and clang against tier 1's
# sysroot (the arch tree's: build/<arch>/sysroot, the floor
# as libsys.a, our libc with its pthreads, libc++), with the pthreads
# threading package over our pthreads. No backtracer, dladdr, locale, file
# system or stdin in the runtime; Synchronization's Mutex over croi's
# futexes, and Concurrency with VectraOS's global and main executors
# (M6f: threads sleeping on croi ports, through the floor's td_floor.h),
# and Observation over our pthreads (M6g: FoundationEssentials needs it).
#
#   tools/toolchain/build_stdlib.sh [ARCH]      # x86_64 (default)
#
# Writes build/stdlib-<arch>/ (the tree's own: it is configured for this
# tree's sysroot, and worktrees share .cache/toolchain) and installs the runtime
# into the sysroot's usr/lib/swift_static (modules, archives, swiftrt.o and
# static-executable-args.lnk), where swiftc finds them with
#   swiftc -target ARCH-unknown-vectraos -sdk SYSROOT -resource-dir SYSROOT/usr/lib/swift_static
# Rebuild after a change to our libc's headers: the runtime's layouts are
# theirs.

set -euo pipefail
source "$(dirname "$0")/common.sh"

ARCH=${1:-x86_64}
case $ARCH in
    x86_64) NATIVE=amd64 ;;
    aarch64) NATIVE=arm64 ;;
    riscv64) NATIVE=rv64 ;;
    *) die "no such machine: $ARCH" ;;
esac
SYSROOT="$ROOT/build/$NATIVE/sysroot"
BUILD="$ROOT/build/stdlib-$ARCH"
BUILD_LLVM="$CACHE/build-llvm"

[[ -x "$OUT/bin/swift-frontend" && -x "$OUT/bin/clang" ]] || die "no toolchain: run the stage builds first"
[[ -f "$SYSROOT/usr/lib/libc++.a" && -f "$SYSROOT/usr/include/module.modulemap" ]] ||
    die "no sysroot with libc++ at $SYSROOT: build the tree (cmake --build build/$NATIVE)"
[[ -x "$HOST_SWIFT_BIN/swiftc" ]] && export PATH="$HOST_SWIFT_BIN:$PATH"

mkdir -p "$BUILD"
# Configured when this script's settings change (ninja reconfigures by
# itself when the tree's CMake does).
if [[ ! -f "$BUILD/build.ninja" || "$0" -nt "$BUILD/configured" ]]; then
say "stdlib: configuring for $ARCH-unknown-vectraos"
cmake -S "$WORK/swift" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$OUT/bin/clang" \
    -DCMAKE_CXX_COMPILER="$OUT/bin/clang++" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DLLVM_FORCE_USE_OLD_TOOLCHAIN=ON \
    -DLLVM_USE_LINKER="$OUT/bin/ld.lld" \
    -DLLVM_DIR="$BUILD_LLVM/lib/cmake/llvm" \
    -DClang_DIR="$BUILD_LLVM/lib/cmake/clang" \
    -DSWIFT_INCLUDE_TOOLS=OFF \
    -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$OUT/bin" \
    -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$OUT/bin" \
    -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$OUT/bin" \
    -DSWIFT_HOST_VARIANT=linux \
    -DSWIFT_HOST_VARIANT_SDK=LINUX \
    -DSWIFT_HOST_VARIANT_ARCH=x86_64 \
    -DSWIFT_SDKS=VECTRAOS \
    -DSWIFT_SDK_VECTRAOS_ARCHITECTURES="$ARCH" \
    -DSWIFT_VECTRAOS_${ARCH}_SYSROOT_PATH="$SYSROOT" \
    -DSWIFT_PRIMARY_VARIANT_SDK=VECTRAOS \
    -DSWIFT_PRIMARY_VARIANT_ARCH="$ARCH" \
    -DSWIFT_BUILD_DYNAMIC_STDLIB=OFF \
    -DSWIFT_BUILD_STATIC_STDLIB=ON \
    -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_STATIC_SDK_OVERLAY=ON \
    -DSWIFT_BUILD_CLANG_OVERLAYS=OFF \
    -DSWIFT_BUILD_REMOTE_MIRROR=OFF \
    -DSWIFT_BUILD_SWIFT_SYNTAX=OFF \
    -DSWIFT_INCLUDE_TESTS=OFF \
    -DSWIFT_INCLUDE_TEST_BINARIES=OFF \
    -DSWIFT_INCLUDE_DOCS=OFF \
    -DSWIFT_ENABLE_DISPATCH=OFF \
    -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY=ON \
    -DSWIFT_CONCURRENCY_GLOBAL_EXECUTOR=vectraos \
    -DSWIFT_ENABLE_EXPERIMENTAL_STRING_PROCESSING=ON \
    -DSWIFT_PATH_TO_STRING_PROCESSING_SOURCE="$WORK/swift-experimental-string-processing" \
    -DSWIFT_ENABLE_EXPERIMENTAL_DISTRIBUTED=OFF \
    -DSWIFT_ENABLE_EXPERIMENTAL_DIFFERENTIABLE_PROGRAMMING=OFF \
    -DSWIFT_ENABLE_EXPERIMENTAL_OBSERVATION=ON \
    -DSWIFT_ENABLE_SYNCHRONIZATION=ON \
    -DSWIFT_ENABLE_VOLATILE=OFF \
    -DSWIFT_ENABLE_RUNTIME_MODULE=OFF \
    -DSWIFT_ENABLE_BACKTRACING=OFF \
    -DSWIFT_STDLIB_SUPPORTS_BACKTRACE_REPORTING=OFF \
    -DSWIFT_STDLIB_BUILD_PRIVATE=OFF \
    -DSWIFT_STDLIB_ASSERTIONS=OFF \
    -DSWIFT_STDLIB_HAS_ASL=OFF \
    -DSWIFT_STDLIB_HAS_LOCALE=OFF \
    -DSWIFT_STDLIB_HAS_DLADDR=OFF \
    -DSWIFT_STDLIB_HAS_DLSYM=OFF \
    -DSWIFT_STDLIB_HAS_FILESYSTEM=OFF \
    -DSWIFT_STDLIB_HAS_STDIN=OFF \
    -DSWIFT_STDLIB_HAS_ENVIRON=ON \
    -DSWIFT_STDLIB_HAS_COMMANDLINE=ON \
    -DSWIFT_STDLIB_OS_VERSIONING=OFF \
    -DSWIFT_STDLIB_TRACING=OFF \
    -DSWIFT_STDLIB_CONCURRENCY_TRACING=OFF \
    -DSWIFT_ENABLE_MODULE_INTERFACES=ON \
    -DSWIFT_STDLIB_ENABLE_SIB_TARGETS=OFF \
    -DSWIFT_THREADING_PACKAGE="VECTRAOS:pthreads" \
    -DSWIFT_STDLIB_EXTRA_SWIFT_COMPILE_FLAGS="-Xfrontend;-function-sections" \
    -DSWIFT_STDLIB_EXTRA_C_COMPILE_FLAGS="-ffunction-sections;-fdata-sections" \
    -DBOOTSTRAPPING_MODE=CROSSCOMPILE > "$BUILD/configure.log" 2>&1 \
    || { tail -30 "$BUILD/configure.log" >&2; rm -f "$BUILD/build.ninja"; die "stdlib: configure failed, see $BUILD/configure.log"; }
touch "$BUILD/configured"
fi

# The libraries (static), the static link's arguments, and swiftrt.o, which
# registers a program's metadata sections with the runtime.
TARGETS=$(ninja -C "$BUILD" -t targets all 2>/dev/null |
    sed -n "s/^\(swift[A-Za-z_]*-vectraos-$ARCH-static\): phony\$/\1/p" | sort -u)
ninja -C "$BUILD" -j "$JOBS" -k 0 $TARGETS static_binary_magic "lib-swift-vectraos-$ARCH-swiftrt.o" \
    > "$BUILD/build.log" 2>&1 \
    || { grep -m40 -E "error:|FAILED" "$BUILD/build.log" >&2; die "stdlib: build failed, see $BUILD/build.log"; }

# Into the sysroot, what changed: Linux's layout, which the drivers search.
DEST="$SYSROOT/usr/lib/swift_static"
mkdir -p "$DEST/vectraos/$ARCH"
cmake -E copy_directory_if_different "$BUILD/lib/swift_static" "$DEST"
cmake -E copy_if_different "$BUILD/lib/swift/vectraos/$ARCH/swiftrt.o" "$DEST/vectraos/$ARCH/"
