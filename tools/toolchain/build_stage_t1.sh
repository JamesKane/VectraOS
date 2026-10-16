#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# LLVM for the *-vectraos triples: clang and lld, for X86, AArch64 and
# RISCV, into .cache/toolchain/out. Applies the series first if needed.

set -euo pipefail
source "$(dirname "$0")/common.sh"

for t in "$HOST_CC" "$HOST_CXX" "$HOST_LD" /usr/bin/cmake /usr/bin/ninja; do
    [[ -x "$t" ]] || die "missing host tool: $t"
done
[[ -d "$WORK/llvm-project/.git" ]] || die "llvm-project not fetched: run fetch-upstream.sh"
"$HERE/apply-patches.sh"

BUILD="$CACHE/build-llvm"
say "LLVM: -j$JOBS, links -j$LINK_JOBS (${RAM_GB} GiB)"
mkdir -p "$BUILD"
cmake -S "$WORK/llvm-project/llvm" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$OUT" \
    -DCMAKE_C_COMPILER="$HOST_CC" \
    -DCMAKE_CXX_COMPILER="$HOST_CXX" \
    -DLLVM_USE_LINKER="$HOST_LD" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64;RISCV" \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS" \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DCLANG_DEFAULT_LINKER=lld \
    -DCLANG_DEFAULT_CXX_STDLIB=libc++
ninja -C "$BUILD" -j "$JOBS" install
say "LLVM installed: $OUT/bin/clang, $OUT/bin/ld.lld; next: build_stage_t1_swift.sh"
