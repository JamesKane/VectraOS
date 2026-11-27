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

## The texture scenes' GPU hang: empty tile read (fixed, 2026-11-27)

A run of the texture scene of 50 s used to end, every time, with
`vulkan-core: failed: a pass ended its group (group state 9, bit 1 is a fatal
fault)` at its teardown. mali's status gave `CSG 0 progress timer expired`, an
unacknowledged TERMINATE and a GPU reset, and no MMU fault. It came after 9 to
26 s of the scene, at any anisotropy, with tiled textures and without. The
vertex scene never hung, even in 50 s (570 000 frames).

What stopped:
- **The fragment run never ended.** At the progress timeout a dump of each
  queue's status (a STATUS_UPDATE, then CS_STATUS_*) showed this.
  - The pass's queue stood at its last `WAIT`, blocked on two scoreboard
    slots. The stream before it was `RUN_FRAGMENT`, a load of the
    completed-chunk words, then `FINISH_FRAGMENT`, which waits on the
    fragment run. Tiling had finished.
  - With the pass on two queues, the fragment queue stood at the same
    instructions.
- **The descriptors were whole.** At the fault, the heap's GPU copy matched
  the CPU's words, and the draws' root blocks and combined image-sampler
  record held what they were written with.
- **The timing repeated.** Two runs of the same image stopped at the same
  millisecond after boot (21.07 s), and each experiment's image at a time of
  its own.

One run of each experiment, 120 s of the texture scene (60 s at anisotropy 0,
then 60 s at 16), headless at 800x600:

| What was off | Result | FPS |
|---|---|---:|
| nothing | hung at 20 s, twice | |
| AFBC | hung at 14 s | |
| tiled textures | hung | |
| one queue a pass (`singleQueuePasses`) | hung at 14 s | |
| CRC tables | 120 s, no hang | 7764 |
| CRC read | 120 s, no hang | 7738 |
| empty tile read (08 word 12 bit 28) | 120 s, no hang | 10345 |

- **Empty tile read was the cause.** With only it off, the scene ran at its
  usual rate and never stopped. Empty tile read skips the load of a tile that
  was empty last time and is empty again. A pass that clears loads nothing,
  so the skip gained nothing here. It is now never set (gpucore(2)). CRC read
  and write and empty tile write stay on.
- **Why it stops the GPU is not known.** The spec has the reference setting
  empty tile read whenever a pass has one colour target. vkmark does what that
  allows: three swapchain images, each with its CRC table, and one depth
  image they share. glmark2 ran its texture scene (mipmap, then linear) for
  60 s each with empty tile read still on, and didn't hang (6767 and 6459
  FPS). GL wasn't seen to be affected, but no other GL scene was run that
  long.
- **The checks.** The Mali tests check that a pass with a CRC table never
  sets empty tile read (RenderPassTests' textured pass, and the FBD's
  words).
- **Long runs on the board after the fix**, at d1aea543: 120 s of the texture
  scene three times passed (scores 10179, 10166 and 10151). The full default
  list passed, score 8767 (texture 10282 and 9989; cube 11227 and clear 14894,
  against 12134 and 15777 before). Those two drops were not measured again.

## Known problems
- **The windowed rate.** 12 to 15 frames a second where the display gives
  60. Radharc composes windows on the GPU here (radharc(4)), and vkmark's
  frames are presented FIFO; neither the compositor's rate nor the present's
  wait has been measured yet.
- **phong: 1.7 ms a frame**, a tenth of gouraud's. Not pow: its
  `pow(x, 250.0)` takes the general exp2(y log2 x) path, but blinn-phong-inf's
  fragment shader takes the same path (its exponent is a uniform) at
  7275 FPS. phong's fragment shader calls a function with its parameters
  passed by pointer; what the compiler makes of that has not been looked at.
- **The board not coming back after a reboot: partly an address change.**
  - 2026-11-27, after a 60 s texture run: FreeBSD did come back, at the
    login prompt, but DHCP had given it 192.168.0.16, and board-run looked
    only at .32. It was not a hang. The serial console's last line was the
    loader's framebuffer information. board-run now reaches the board by name
    (`root@opi6plus`).
  - The same day, after a run that ended well (vkmark exited 0 and mali's
    MCU halted, disabled and soft reset), the board hung: the console ended
    at `croi kernel: rebooting` and its budget lines, with no firmware
    output after them, and the owner power-cycled it. That one was a real
    hang, in our reboot or the firmware's reset.
  - The two cases below are older. Nobody looked for the board at another
    address then, so it is not known whether either was an address change
    or a hang.
  - Before main's quiesce fix (devmgr halts and disables mali's MCU and
    soft-resets the GPU before a reset), the console stayed silent after
    FreeBSD's reboot into the next image.
  - With it, once: a boot in which vkmark never started (the diagnostic's
    manifest was wrong) quiesced mali (`the MCU (enabled) halted, disabled
    and the GPU soft reset`), printed `croi kernel: rebooting`, and the
    firmware and FreeBSD's loader came up. The console ended after the
    loader's framebuffer information, in FreeBSD's kernel start. Today's
    address change ended the console at the same line (the serial console
    shows nothing of FreeBSD's kernel), so this one may have been an address
    change too; that was not checked.

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
