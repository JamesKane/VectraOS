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

# The host's LLVM builds ours (Fedora's clang 22).
HOST_CC=/usr/bin/clang-22
HOST_CXX=/usr/bin/clang++-22
HOST_LD=/usr/bin/ld.lld-22

# The host Swift that builds the compiler (hosttools bootstrapping); it
# needn't be the Swift being built. 6.3.1, as swift-on-vectra built 6.4.0
# with.
HOST_SWIFT_VERSION=${HOST_SWIFT_VERSION:-6.3.1}
HOST_SWIFT_BIN="$HOME/.local/share/swiftly/toolchains/$HOST_SWIFT_VERSION/usr/bin"

JOBS=${JOBS:-$(nproc)}
RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
LINK_JOBS=${LINK_JOBS:-$(( RAM_GB / 6 ))}   # an LLVM or Swift link takes several GiB
(( LINK_JOBS < 1 )) && LINK_JOBS=1
(( LINK_JOBS > JOBS )) && LINK_JOBS=$JOBS

say() { echo "vectraos: toolchain: $*"; }
die() { echo "vectraos: toolchain: $*" >&2; exit 1; }

# component  work-subdir: the series, by component.
COMPONENTS=("llvm llvm-project" "swift swift" "swift-driver swift-driver" "swift-foundation swift-foundation")
