#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Regenerates patches/<component>/ from the commits past vectraos-base in
# .cache/toolchain/work/<tree>/: one patch a commit. To change a patch,
# commit in the tree (amend, or reset and re-commit), run this, and review
# the series' diff.
#
#   ./refresh-patches.sh [component]

set -euo pipefail
source "$(dirname "$0")/common.sh"

for entry in "${COMPONENTS[@]}"; do
    read -r comp tree <<< "$entry"
    [[ -z "${1-}" || "$1" == "$comp" ]] || continue
    dir="$WORK/$tree"
    [[ -d "$dir/.git" ]] || { say "$tree not fetched, skipped"; continue; }
    n=$(git -C "$dir" rev-list --count vectraos-base..HEAD)
    rm -rf "$PATCHES/$comp"
    (( n )) || { say "$comp: no commits past vectraos-base"; continue; }
    mkdir -p "$PATCHES/$comp"
    git -C "$dir" format-patch --quiet --no-signature --zero-commit -o "$PATCHES/$comp" vectraos-base..HEAD
    say "$comp: $n patches"
done
