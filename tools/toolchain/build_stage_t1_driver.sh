#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# The Swift-language driver (swift-driver), with the series, installed as
# the toolchain's swiftc and swift, as Swift's own toolchains do. Built by
# the host Swift with SwiftPM, taking its dependencies from the pinned
# siblings in the work tree (SWIFTCI_USE_LOCAL_DEPS).

set -euo pipefail
source "$(dirname "$0")/common.sh"

for d in swift-driver llbuild swift-tools-support-core swift-argument-parser swift-toolchain-sqlite; do
    [[ -d "$WORK/$d/.git" ]] || die "$d not fetched: run fetch-upstream.sh"
done
[[ -x "$OUT/bin/swift-frontend" ]] || die "no swift-frontend: run build_stage_t1_swift.sh"
export PATH="$HOST_SWIFT_BIN:$PATH"

say "swift-driver: building with $(swift --version 2>&1 | head -1)"
(cd "$WORK/swift-driver" && SWIFTCI_USE_LOCAL_DEPS=1 swift build -c release --product swift-driver)
install -m 0755 "$WORK/swift-driver/.build/release/swift-driver" "$OUT/bin/swift-driver"
for tool in swift swiftc; do ln -sf swift-driver "$OUT/bin/$tool"; done
say "swift-driver installed; swiftc and swift run it (the C++ driver: SWIFT_USE_OLD_DRIVER=1 swift-frontend --driver-mode=swiftc)"
