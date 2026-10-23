#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# The Swift runtime, standard library and FoundationEssentials as shared
# libraries (D124), linked from the static archives build_stdlib.sh and
# build_foundation.sh install, which are position-independent with their
# TLS by initial-exec: each archive whole, with swiftrt.o to register its
# metadata, as lib<name>.so, needing those linked before it that it uses
# (--as-needed: an autolink entry doesn't name an implementation-only
# import, FoundationEssentials' of its C shims) and noting their build
# IDs (vx library-note). What they use of the
# floor, the libc and libc++ they take from the program, which links those
# statically (cmake/Tier1.cmake). The runtime's threading layer is hidden
# in libswiftCore, so each other library gets its own copy of what it uses
# of it, as Swift's own shared build gives them: Core's Pthreads and
# ThreadingError objects, as an archive. A library is relinked when its
# archive, a library it needs or this script is newer.
#
#   tools/toolchain/link_shared.sh ARCH DIR     # into DIR/lib<name>.so

set -euo pipefail
source "$(dirname "$0")/common.sh"

ARCH=${1:?arch}
DEST=${2:?directory}
case $ARCH in
    x86_64) NATIVE=amd64 ;;
    aarch64) NATIVE=arm64 ;;
    *) die "no shared runtime for $ARCH" ;;
esac
STATIC="$ROOT/build/$NATIVE/sysroot/usr/lib/swift_static/vectraos/$ARCH"
VX="$ROOT/.build/debug/vx"
[[ -f "$STATIC/libswiftCore.a" ]] || die "no runtime at $STATIC: build_stdlib.sh first"
[[ -x "$VX" ]] || die "no vx at $VX"
mkdir -p "$DEST"

# The threading layer, from Core's archive.
THREADING="$DEST/threading.a"
if [[ ! $THREADING -nt "$STATIC/libswiftCore.a" ]]; then
    rm -rf "$DEST/threading" "$THREADING"
    mkdir -p "$DEST/threading"
    (cd "$DEST/threading" && "$OUT/bin/llvm-ar" x "$STATIC/libswiftCore.a" Pthreads.cpp.o ThreadingError.cpp.o)
    "$OUT/bin/llvm-ar" rcs "$THREADING" "$DEST/threading/Pthreads.cpp.o" "$DEST/threading/ThreadingError.cpp.o"
fi

# Each after those it may need.
LIBS=(swiftCore swift_Builtin_float swiftSynchronization swift_Concurrency swift_RegexParser
      swift_StringProcessing swiftRegexBuilder swiftObservation swiftVectraOSLibc swiftSwiftOnoneSupport
      _FoundationCShims _FoundationCollections FoundationEssentials)
for lib in "${LIBS[@]}"; do
    archive="$STATIC/lib$lib.a"
    [[ -f $archive ]] || continue
    so="$DEST/lib$lib.so"
    needs=()
    for l in "${LIBS[@]}"; do
        [[ $l == "$lib" ]] && break
        [[ -f "$DEST/lib$l.so" ]] && needs+=("$DEST/lib$l.so")
    done
    stale=0
    [[ $so -nt $archive && $so -nt "$STATIC/swiftrt.o" && $so -nt $THREADING && $so -nt "$0" ]] || stale=1
    for n in "${needs[@]}"; do [[ $so -nt $n ]] || stale=1; done
    ((stale)) || continue
    note=()
    if ((${#needs[@]})); then
        "$VX" library-note "$DEST/lib$lib-libraries.c" "${needs[@]}"
        "$OUT/bin/clang" --target="$ARCH-unknown-vectraos" -c "$DEST/lib$lib-libraries.c" -o "$DEST/lib$lib-libraries.o"
        note=("$DEST/lib$lib-libraries.o")
    fi
    threading=()
    [[ $lib == swiftCore ]] || threading=("$THREADING")
    "$OUT/bin/ld.lld" -shared -soname "lib$lib.so" --build-id=sha1 -z max-page-size=0x1000 \
        -z separate-loadable-segments -z noexecstack -z now -z text --eh-frame-hdr --as-needed \
        "$STATIC/swiftrt.o" --whole-archive "$archive" --no-whole-archive "${note[@]}" "${threading[@]}" \
        "${needs[@]}" -o "$so.new"
    mv "$so.new" "$so"
    say "shared: lib$lib.so"
done
