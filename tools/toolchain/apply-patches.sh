#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Applies patches/<component>/*.patch onto .cache/toolchain/work/<tree>/ with
# git am, from vectraos-base. A tree already past its base is left alone:
# to start over, remove it and run fetch-upstream.sh.

set -euo pipefail
source "$(dirname "$0")/common.sh"

for entry in "${COMPONENTS[@]}"; do
    read -r comp tree <<< "$entry"
    dir="$WORK/$tree"
    [[ -d "$dir/.git" ]] || die "$tree not fetched: run fetch-upstream.sh"
    shopt -s nullglob; patches=("$PATCHES/$comp"/*.patch); shopt -u nullglob
    (( ${#patches[@]} )) || { say "$comp: no patches"; continue; }
    if [[ "$(git -C "$dir" rev-parse HEAD)" != "$(git -C "$dir" rev-parse vectraos-base)" ]]; then
        say "$comp: already past vectraos-base, left alone"
        continue
    fi
    say "$comp: applying ${#patches[@]} patches"
    # --keep-non-patch keeps the [VectraOS] in each subject.
    git -C "$dir" -c user.name="VectraOS toolchain" -c user.email="toolchain@vectraos.invalid" \
        am --quiet --keep-non-patch "${patches[@]}"
done
say "patches applied; next: build_stage_t1.sh"
