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
display's vblanks, not at each one. The cause is below.

## The windowed rate: Radharc's frame took 62 ms (fixed, 2026-11-28)

Measured on the board with lines Radharc and the Vulkan layer printed every
2 s (dropped since), over `vkmark -b clear -b vertex` in the window:

- **The timeline at 13 FPS.** vkmark's present waited 66 to 83 ms for its
  credit; its acquire waited 1 us (three images, always one free). Radharc
  took every present at the first latch after it arrived (14 ms in the queue
  at most) and never found one not yet drawn. Its latch thread woke on time
  (2 us late) but latched 26 to 30 times in 2 s, skipping three vblanks of
  four: each latch's frame took 58 to 68 ms. The frame was the GPU's whole
  desk (18 ms), the GPU's copy of it back into memory the CPU reads (37 ms),
  the CPU's copy of the damage into the shadow (0.5 ms) and into the
  output's image. The latch's deadline profile was not the cause (1.8 ms of
  CPU a latch; the same with no profile).
- **Cause 1: scanout direct never attached.** `renderer gpu` was on Mali but
  not `scanout direct`. linlon refused both targets: `bti_pin` failed
  ACCESS_DENIED. bti_pin asks MAP of the VMO it pins, as Zircon's does, and
  mali(3)'s `exportVMO` gave transfer, read and measure only. No board run
  had ever had Radharc's direct path; compose-test checked that the targets
  export, never that a display pins them. With MAP, both attach: 28 to 30
  FPS, Radharc latching at every other vblank.
- **Cause 2: the window's chrome uploaded at every frame.** The draw was
  still 17.5 ms. Not the GPU wait or its notification (a 30 ms spin on the
  chain word saw the same), not the scheduler (no profile, or vkmark's group
  at the lowest priority: the same), not the window's imported image (drawn
  as a fill instead: the same, and bound GPU-cacheable: the same). The same
  desk drawn with nothing in it took 0.87 ms, and the desk drawn before
  vkmark started 0.4 ms. The renderer copied each window's chrome into its
  texture at every frame (a staging copy before the pass), though a chrome
  changes only by being made again. Uploaded once for each chrome made, the
  frame takes 0.6 ms and Radharc latches at every vblank.

