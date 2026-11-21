# SPDX-License-Identifier: BSD-3-Clause
#
# What the toolchain scripts share: where things are, the host tools, the
# job counts. Sourced, not run.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CACHE="${VECTRAOS_TOOLCHAIN_CACHE:-$ROOT/.cache/toolchain}"
WORK="${VECTRAOS_TOOLCHAIN_WORK:-$CACHE/work}"
OUT="$CACHE/out"
PATCHES="$HERE/patches"

# The triples: croi's three machines.
TRIPLES=(x86_64-unknown-vectraos aarch64-unknown-vectraos riscv64-unknown-vectraos)

# The host: Linux (brimstone, Fedora x86_64) or macOS (Apple silicon). Every
# host-tool assumption of the scripts lives here; the target side (the
# sysroot, the stdlib, Foundation, libc++ for vectraos) is host-independent.
#
#   HOST_CC, HOST_CXX   the host compiler that builds LLVM and Swift
#   HOST_LD_ARGS        LLVM_USE_LINKER for them: lld on Linux, none on macOS
#                       (the system's ld64 links host binaries; the installed
#                       toolchain's ld.lld is built from our LLVM either way)
#   HOST_CMAKE, HOST_NINJA
#   HOST_SWIFT_BIN      the host Swift that builds the compiler (hosttools
#                       bootstrapping); it needn't be the Swift being built
#   HOST_SWIFT_OS_DIR   its runtime libraries' directory under lib/swift
#   SWIFT_HOST_ARGS     Swift's CMake variables naming the host platform
#   HOST_SDKROOT        macOS: the SDK host code builds against
#   DARWIN              1 on macOS
#   SHLIB_EXT           the host's shared library suffix
#   READELF, NM         LLVM's, for the smoke scripts
#   JOBS, RAM_GB, LINK_JOBS
case "$(uname -s)" in
Linux)
    # The host's LLVM builds ours (Fedora's clang 22).
    HOST_CC=/usr/bin/clang-22
    HOST_CXX=/usr/bin/clang++-22
    HOST_LD_ARGS=(-DLLVM_USE_LINKER=/usr/bin/ld.lld-22)
    HOST_CMAKE_ARGS=()
    HOST_CMAKE=/usr/bin/cmake
    HOST_NINJA=/usr/bin/ninja
    # 6.3.1, as swift-on-vectra built 6.4.0 with.
    HOST_SWIFT_VERSION=${HOST_SWIFT_VERSION:-6.3.1}
    HOST_SWIFT_BIN="$HOME/.local/share/swiftly/toolchains/$HOST_SWIFT_VERSION/usr/bin"
    HOST_SWIFT_OS_DIR=linux
    SWIFT_HOST_ARGS=(-DSWIFT_HOST_VARIANT=linux -DSWIFT_HOST_VARIANT_SDK=LINUX -DSWIFT_HOST_VARIANT_ARCH=x86_64)
    SHLIB_EXT=so
    DARWIN=0
    READELF=/usr/bin/llvm-readelf
    NM=/usr/bin/llvm-nm
    JOBS=${JOBS:-$(nproc)}
    RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
    ;;
