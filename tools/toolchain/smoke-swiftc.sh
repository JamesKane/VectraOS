#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# The Swift compiler for each *-vectraos triple. There is no stdlib for
# them yet (M6e), so the source is compiled with -parse-stdlib. Checks an
# object for the right machine, os(VectraOS) and not os(Linux), and the
# platform's name, through the frontend and through the driver.

set -euo pipefail
source "$(dirname "$0")/common.sh"
FRONTEND="$OUT/bin/swift-frontend"
SWIFTC="${SWIFTC:-$OUT/bin/swiftc}"
[[ -x "$FRONTEND" ]] || die "no swift-frontend: run build_stage_t1_swift.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/hello.swift" <<'S'
#if os(VectraOS) && !os(Linux)
public func vectraos_yes() {}
#else
public func vectraos_no() {}
#endif
S

fail=0
check() {
    if [[ "$2" == "$3" ]]; then printf '  %-26s %s\n' "$1" "$2"
    else printf '  %-26s %s, expected %s: FAIL\n' "$1" "$2" "$3"; fail=1; fi
}

for triple in "${TRIPLES[@]}"; do
    say "smoke (swiftc): $triple"
    obj="$TMP/hello-$triple.o"
    "$FRONTEND" -frontend -c -parse-stdlib -target "$triple" -module-name hello "$TMP/hello.swift" -o "$obj"
    case "$triple" in
        x86_64-*) want="X86-64" ;; aarch64-*) want="AArch64" ;; riscv64-*) want="RISC-V" ;;
    esac
    machine=$(/usr/bin/llvm-readelf -h "$obj" | awk -F: '/Machine:/{gsub(/^ +/,"",$2); print $2}')
    check machine "$( [[ "$machine" == *"$want"* ]] && echo "$want" || echo "$machine")" "$want"
    check "os(VectraOS)" "$(/usr/bin/llvm-nm "$obj" | grep -c vectraos_yes || true)" "1"
    platform=$("$FRONTEND" -frontend -print-target-info -target "$triple" | sed -n 's/.*"platform": *"\([^"]*\)".*/\1/p' | head -1)
    check platform "$platform" "vectraos"
    if [[ -x "$SWIFTC" ]]; then
        "$SWIFTC" -c -parse-stdlib -target "$triple" -module-name hello "$TMP/hello.swift" -o "$TMP/d-$triple.o"
        check "through the driver" "$(/usr/bin/llvm-nm "$TMP/d-$triple.o" | grep -c vectraos_yes || true)" "1"
    fi
done

(( fail )) && die "smoke (swiftc): FAIL"
say "smoke (swiftc): pass"