Why a copy before the pass costs 17 ms only while another context (vkmark's)
is on the GPU is not known; see Known problems.

`esp-board-vkmark-window` after both, 2026-11-28 (branch at 29efb71e), the
default list:

| Scene | FPS | Scene | FPS |
|---|---:|---|---:|
| vertex device-local=true | 59 | shading cel | 57 |
| vertex device-local=false | 57 | effect2d edge | 60 |
| texture anisotropy=0 | 60 | effect2d blur | 57 |
| texture anisotropy=16 | 57 | desktop | 60 |
| shading gouraud | 60 | cube | 59 |
| shading blinn-phong-inf | 57 | clear | 57 |
| shading phong | 60 | | |

vkmark score: **58** (13 before). The scenes alternate between 57 and 60:
Radharc's vblank is its own 60.0 Hz while the display's is 59.9 Hz, and as
the two drift, a latch now and then falls just after the display's latch
and waits a frame.

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

## phong's 1.7 ms: an inlined callee's variables in memory (fixed, 2026-11-28)

phong ran at 598 FPS, 1.67 ms a frame, where gouraud ran at 7439 and
blinn-phong-inf at 7217. It wasn't pow: blinn-phong-inf's fragment shader
also takes the general exp2(y log2 x) path. It wasn't the vertex side either:
cel uses phong's vertex shader and ran at 5634.

- **The cause.** phong's fragment shader calls `compute_color`, and glslang
  passes the arguments as pointers to Function variables of `main`. The
  Valhall backend inlines every call, but it left the callee's variables
  (`eye_direction`, `reflection`, `result` and the rest) in the callee's
  cloned blocks. Promotion only takes variables in the entry block. So each
  of them stayed in the thread's stack memory.
- **The listing.** The shader was 202 instructions, with 144 bytes of stack
  and a `STORE` or `LOAD ... thread_local_pointer` for every component of
  every variable access: 30 stores and 36 loads, and 37 NOPs that wait for them.
  Now it is 99 instructions, with no stack and no thread-local access. Of
  vkmark's 17 shaders, it was the only one that changed. A multiview vertex
  shader's copies kept their outputs' slots in memory the same way (48 bytes
  for two views). Both now put the cloned variables in the entry block
  (valhallbackend(2)).
- **The checks.** ValhallBackendTests' InliningTests compile a fragment
  shader that calls a function with pointer parameters, and a compute shader
  that makes the call inside a branch. Each must have no stack bytes and no
  thread-local access. MultiviewTests checks that a two-view shader has no
  stack.

Headless, 800x600, before (main 420a8bd2) and after:

| Scene | Before | After |
|---|---:|---:|
| vertex device-local=true | 11488 | 11398 |
| vertex device-local=false | 10932 | 10919 |
| texture anisotropy=0 | 10285 | 10281 |
| texture anisotropy=16 | 9989 | 9983 |
| shading shading=gouraud | 7439 | 7481 |
| shading shading=blinn-phong-inf | 7217 | 7235 |
| shading shading=phong | 598 | **5240** |
| shading shading=cel | 5634 | 5606 |
| effect2d kernel=edge | 11929 | 11970 |
| effect2d kernel=blur | 6381 | 6384 |
| desktop | 5844 | 5847 |
| cube | 11961 | 12058 |
| clear | 16101 | 16280 |
| **vkmark Score** | **8907** | **9283** |

The shading scenes alone gave the same: 7417, 7269, 599 and 5640 before, and
7368, 7248, 5253 and 5622 after. glmark2 takes no calls into the backend
(the GLSL front end inlines its functions itself), so GL can't change. Its
shading scenes on the same build gave 4927, 4838, 3759 and 3842 FPS, against
gl.md's last 4861, 4755, 3690 and 3763.

## Known problems
- **A copy before a pass: 17 ms beside another context.** Radharc's desk,
  with a staging copy into a texture before its pass, took 17.5 ms while
  vkmark's context was on the GPU, against 0.4 ms for the same frame
  before vkmark started. Its GPU copy of the frame back to memory took
  37 ms there, against 5.5 ms for a 4K one in compose-test alone. The
  chain word only reached its value then, so the GPU's work, not the
  wait, took that long. The chrome no longer needs the copy, but any
  client that uploads before it draws, while another process uses the GPU,
  should see the same. Not looked into: the mali scheduler's choice of
  groups, endpoints, or the firmware's.
- **Radharc's vblank is its own.** 60.0 Hz against the display's 59.9 Hz,
  so a window at the display's rate loses a frame now and then (57 to 60 in
  vkmark's scenes); linlon's `present` returns at the display's latch,
  which Radharc doesn't follow.
- **One whole-board hang at phong's start**, 2026-11-28, on the first run of
  the fixed build (the shading scenes alone). The console stopped at
  `[shading] shading=phong:`, with no mali message, and the watchdog reset the
  board. The same image then ran the four scenes again, phong passing at 5253
  FPS. A build that starts phong twelve times in one boot didn't hang, nor did
  the full list after it. Whether it comes from the faster shader, or from the
  GPU or the board, is not known.
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
  - **The reset hang, looked into (2026-11-28; cause not found).** One
    other console ends the same way: 2026-11-26, before the quiesce fix,
    glmark2 killed by an exception with GPU work in flight. Of the 88
    consoles kept from that week's board runs that reach
    `croi kernel: rebooting`, 87 go on to the firmware's BL2; of the 45
    or so after the quiesce fix, all do, so with the hang above the rate
    since is about 1 in 46, not 1 in 12.
    - **Where it stops.** The kernel now prints the reset's last lines
      (system(2)); the last is `croi kernel: PSCI SYSTEM_RESET (SMC)`.
      board-run's `LOG.times` puts BL2's first line 1 to 2 s after it, so a
      hang is in the reset itself or in firmware before BL2.
    - **The watchdog doesn't rescue it.** The SBSA watchdog (GTDT,
      `0x16003000`; the kernel arms it, 30 s, firmware and FreeBSD leave
      it off: WCS 0 at our boot) is on at the reset, 16.6 s from its own
      reset in both runs measured. It was on in the 11-26 hang too, and
      the board stayed hung: either the reset happened and took the
      watchdog with it, or the reset machinery can't act. A shorter
      timeout armed just before the reset would not help.
    - **What the reset found running**, against FreeBSD's reboot, which
      PSCI SYSTEM_RESET as we do (AbyssBSD's shutdown too): the GPU is
      quiesced; PCI bus mastering is off (NVMe, the RTL8126s); DPU4
      scans out the GOP framebuffer through the display SMMU's RMR
      identity map, as under FreeBSD; but ten xHCI controllers are left
      running with their rings in our memory and no IOMMU (USB1 polls a
      keyboard every few ms), which FreeBSD halts, and both SMMUv3s and
      the ITS were left on. The reset now turns the other CPUs off
      (PSCI CPU_OFF) and the ITS and both SMMUs off first, as a warm boot
      does (CR0 0 on the last line).
    - **Not the xHCIs.** A build that held all ten in reset before the
      reset (through their Cadence controllers' lines on RST0, 71 to 90)
      reset cleanly ten times and hung on the eleventh, after
      `PSCI SYSTEM_RESET (SMC)`, as before. It was not merged. What still
      runs at the reset is DPU4's scan-out and devices that do no DMA.
    - **Left as it is (the owner, 2026-11-28).** The hang has a manual
      workaround, a power cycle, and doesn't affect correctness, so it is
      not chased further.
    - **Reboots since:** ten board-test runs (one with the last lines
      only, nine with the hand-over too), none hung. At about 1 in 46
      that says little either way.
    - **One slow reset.** In nine of the ten, BL2's first line came 0.95
      to 1.8 s after the PSCI line; in one (with the hand-over) it came
      11.2 s after. Something in the reset or the firmware before BL2
      waits, and here gave up after about 10 s; a wait that never gives
      up would be the hang. What it waits on is not known.
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

D177 names GNOME on Ubuntu as the comparison for `uc_vkmark` (AbyssBSD's
notes list vkmark only as a diagnostic, with no numbers). Run 2026-11-28 on
this board's own Ubuntu by `ports/vkmark/reference.sh`: Ubuntu 26.04.1 LTS,
Linux 7.0.0-41-cix with panthor, Mesa 26.0.8-1ubuntu0.3's panvk (the
Mali-G720 MC10; panvk warns it is not conformant), GNOME on Wayland,
vkmark 2025.01 unpatched at the port's pin (2bf2ca7f), 800x600, nothing
else on the GPU. VectraOS's columns are main's (headless at d555ee9a,
windowed at 4fef477e).

| Scene | panvk headless | VectraOS headless | panvk in GNOME | VectraOS in Radharc |
|---|---:|---:|---:|---:|
| vertex device-local=true | 968 | 11398 | 1019 | 59 |
| vertex device-local=false | 1041 | 10919 | 834 | 57 |
| texture anisotropy=0 | 5940 | 10281 | 3873 | 60 |
| texture anisotropy=16 | 5833 | 9983 | 3962 | 57 |
| shading gouraud | 584 | 7481 | 590 | 60 |
| shading blinn-phong-inf | 216 | 7235 | 228 | 57 |
| shading phong | 191 | 5240 | 225 | 60 |
| shading cel | 550 | 5606 | 501 | 57 |
| effect2d edge | 1280 | 11970 | 1221 | 60 |
| effect2d blur | 1209 | 6384 | 252 | 57 |
| desktop | 6607 | 5847 | 3993 | 60 |
| cube | 8145 | 12058 | 5470 | 59 |
| clear | 5127 | 16280 | 4987 | 57 |
| **Score** | **2899** | **9283** | **2088** | **58** |

- **Headless:** VectraOS scores 3.2 times panvk, and is ahead in every scene
  but desktop (5847 against 6607, 88%).
- **In a window the two aren't alike:** GNOME presents mailbox, so a frame
  never waits for the display, while Radharc presents FIFO only and is held
  to the display's 60 Hz (radharc(4)). The windowed columns compare how
  each composites, not the GPU; a like-for-like windowed comparison waits
  for Radharc to present mailbox, or for GNOME to be run FIFO.
- `ports/vkmark/reference.sh` makes the run again on the board's Ubuntu
  (firmware entry Boot0004, booted once by BootNext from FreeBSD).
