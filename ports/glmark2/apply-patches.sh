#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Applies ports/glmark2/patches/*.patch onto .cache/ports/glmark2 with git
# am, from vectraos-base (fetch.sh). A checkout already past its base is
# left alone; --reset puts it back at its base first (discarding the
# series' commits there), as after a change to the series.
#
#   ports/glmark2/apply-patches.sh [--reset]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEST="${VECTRAOS_PORTS:-$ROOT/.cache/ports}/glmark2"

say() { echo "vectraos: glmark2: $*"; }

[[ -d "$DEST/.git" ]] || { echo "vectraos: glmark2: not fetched: run ports/glmark2/fetch.sh" >&2; exit 1; }
git -C "$DEST" rev-parse -q --verify vectraos-base >/dev/null || { echo "vectraos: glmark2: no vectraos-base: run fetch.sh" >&2; exit 1; }
if [[ "${1-}" == "--reset" ]]; then
    git -C "$DEST" am --abort >/dev/null 2>&1 || true
    git -C "$DEST" checkout --quiet --detach vectraos-base
    git -C "$DEST" reset --quiet --hard vectraos-base
fi
if [[ "$(git -C "$DEST" rev-parse HEAD)" != "$(git -C "$DEST" rev-parse vectraos-base)" ]]; then
    say "already past vectraos-base, left alone (--reset to apply again)"
    exit 0
fi
shopt -s nullglob
patches=("$HERE"/patches/*.patch)
say "applying ${#patches[@]} patches"
# --keep-non-patch keeps the [VectraOS] in each subject.
git -C "$DEST" -c user.name="VectraOS port" -c user.email="port@vectraos.invalid" \
    am --quiet --keep-non-patch "${patches[@]}"
say "patches applied; cmake/Glmark2.cmake builds it with tier 1"