Darwin)
    # Xcode's clang, not the host Swift toolchain's: it is the compiler the
    # macOS SDK and its libc++ are made for, and Apple builds Swift with it.
    # The system linker (ld64) links the host's binaries, so LLVM_USE_LINKER
    # stays unset; the installed ld.lld is ours, built as any LLVM tool.
    HOST_CC=$(xcrun --find clang)
    HOST_CXX=$(xcrun --find clang++)
    HOST_LD_ARGS=()
    HOST_CMAKE=$(command -v cmake || true)
    HOST_NINJA=$(command -v ninja || true)
    # An open-source 6.3.x, which swiftly keeps with Xcode's toolchains; not
    # Xcode's own Swift (6.4 here): as on Linux, the compiler under build
    # is built by an older one.
    HOST_SWIFT_VERSION=${HOST_SWIFT_VERSION:-6.3.2}
    HOST_SWIFT_BIN="$HOME/Library/Developer/Toolchains/swift-$HOST_SWIFT_VERSION-RELEASE.xctoolchain/usr/bin"
    HOST_SWIFT_OS_DIR=macosx
    SWIFT_HOST_ARGS=(-DSWIFT_HOST_VARIANT=macosx -DSWIFT_HOST_VARIANT_SDK=OSX "-DSWIFT_HOST_VARIANT_ARCH=$(uname -m)")
    SHLIB_EXT=dylib
    DARWIN=1
    READELF="$OUT/bin/llvm-readelf"
    NM="$OUT/bin/llvm-nm"
    JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
    RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    # The macOS SDK that host code (LLVM, the compiler) builds against; only
    # the host builds export it (the target builds name their own sysroot).
    HOST_SDKROOT=$(xcrun --show-sdk-path)
    # What the host binaries run on: one deployment target for LLVM, cmark
    # and the compiler (Swift's own default is 13.0, LLVM's is the SDK's, so
    # linking the two warned "built for newer macOS"), and no zstd, which
    # only Homebrew has: the built tools then link the system's libraries
    # alone (libSystem, libc++, libz, libxml2, libedit) and move to any Mac.
    DARWIN_DEPLOYMENT_TARGET=${DARWIN_DEPLOYMENT_TARGET:-13.0}
    HOST_CMAKE_ARGS=("-DCMAKE_OSX_DEPLOYMENT_TARGET=$DARWIN_DEPLOYMENT_TARGET"
        "-DSWIFT_DARWIN_DEPLOYMENT_VERSION_OSX=$DARWIN_DEPLOYMENT_TARGET" -DLLVM_ENABLE_ZSTD=OFF)
    ;;
*)
    echo "vectraos: toolchain: unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

LINK_JOBS=${LINK_JOBS:-$(( RAM_GB / 6 ))}   # an LLVM or Swift link takes several GiB
(( LINK_JOBS < 1 )) && LINK_JOBS=1
(( LINK_JOBS > JOBS )) && LINK_JOBS=$JOBS

# CMake variables for a build of the target by our compiler (the stdlib's,
# Foundation's): TARGET_CMAKE_ARGS, and TARGET_SWIFT_HOST_ARGS for Swift's
# own host-variant variables. On Linux, the same as for the host builds.
#
# On macOS, CMake adds -arch and, from Swift's host variant (OSX), -isysroot
# <the macOS SDK> to every compile, ahead of the target's sysroot, so the
# macOS headers are what vectraos code sees. The build is a cross build, so
# it is told it runs on Linux, as brimstone's does: CMAKE_SYSTEM_NAME and
# Swift's Linux host variant. The host tools it runs (swift-frontend, clang)
# come from OUT/bin by their own variables. A cross build no longer finds,
# through the SDK, the zlib, zstd, libxml2 and libedit that our macOS LLVM's
# CMake config looks for (the stdlib's configure reads it): say where they
# are.
target_cmake_args() {
    TARGET_CMAKE_ARGS=()
    TARGET_SWIFT_HOST_ARGS=("${SWIFT_HOST_ARGS[@]}")
    if (( DARWIN )); then
        TARGET_SWIFT_HOST_ARGS=(-DSWIFT_HOST_VARIANT=linux -DSWIFT_HOST_VARIANT_SDK=LINUX "-DSWIFT_HOST_VARIANT_ARCH=$(uname -m | sed s/arm64/aarch64/)")
        TARGET_CMAKE_ARGS=(-DCMAKE_SYSTEM_NAME=Linux
            "-DZLIB_LIBRARY=$HOST_SDKROOT/usr/lib/libz.tbd" "-DZLIB_INCLUDE_DIR=$HOST_SDKROOT/usr/include"
            "-DLIBXML2_LIBRARY=$HOST_SDKROOT/usr/lib/libxml2.tbd" "-DLIBXML2_INCLUDE_DIR=$HOST_SDKROOT/usr/include/libxml2"
            "-DLibEdit_LIBRARIES=$HOST_SDKROOT/usr/lib/libedit.tbd" "-DLibEdit_INCLUDE_DIRS=$HOST_SDKROOT/usr/include")
    fi
}

say() { echo "vectraos: toolchain: $*"; }
die() { echo "vectraos: toolchain: $*" >&2; exit 1; }

# component  work-subdir: the series, by component.
COMPONENTS=("llvm llvm-project" "swift swift" "swift-driver swift-driver" "swift-foundation swift-foundation")
