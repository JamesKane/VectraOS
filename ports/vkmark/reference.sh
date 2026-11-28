#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# The reference for vkmark on the Orange Pi 6 Plus (D177's uc_vkmark,
# docs/boards/orangepi-6-plus/vk.md, "The reference"): run on the board
# under Ubuntu with GNOME on Wayland and Mesa's panvk, never on VectraOS.
# It builds vkmark at the same pin as ports/vkmark/fetch.sh (2025.01,
# unpatched, its own window systems), checks that Vulkan's device is the
# Mali-G720 through panvk, and runs it as VectraOS's two images do:
#
#   vkmark -s 800x600                    in a window of GNOME's session
#   vkmark --winsys headless -s 800x600  headless
#
# Each run's output goes to ~/vkmark-reference/results/<name>.txt, with the system's
# details beside it, for vk.md's table. Run it from a terminal in the
# GNOME session, with nothing else using the GPU:
#
#   bash reference.sh            build if needed, then both runs
#   bash reference.sh --no-build only the runs (vkmark already built)
#
# Host side only (D4): nothing of this goes on the device.

set -euo pipefail

PIN=2bf2ca7f1623db7ad7840a4dd626444d11830815
WORK=${VKMARK_REFERENCE_DIR:-$HOME/vkmark-reference}
OUT=$WORK/results
say() { echo "vkmark-reference: $*"; }

mkdir -p "$WORK" "$OUT"
if [[ ${1:-} != --no-build ]]; then
  say "packages (sudo): meson, the Vulkan loader and headers, glm, assimp, Wayland, Mesa's Vulkan drivers"
  sudo apt-get install -y git meson ninja-build g++ pkg-config libvulkan-dev vulkan-tools \
    libglm-dev libassimp-dev libwayland-dev libwayland-bin wayland-protocols libxcb1-dev libxcb-icccm4-dev \
    libdrm-dev libgbm-dev mesa-vulkan-drivers
  if [[ ! -d $WORK/vkmark/.git ]]; then
    git clone --quiet https://github.com/vkmark/vkmark.git "$WORK/vkmark"
  fi
  git -C "$WORK/vkmark" fetch --quiet origin "$PIN" 2>/dev/null || true
  git -C "$WORK/vkmark" checkout --quiet "$PIN"
  meson setup "$WORK/build" "$WORK/vkmark" --buildtype=release --reconfigure 2>/dev/null ||
    meson setup "$WORK/build" "$WORK/vkmark" --buildtype=release
  ninja -C "$WORK/build"
fi

VKMARK=$WORK/build/src/vkmark
DATA=$WORK/vkmark/data
PLUGINS=$WORK/build/src

{
  echo "date        $(date -u +%FT%TZ)"
  echo "kernel      $(uname -srm)"
  echo "os          $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "session     ${XDG_SESSION_TYPE:-?} ${XDG_CURRENT_DESKTOP:-?}"
  echo "vkmark      $(git -C "$WORK/vkmark" rev-parse HEAD)"
  echo "mesa        $(dpkg-query -W -f '${Version}' mesa-vulkan-drivers 2>/dev/null || echo ?)"
  vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverName|driverInfo|apiVersion" || true
} | tee "$OUT/system.txt"

# The device must be the Mali through panvk: a reference on llvmpipe (the
# CPU) or another driver would compare nothing.
if ! grep -qi panvk "$OUT/system.txt" && ! grep -qi "mali" "$OUT/system.txt"; then
  say "Vulkan's device is not the Mali through panvk (see $OUT/system.txt); not running"
  exit 1
fi

run() {
  local name=$1; shift
  say "$name: vkmark $*"
  "$VKMARK" --data-dir "$DATA" --winsys-dir "$PLUGINS" "$@" 2>&1 | tee "$OUT/$name.txt"
}
run windowed -s 800x600
run headless --winsys headless -s 800x600

say "done: send $OUT (system.txt, windowed.txt, headless.txt) to be recorded in vk.md"
