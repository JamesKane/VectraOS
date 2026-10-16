#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# The upstream sources M6's toolchain builds (LLVM's and Swift's, at Swift
# 6.4.0), shallow clones into .cache/toolchain/work/, each checked against
# pins.txt and tagged vectraos-base, which apply-patches.sh and
# refresh-patches.sh measure the series from. Idempotent: a clone already
# there is skipped.
#
# VECTRAOS_TOOLCHAIN_MIRROR=DIR clones from DIR/<name> (a tree of clones at
# the same pins, such as ../lang/swift-on-vectra/toolchain/work, whose
# clones carry the upstream commit as `vectra-base`) instead of GitHub.
#
#   ./fetch-upstream.sh          clone what is missing
#   ./fetch-upstream.sh --pin    rewrite pins.txt from the clones

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${VECTRAOS_TOOLCHAIN_WORK:-$ROOT/.cache/toolchain/work}"
PINS="$HERE/pins.txt"
MIRROR="${VECTRAOS_TOOLCHAIN_MIRROR:-}"
mkdir -p "$WORK"

if [[ "${1-}" == "--pin" ]]; then
    tmp=$(mktemp)
    head -4 "$PINS" > "$tmp"
    for d in "$WORK"/*/; do
        d=${d%/}; n=${d##*/}
        t=$(awk -v n="$n" '$1 == "clone" && $2 == n {print $4}' "$0")
        [[ -n "$t" ]] || continue
        printf '%-38s %-22s %s\n' "$n" "$t" "$(git -C "$d" rev-parse vectraos-base)" >> "$tmp"
    done
    mv "$tmp" "$PINS"
    echo "vectraos: toolchain: wrote $PINS"
    exit 0
fi

clone() {
    local name="$1" url="$2" tag="$3"
    local dest="$WORK/$name"
    if [[ -d "$dest/.git" ]]; then
        echo "vectraos: toolchain: $name present — skipping"
        return 0
    fi
    local want
    want=$(awk -v n="$name" -v t="$tag" '$1 == n && $2 == t {print $3}' "$PINS")
    if [[ -n "$MIRROR" && -d "$MIRROR/$name/.git" ]]; then
        echo "vectraos: toolchain: cloning $name from $MIRROR"
        local ref=$tag
        git -C "$MIRROR/$name" rev-parse -q --verify vectra-base >/dev/null && ref=vectra-base
        git clone --quiet --depth=1 --branch="$ref" "file://$MIRROR/$name" "$dest"
    else
        echo "vectraos: toolchain: shallow-cloning $name @ $tag"
        git clone --quiet --depth=1 --branch="$tag" --single-branch "$url" "$dest"
    fi
    local got
    got=$(git -C "$dest" rev-parse HEAD)
    if [[ -n "$want" && "$want" != "$got" ]]; then
        echo "vectraos: toolchain: $name is $got, but pins.txt says $want — refusing" >&2
        rm -rf "$dest"
        exit 1
    fi
    [[ -n "$want" ]] || echo "vectraos: toolchain: $name @ $tag is not in pins.txt; run --pin after review" >&2
    git -C "$dest" tag vectraos-base
}

# LLVM is swiftlang's fork: Swift's frontend needs its clang additions.
clone llvm-project                          https://github.com/swiftlang/llvm-project.git                          swift-6.4.0-RELEASE
clone swift                                 https://github.com/swiftlang/swift.git                                 swift-6.4.0-RELEASE
# What a compiler-only build needs beside swift.
clone cmark                                 https://github.com/swiftlang/swift-cmark.git                           swift-6.4.0-RELEASE
clone swift-syntax                          https://github.com/swiftlang/swift-syntax.git                          swift-6.4.0-RELEASE
clone swift-experimental-string-processing  https://github.com/swiftlang/swift-experimental-string-processing.git  swift-6.4.0-RELEASE
# FoundationEssentials (M6g) and its collections.
clone swift-foundation                      https://github.com/swiftlang/swift-foundation.git                      swift-6.4.0-RELEASE
clone swift-collections                     https://github.com/apple/swift-collections.git                         1.1.6
# The Swift-language driver and what it is built from.
clone swift-driver                          https://github.com/swiftlang/swift-driver.git                          swift-6.4.0-RELEASE
clone llbuild                               https://github.com/swiftlang/swift-llbuild.git                         swift-6.4.0-RELEASE
clone swift-tools-support-core              https://github.com/swiftlang/swift-tools-support-core.git              swift-6.4.0-RELEASE
clone swift-argument-parser                 https://github.com/apple/swift-argument-parser.git                     1.6.1
clone swift-toolchain-sqlite                https://github.com/swiftlang/swift-toolchain-sqlite.git                1.0.9

echo "vectraos: toolchain: sources fetched; next: apply-patches.sh"
