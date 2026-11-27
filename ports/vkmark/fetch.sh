#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# vkmark at its pinned release (vkmark(8)), with the two header-only
# libraries it is compiled against: Khronos's Vulkan-Headers (vulkan.hpp, at
# the version of data/vulkan/vk.xml) and glm. Shallow clones into
# .cache/ports/vkmark, .cache/ports/vulkan-headers and .cache/ports/glm,
# each checked against its pin and tagged vectraos-base; apply-patches.sh
# applies the series onto vkmark's. Idempotent: a clone already there is
# checked, not fetched again.
#
#   ports/vkmark/fetch.sh                      clone what is missing
#   VKMARK_MIRROR=DIR fetch.sh                 vkmark from a local clone at the pin instead of GitHub
#   VULKAN_HEADERS_MIRROR=DIR, GLM_MIRROR=DIR  the same for the other two

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PORTS="${VECTRAOS_PORTS:-$ROOT/.cache/ports}"

say() { echo "vectraos: vkmark: $*"; }

# fetch NAME URL TAG PIN: a shallow clone of TAG into $PORTS/NAME, refused unless TAG is PIN.
fetch() {
    local name=$1 url=$2 tag=$3 pin=$4 dest="$PORTS/$1" base
    if [[ ! -d "$dest/.git" ]]; then
        say "shallow-cloning $name $tag from $url"
        mkdir -p "$PORTS"
        git clone --quiet --depth=1 --branch="$tag" "$url" "$dest"
    fi
    base=$(git -C "$dest" rev-parse -q --verify vectraos-base || git -C "$dest" rev-parse "$tag^{commit}")
    if [[ "$base" != "$pin" ]]; then
        echo "vectraos: vkmark: $dest's $tag is $base, but the pin is $pin: refusing" >&2
        exit 1
    fi
    git -C "$dest" tag -f vectraos-base "$pin" >/dev/null
    say "$name at $pin"
}

fetch vkmark "${VKMARK_MIRROR:-https://github.com/vkmark/vkmark.git}" \
    2025.01 2bf2ca7f1623db7ad7840a4dd626444d11830815
fetch vulkan-headers "${VULKAN_HEADERS_MIRROR:-https://github.com/KhronosGroup/Vulkan-Headers.git}" \
    v1.4.341 b5c8f996196ba4aa6d8f97e52b5d3b6e70f7e4e2
fetch glm "${GLM_MIRROR:-https://github.com/g-truc/glm.git}" \
    1.0.1 0af55ccecd98d4e5a8d1fad7de25ba429d60e863
say "next: ports/vkmark/apply-patches.sh"
