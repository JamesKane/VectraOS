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

## Results

None yet. The first runs (branch `vkmark`, 2026-11-27) found the board
unreachable: no FreeBSD at 192.168.0.32 for over an hour and a silent
serial console, which needs a power cycle. The images above are built and
waiting.

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
