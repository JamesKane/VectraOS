#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# compiler-rt's builtins for the *-vectraos triples: the routines clang
# calls for what a machine lacks (128-bit division, soft float conversions,
# outlined atomics), from the pinned llvm-project's compiler-rt/lib/builtins,
# built freestanding by our clang. They replace Swift 6.4.0's prebuilt
# x86_64 Linux archive, which only amd64 had (D4: nothing third-party on the
# device), so the three machines get theirs the same way. Minutes, not hours.
#
#   tools/toolchain/build_builtins.sh [TRIPLE...]   # all three by default
#
# Installs each into the toolchain's resource directory,
# out/lib/clang/<version>/lib/<triple>/libclang_rt.builtins.a, from where
# cmake/Tier1.cmake copies it into the arch's sysroot (the driver links
# -lclang_rt.builtins from there, patch llvm 0003).

set -euo pipefail
source "$(dirname "$0")/common.sh"

[[ -x "$OUT/bin/clang" ]] || die "no clang: run build_stage_t1.sh"
SRC="$WORK/llvm-project/compiler-rt/lib/builtins"
[[ -d "$SRC" ]] || die "no compiler-rt sources at $SRC: run fetch-upstream.sh"
VERSION=$("$OUT/bin/clang" -dumpversion)
VERSION=${VERSION%%.*}

for triple in "${@:-${TRIPLES[@]}}"; do
    BUILD="$CACHE/build-builtins-$triple"
    DEST="$OUT/lib/clang/$VERSION/lib/$triple"
    mkdir -p "$BUILD" "$DEST" "$CACHE/empty-sysroot"
    # riscv64 has no 16-byte compare-and-swap below Zacas, which RVA22
    # lacks, so the Swift runtime's 16-byte atomics (side-table refcounts,
    # task status) are calls: atomic.c's __atomic_*, spinlocks hashed by
    # address. A program links them once and its shared libraries bind to
    # its copy, so one lock table guards an object wherever it's touched.
    # x86_64 and aarch64 inline theirs.
    atomics=ON
    [[ $triple == riscv64-* ]] && atomics=OFF
    if [[ ! -f "$BUILD/build.ninja" || "$0" -nt "$BUILD/configured" ]]; then
        say "builtins: configuring for $triple"
        # Freestanding (BAREMETAL) over an empty sysroot, so the host's
        # headers never come in: clang's own headers, then our libc's
        # (cpu_model includes <assert.h>), not a tree's sysroot, which is
        # built after this.
        CFLAGS="-ffreestanding -fno-omit-frame-pointer -idirafter $ROOT/system/libc/include"
        cmake -S "$SRC" -B "$BUILD" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_SYSTEM_NAME=Generic \
            -DCMAKE_C_COMPILER="$OUT/bin/clang" \
            -DCMAKE_CXX_COMPILER="$OUT/bin/clang++" \
            -DCMAKE_ASM_COMPILER="$OUT/bin/clang" \
            -DCMAKE_CXX_COMPILER_TARGET="$triple" \
            -DCMAKE_C_COMPILER_TARGET="$triple" \
            -DCMAKE_ASM_COMPILER_TARGET="$triple" \
            -DCMAKE_AR="$OUT/bin/llvm-ar" \
            -DCMAKE_RANLIB="$OUT/bin/llvm-ranlib" \
            -DCMAKE_NM="$OUT/bin/llvm-nm" \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
            -DCMAKE_C_FLAGS="$CFLAGS" \
            -DCMAKE_CXX_FLAGS="$CFLAGS" \
            -DCMAKE_ASM_FLAGS="-ffreestanding" \
            -DCMAKE_SYSROOT="$CACHE/empty-sysroot" \
            -DLLVM_CMAKE_DIR="$WORK/llvm-project/llvm/cmake/modules" \
            -DCOMPILER_RT_BAREMETAL_BUILD=ON \
            -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
            -DCOMPILER_RT_BUILTINS_HIDE_SYMBOLS=OFF \
            -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=$atomics \
            -DCOMPILER_RT_OS_DIR="" \
            > "$BUILD/configure.log" 2>&1 \
            || { tail -30 "$BUILD/configure.log" >&2; rm -f "$BUILD/build.ninja"; die "builtins: configure failed, see $BUILD/configure.log"; }
        touch "$BUILD/configured"
    fi
    ninja -C "$BUILD" -j "$JOBS" > "$BUILD/build.log" 2>&1 \
        || { grep -m40 -E "error:|FAILED" "$BUILD/build.log" >&2; die "builtins: build failed, see $BUILD/build.log"; }
    # The triple's machine by name: a configure gone wrong builds the host's.
    archive=$(find "$BUILD" -name "libclang_rt.builtins-${triple%%-*}.a" | head -1)
    [[ -n "$archive" ]] || die "builtins: no archive for $triple in $BUILD"
    cmake -E copy_if_different "$archive" "$DEST/libclang_rt.builtins.a"
    say "builtins: $triple: $DEST/libclang_rt.builtins.a"
done
