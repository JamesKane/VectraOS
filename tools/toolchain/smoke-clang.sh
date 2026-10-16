#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# clang for each *-vectraos triple: an object for the right machine with
# __vectraos__ defined, and a program linked against a stub sysroot (crt1.o,
# empty libsys, libc, libm and builtins), which must come out a static
# ET_EXEC at croi's user address, entered at _start, with no PT_INTERP.

set -euo pipefail
source "$(dirname "$0")/common.sh"
CLANG="$OUT/bin/clang"
[[ -x "$CLANG" ]] || die "no clang: run build_stage_t1.sh"
READELF=/usr/bin/llvm-readelf

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/m.c" <<'C'
#ifndef __vectraos__
#error "no __vectraos__"
#endif
int value = 42;
int main(void) { return value; }
C
cat > "$TMP/crt1.c" <<'C'
int main(void);
void _start(void) { main(); for (;;) {} }
C

fail=0
check() {
    if [[ "$2" == "$3" ]]; then printf '  %-26s %s\n' "$1" "$2"
    else printf '  %-26s %s, expected %s: FAIL\n' "$1" "$2" "$3"; fail=1; fi
}

for triple in "${TRIPLES[@]}"; do
    say "smoke (clang): $triple"
    root="$TMP/$triple"; mkdir -p "$root/usr/lib"
    "$CLANG" --target="$triple" -c "$TMP/m.c" -o "$root/m.o"
    "$CLANG" --target="$triple" -c "$TMP/crt1.c" -o "$root/usr/lib/crt1.o"
    for lib in sys c m clang_rt.builtins; do "$OUT/bin/llvm-ar" rc "$root/usr/lib/lib$lib.a"; done
    case "$triple" in
        x86_64-*) want="X86-64" ;; aarch64-*) want="AArch64" ;; riscv64-*) want="RISC-V" ;;
    esac
    machine=$($READELF -h "$root/m.o" | awk -F: '/Machine:/{gsub(/^ +/,"",$2); print $2}')
    check machine "$( [[ "$machine" == *"$want"* ]] && echo "$want" || echo "$machine")" "$want"
    "$CLANG" --target="$triple" --sysroot="$root" "$root/m.o" -o "$root/m" 2> "$root/link.err" || cat "$root/link.err"
    check "type" "$($READELF -h "$root/m" | awk '/Type:/{print $2}')" "EXEC"
    check "first segment" "$($READELF -lW "$root/m" | awk '$1=="LOAD"{print $3; exit}')" "0x0000000001000000"
    check "entry is _start" "$( [[ "$($READELF -h "$root/m" | awk '/Entry/{print $4}')" == "0x$(/usr/bin/llvm-nm "$root/m" | awk '$3=="_start"{print $1}' | sed 's/^0*//')" ]] && echo yes || echo no)" "yes"
    check "no PT_INTERP" "$($READELF -lW "$root/m" | grep -c INTERP || true)" "0"
done

(( fail )) && die "smoke (clang): FAIL"
say "smoke (clang): pass"
