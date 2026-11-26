#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# glmark2 at its pinned release (D183), a shallow clone into
# .cache/ports/glmark2, checked against the pin and tagged vectraos-base,
# which apply-patches.sh applies the series from. Idempotent: a clone
# already there is checked, not fetched again.
#
#   ports/glmark2/fetch.sh             clone if missing
#   GLMARK2_MIRROR=DIR fetch.sh        clone from a local clone at the pin instead of GitHub

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEST="${VECTRAOS_PORTS:-$ROOT/.cache/ports}/glmark2"
URL="${GLMARK2_MIRROR:-https://github.com/glmark2/glmark2.git}"
TAG=2023.01
PIN=42e3d8fe3aa88743ef90348138f643f7b04a9237

say() { echo "vectraos: glmark2: $*"; }

if [[ ! -d "$DEST/.git" ]]; then
    say "shallow-cloning $TAG from $URL"
    mkdir -p "$(dirname "$DEST")"
    git clone --quiet --depth=1 --branch="$TAG" "$URL" "$DEST"
fi
base=$(git -C "$DEST" rev-parse -q --verify vectraos-base || git -C "$DEST" rev-parse "$TAG^{commit}")
if [[ "$base" != "$PIN" ]]; then
    echo "vectraos: glmark2: $DEST's $TAG is $base, but the pin is $PIN: refusing" >&2
    exit 1
fi
git -C "$DEST" tag -f vectraos-base "$PIN" >/dev/null
say "at $PIN; next: ports/glmark2/apply-patches.sh"
