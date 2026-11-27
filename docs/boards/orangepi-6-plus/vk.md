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
    BOARD_DEADLINE=600 BOARD_PASS="vkmark Score:" BOARD_FAIL="exited with -?[1-9]|PANIC" \
      .claude/skills/board-run/board-run.sh build/arm64/esp-board-vkmark LOG

- `esp-board-vkmark`: `vkmark --winsys headless -s 800x600`, no compositor.
  The swapchain is the layer's `VK_EXT_headless_surface` one: nothing is
  shown, and a frame waits only for the GPU's work three frames back.
- `esp-board-vkmark-window`: Radharc on the display, and `vkmark -s 800x600`
  in a window of it. Radharc presents FIFO only, so this run is paced by the
  display (60 Hz at 1080p60) and measures at most that rate per scene.

The serial console carries each scene's line, `[scene] options: FPS: N
FrameTime: T ms`, and the end's `vkmark Score: N`.

## Headless, 2026-11-27 (branch at a1af5fe2)

`esp-board-vkmark`: the default list in order, 800x600, `B8G8R8A8_SRGB`, on
whatever core the scheduler gives it.

| Scene | FPS | Frame (ms) |
|---|---:|---:|
| vertex device-local=true | 11235 | 0.089 |
| vertex device-local=false | 10771 | 0.093 |
| texture anisotropy=0 | 10331 | 0.097 |
| texture anisotropy=16 | 10047 | 0.100 |
| shading shading=gouraud | 7525 | 0.133 |
| shading shading=blinn-phong-inf | 7275 | 0.137 |
| shading shading=phong | 597 | 1.675 |
| shading shading=cel | 5631 | 0.178 |
| effect2d kernel=edge | 11942 | 0.084 |
| effect2d kernel=blur | 6388 | 0.157 |
| desktop | 5849 | 0.171 |
| cube | 12134 | 0.082 |
| clear | 15777 | 0.063 |

vkmark score: **8884**.

What it took to get here, on the board:

- Every scene but effect2d and clear first failed with `OpTypeMatrix: not
  supported by the compiler`. glslang's SPIR-V has matrices, which our GLSL
  front end never wrote; the shader compiler now lowers them as their columns
  (shadercompiler(2)).
- clear ran at 117 FPS (8.5 ms a frame). The Mali backend ran
  `vkCmdClearColorImage` as its `copy` kernel, a texel a thread. A whole
  clear of a one-level render target is now a pass that draws the clear:
  15777 FPS.

## In a window, 2026-11-27 (branch at a1af5fe2)

`esp-board-vkmark-window`: the default list in a window of 800x600 on the
Radharc of the display (1920x1080 at 60 Hz), presented FIFO.

| Scene | FPS | Scene | FPS |
|---|---:|---|---:|
| vertex device-local=true | 14 | shading cel | 13 |
| vertex device-local=false | 12 | effect2d edge | 14 |
| texture anisotropy=0 | 15 | effect2d blur | 13 |
| texture anisotropy=16 | 12 | desktop | 13 |
| shading gouraud | 15 | cube | 14 |
| shading blinn-phong-inf | 12 | clear | 13 |
| shading phong | 14 | | |

vkmark score: **13**. Every scene runs, at 12 to 15 frames a second whatever
its GPU work (the same scenes run at 600 to 16000 frames a second headless):
the window's presents are paced at about one in four or five of the
display's vblanks, not at each one. Why is not yet known; see below.

## Known problems

- **Texture scenes hang the GPU after some seconds.** A run of the texture
  scene of 50 s ended, every time, with `vulkan-core: failed: a pass ended
  its group (group state 9, bit 1 is a fatal fault)` at its teardown, and
  mali's status says why: `CSG 0 progress timer expired`, the group was told to
  terminate and didn't acknowledge, and the GPU was reset. No MMU fault.
  - It came after 9, 17, 20 and 26 s, with anisotropy 16, 16, 2 and 0, with
    the 64 KiB tiled texture layout and without it.
  - A 50 s run of the vertex scene (570 000 frames, no texture) didn't hang,
    and nor did 20 s of the texture scene, nor the full default list
    (10 s each) on its last run. Two earlier runs of the default list hung in
    texture anisotropy=16.
  - So something in a pass that samples a texture stops the GPU now and then.
    Not found yet.
- **The windowed rate.** 12 to 15 frames a second where the display gives
  60. Radharc composes windows on the GPU here (radharc(4)), and vkmark's
  frames are presented FIFO; neither the compositor's rate nor the present's
  wait has been measured yet.
- **phong: 1.7 ms a frame**, a tenth of gouraud's. Not pow: its
  `pow(x, 250.0)` takes the general exp2(y log2 x) path, but blinn-phong-inf's
  fragment shader takes the same path (its exponent is a uniform) at
  7275 FPS. phong's fragment shader calls a function with its parameters
  passed by pointer; what the compiler makes of that has not been looked at.
- **Twice the board didn't come back after a reboot.**
  - Before main's quiesce fix (devmgr halts and disables mali's MCU and
    soft-resets the GPU before a reset), the console stayed silent after
    FreeBSD's reboot into the next image.
  - With it, once: a boot in which vkmark never started (the diagnostic's
    manifest was wrong) quiesced mali (`the MCU (enabled) halted, disabled
    and the GPU soft reset`), printed `croi kernel: rebooting`, and the
    firmware and FreeBSD's loader came up. The console ended after the
    loader's framebuffer information, in FreeBSD's kernel start.

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
