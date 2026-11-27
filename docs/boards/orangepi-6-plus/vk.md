# Orange Pi 6 Plus: Vulkan and vkmark

vkmark(8) on the board, over our Vulkan layer on the core's Mali backend:
D177's `uc_vkmark`, a fixed set of scenes' frame times in a window of
Radharc's, and the same scenes headless.

## How it is run

Two images, each built on request with tier 1 and the port fetched and
patched (ports/vkmark), boot the board image's drivers, run vkmark's default
benchmarks (thirteen scenes, ten seconds each) until it ends, and reboot into
FreeBSD:

    ninja -C build/arm64 esp-board-vkmark esp-board-vkmark-window
    BOARD_DEADLINE=600 BOARD_PASS="vkmark Score:" BOARD_FAIL="launcher exited with [1-9]|panic" \
      .claude/skills/board-run/board-run.sh build/arm64/esp-board-vkmark LOG

- `esp-board-vkmark`: `vkmark --winsys headless -s 800x600`, no compositor.
  The swapchain is the layer's `VK_EXT_headless_surface` one: nothing is
  shown, and a frame waits only for the GPU's work three frames back.
- `esp-board-vkmark-window`: Radharc on the display, and `vkmark -s 800x600`
  in a window of it. Radharc presents FIFO only, so this run is paced by the
  display (60 Hz at 1080p60) and measures at most that rate per scene.

The serial console carries each scene's line, `[scene] options: FPS: N
FrameTime: T ms`, and the end's `vkmark Score: N`.

## Headless, 2026-11-27 (branch at 083bf61b)

`esp-board-vkmark`, 800x600, `B8G8R8A8_SRGB`, on whatever core the
scheduler gives it. The first run had only four scenes before the shader
compiler took matrices (every scene but effect2d and clear failed with
`OpTypeMatrix: not supported by the compiler`); with matrices, two runs:
one of the default list in order, which stopped with a GPU fault after
texture anisotropy=16 (below), and one of the default list with texture
anisotropy=16 moved to the end, which ran every scene.

| Scene | FPS | Frame (ms) | Run |
|---|---:|---:|---|
| vertex device-local=true | 11471 | 0.087 | default order |
| vertex device-local=false | 10924 | 0.092 | default order |
| texture anisotropy=0 | 10379 | 0.096 | default order |
| texture anisotropy=16 | 10048 | 0.100 | moved to the end |
| shading shading=gouraud | 7477 | 0.134 | moved |
| shading shading=blinn-phong-inf | 7315 | 0.137 | moved |
| shading shading=phong | 607 | 1.647 | moved |
| shading shading=cel | 5666 | 0.176 | moved |
| effect2d kernel=edge | 11974 | 0.084 | moved |
| effect2d kernel=blur | 6385 | 0.157 | moved |
| desktop | 5842 | 0.171 | moved |
| cube | 11027 | 0.091 | moved |
| clear | 117 | 8.547 | moved |

The second run's score: **6645** (its ten scenes; the first run's three
scenes before texture anisotropy=16 are not in it). The mean of all
thirteen rows above is 7633.

## Known problems

- **A GPU fault after texture anisotropy=16 in the default order.** In
  the default list texture anisotropy=16 directly follows texture
  anisotropy=0. It ran slower there (6328 FPS, and 13.8 s for a 10 s scene)
  and ended with `vulkan-core: failed: a pass ended its group (group state 9,
  bit 1 is a fatal fault)` at its teardown's `waitIdle`. vkmark then aborted
  (`vkmark-offscreen exited -1028`). Run last, after other scenes, the same
  scene ran its 10 s at 10048 FPS without a fault. So it is not
  anisotropy by itself; the repeated texture scene's resources are the
  suspect. Not reproduced or fixed yet: the run that would have isolated it
  (texture anisotropy=0 three times, then 16) never booted (next item).
- **The board didn't come back after a reboot.** After the run with every
  scene (the second above) the board came back to FreeBSD and took the next
  image (texture repeated, `esp-board-vkmark`). After FreeBSD's reboot into
  it, the serial console stayed silent, with no firmware output, and the board
  answered nothing for 17 minutes.
- **clear: 8.5 ms a frame.** vkmark's clear scene records
  `vkCmdClearColorImage` every frame; the Mali backend runs it as its `copy`
  kernel (Transfers.swift). 8.547 ms is far more than an 800x600 clear
  costs, and the same every frame; not yet looked into.
- **phong: 1.6 ms a frame**, a tenth of gouraud's. Its fragment shader has
  `pow(x, 250.0)`, beyond the compiler's products by squaring (exponents to
  128), so it takes the accurate exp2(y log2 x) path; whether that is the
  cost is not yet measured.

## In a window

Not yet run (`esp-board-vkmark-window`): the board was down.

## The reference

There is none to compare with yet. AbyssBSD's own notes list vkmark only as a
diagnostic, with no numbers, and D177 names GNOME on Ubuntu as the
comparison for `uc_vkmark`. The run the owner would need to make: Ubuntu
with GNOME (Wayland) on this board with Mesa's panvk, vkmark 2025.01 from
the distribution or built at the same release, run as

    vkmark -s 800x600                    # windowed, mailbox (GNOME's default)
    vkmark --winsys headless -s 800x600  # headless

with nothing else on the GPU, and its per-scene lines and score recorded
here as glmark2's reference is in gl.md.
