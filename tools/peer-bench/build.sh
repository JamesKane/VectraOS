#!/usr/bin/env bash
# build.sh OS OUT: D127's rows (rows.c) and the spawn rows' children
# (hello.c, static and linked) for a peer, by the bundled clang and lld
# (.swift-version's toolchain) against the sysroot copied from the board
# into .cache/peer-sysroots/OS (README.md), host-only (D4). OS is
# freebsd or linux; the same flags and -march for all three OSes.
set -euo pipefail
os=$1 out=$2
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
bin=$HOME/.local/share/swiftly/toolchains/$(cat "$repo/.swift-version")/usr/bin
sysroot=$repo/.cache/peer-sysroots/$os
case $os in
  freebsd) target=aarch64-unknown-freebsd16 ;;
  linux) target=aarch64-unknown-linux-gnu ;;
  *) echo "build.sh: OS is freebsd or linux" >&2; exit 2 ;;
esac
[ -d "$sysroot" ] || { echo "build.sh: no sysroot at $sysroot (README.md)" >&2; exit 1; }
# D53's baseline, the board's: the flags every column is built with.
# Not PIE on any OS (clang's FreeBSD default; its Linux one is PIE), so
# the spawn rows load the same kind of program.
flags=(--target=$target --sysroot="$sysroot" -fuse-ld=lld -O2 -march=armv8.2-a+fp16+dotprod+rcpc -pthread
  -fno-pie -no-pie)
mkdir -p "$out"
"$bin/clang" "${flags[@]}" -o "$out/peer-bench" "$here/rows.c"
"$bin/clang" "${flags[@]}" -o "$out/hello-linked" "$here/hello.c"
"$bin/clang" "${flags[@]}" -static -o "$out/hello-static" "$here/hello.c"
