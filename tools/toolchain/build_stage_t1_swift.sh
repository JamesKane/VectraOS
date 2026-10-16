#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# The Swift compiler (swift-frontend), against our LLVM, into
# .cache/toolchain/out: the compiler, its host libraries, the SwiftShims
# headers and libSwiftScan, nothing of the stdlib (that is M6e). Adapted
# from swift-on-vectra's build_stage_t1_swift.sh.

set -euo pipefail
source "$(dirname "$0")/common.sh"

for d in swift cmark swift-syntax swift-experimental-string-processing; do
    [[ -d "$WORK/$d/.git" ]] || die "$d not fetched: run fetch-upstream.sh"
done
BUILD_LLVM="$CACHE/build-llvm"
BUILD="$CACHE/build-swift"
[[ -d "$BUILD_LLVM/lib/cmake/llvm" ]] || die "no LLVM build: run build_stage_t1.sh"

# The concrete host toolchain, not swiftly's shim: Swift's CMake runs
# `swiftly use --print-location` for a swiftc under swiftly/bin and fails on
# anything swiftly prints to stderr.
[[ -x "$HOST_SWIFT_BIN/swiftc" ]] || die "host Swift $HOST_SWIFT_VERSION not installed (swiftly install $HOST_SWIFT_VERSION)"
export PATH="$HOST_SWIFT_BIN:$PATH"
say "Swift: hosttools with $(swiftc --version 2>&1 | head -1); -j$JOBS, links -j$LINK_JOBS"

# Swift's lib/Option reads clang's features.json from LLVM's build tree.
mkdir -p "$BUILD_LLVM/share/clang"
[[ -f "$BUILD_LLVM/share/clang/features.json" ]] || echo '{"features": []}' > "$BUILD_LLVM/share/clang/features.json"

# cmark first: Swift's configure reads its exported targets.
if [[ ! -f "$BUILD/cmark/src/cmarkTargets.cmake" ]]; then
    mkdir -p "$BUILD/cmark"
    cmake -S "$WORK/cmark" -B "$BUILD/cmark" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$HOST_CC" -DCMAKE_CXX_COMPILER="$HOST_CXX" -DCMARK_TESTS=OFF
    ninja -C "$BUILD/cmark" -j "$JOBS"
fi

cmake -S "$WORK/swift" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$OUT" \
    -DCMAKE_C_COMPILER="$HOST_CC" \
    -DCMAKE_CXX_COMPILER="$HOST_CXX" \
    -DLLVM_USE_LINKER="$HOST_LD" \
    -DLLVM_DIR="$BUILD_LLVM/lib/cmake/llvm" \
    -DClang_DIR="$BUILD_LLVM/lib/cmake/clang" \
    -DSWIFT_PATH_TO_CMARK_SOURCE="$WORK/cmark" \
    -DSWIFT_PATH_TO_CMARK_BUILD="$BUILD/cmark" \
    -DSWIFT_PATH_TO_SWIFT_SYNTAX_SOURCE="$WORK/swift-syntax" \
    -DSWIFT_PATH_TO_STRING_PROCESSING_SOURCE="$WORK/swift-experimental-string-processing" \
    -DSWIFT_INCLUDE_TOOLS=ON \
    -DSWIFT_BUILD_SWIFT_SYNTAX=ON \
    -DSWIFT_BUILD_DYNAMIC_STDLIB=ON \
    -DSWIFT_BUILD_STATIC_STDLIB=OFF \
    -DSWIFT_BUILD_REMOTE_MIRROR=OFF \
    -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_CLANG_OVERLAYS=OFF \
    -DSWIFT_BUILD_SOURCEKIT=OFF \
    -DSWIFT_BUILD_LIBEXEC=OFF \
    -DSWIFT_BUILD_STDLIB_EXTRA_TOOLCHAIN_CONTENT=OFF \
    -DSWIFT_BUILD_REGEX_PARSER_IN_COMPILER=ON \
    -DSWIFT_INCLUDE_TESTS=OFF \
    -DSWIFT_INCLUDE_TEST_BINARIES=OFF \
    -DSWIFT_INCLUDE_DOCS=OFF \
    -DSWIFT_INCLUDE_APINOTES=OFF \
    -DSWIFT_ENABLE_DISPATCH=OFF \
    -DSWIFT_HOST_VARIANT=linux \
    -DSWIFT_HOST_VARIANT_SDK=LINUX \
    -DSWIFT_HOST_VARIANT_ARCH=x86_64 \
    -DSWIFT_STDLIB_ASSERTIONS=OFF \
    -DLLVM_ENABLE_ASSERTIONS=ON \
    -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS" \
    -DSWIFT_TOOLS_ENABLE_LTO=OFF \
    -DBOOTSTRAPPING_MODE=HOSTTOOLS \
    -DSWIFT_SHOULD_BUILD_EMBEDDED_STDLIB=OFF \
    -DSWIFT_ENABLE_VOLATILE=ON \
    -DSWIFT_ENABLE_SYNCHRONIZATION=ON \
    -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY=ON \
    -DSWIFT_CONCURRENCY_GLOBAL_EXECUTOR=hooked

# Only what's needed: `ninja install` would build the hosted Linux stdlib.
ninja -C "$BUILD" -j "$JOBS" swift-frontend copy_shim_headers libSwiftScan

mkdir -p "$OUT/bin" "$OUT/lib/swift/host" "$OUT/lib/swift/linux" "$OUT/lib/swift/shims"
cp -a "$BUILD/bin/swift-frontend" "$OUT/bin/"
ln -sf swift-frontend "$OUT/bin/swift-autolink-extract"
ln -sf swift-frontend "$OUT/bin/swift-api-digester"
driver=swift-frontend
[[ -x "$OUT/bin/swift-driver" ]] && driver=swift-driver
for tool in swift swiftc; do ln -sf "$driver" "$OUT/bin/$tool"; done
cp -a "$BUILD/lib/swift/host/." "$OUT/lib/swift/host/"
cp -a "$BUILD/lib/lib_InternalSwiftScan.so" "$OUT/lib/swift/host/"
cp -a "$BUILD/lib/swift/shims/." "$OUT/lib/swift/shims/"
# The host's Swift libraries, which swift-frontend itself runs on.
cp -a "$HOST_SWIFT_BIN/../lib/swift/linux/." "$OUT/lib/swift/linux/"
say "Swift installed: $OUT/bin/swift-frontend; next: build_stage_t1_driver.sh"
