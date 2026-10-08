# 21. Pixels: M7's design and scope

Status: scoping, 2026-10-08. M7's content is 04 §6's row; its design is 03 (§4 the frame protocol, §5 `/wsys`, §6 `vxui`), ADR-0026 (display back ends), 07 §7 (the plumber) and 08 §16 (`lib/vx-text`). This note settles what those leave open or disagree on, against the prior art (9front's draw device, rio and plumber; Fuchsia's Flatland, display coordinator and input pipeline), and orders the work into steps (`milestones/M7.md`). Decided with the user on 2026-10-08: the exit is pixels only; M6's formatting library is renamed `lib/vx-fmt`, leaving `lib/vx-text` to the editor; a terminal is an M7 step.

## 1. Where the tree starts

None of the pixel side exists. The kernel makes no Limine framebuffer request (`kernel/boot.c:12-29`); nothing maps a framebuffer, and the only device mapping is uncached (`kernel/mm/paging.c:10`, PCD|PWT at `kernel/arch/x86_64/arch.c:986`), which a CPU compositor's blits cannot live with. There is no virtio-gpu or virtio-input driver, though the transport (`lib/vx-driver/virtio.c`) and `devmgr`'s matching serve them as they serve blk and net. QEMU runs with `-display none` and no QMP, so no scenario can see a pixel (`build.c` `qemu_cmd`). Nothing is vendored for fonts, shaping or tzdata. `vx-buffer`, rule 7's one currency (01 §6.1), is design only; its timeline fence, the Counter, exists.

What M6 left that M7 stands on: `libvx` level 1 (the loop and its one event record, which `vx_wait` extends), the loader (hot reload), `AS_FIXED`, 9Px `notify`, `sched_ctx` with realtime admission, Lua (`wm`).

## 2. Decisions

1. **Client-owned buffers; the window server only composites.** 9front's clients draw into a server-side image through devdraw's 6k-line memdraw protocol (devdraw.c:1503-2032); Flatland's clients hand over images. M7 follows Flatland: an app renders into its own `vx-buffer` (a VMO, a descriptor, a Counter), and `winsrv` composites. No drawing operations cross the protocol (rule 2: pixels by shared pages). A buffer is named by a handle passed on the channel, never by a global name (devdraw's `DName` race, libdraw/init.c:136-144, is what capabilities avoid).
2. **The frame protocol is Flatland's model on 03 §4's records.** Present costs a credit; a client starts with one and is granted more with each frame event, so a client can never queue unbounded frames and the server never blocks (Flatland's `OnNextFrameBegin`, flatland.fidl:494-528; 03 §4's `present` fails fast). The frame event carries the target and the previous frame's actual presentation; feedback carries `actual`, `zero_copy`, `dropped`. Records travel on the window's ring (03 §4); `/wsys/self/frame` is the same records as text for scripts.
3. **Release by composite, not by vblank.** With a CPU compositor a buffer is free once it has been copied, so `release` comes at the end of the composite; only direct scanout holds it to the next vblank (Fuchsia's release-fence rule, release_fence_manager.h:21-48). M7 has no direct scanout of client buffers (one plane), so a client double-buffers with no stall.
4. **displayd and winsrv are separate, as the display coordinator and Scenic are.** `displayd` owns outputs and the engine protocol (ADR-0026: `INFO`, `IMPORT`, `CHECK`, `APPLY(stamp)`, `VBLANK(time, stamp)`); `winsrv` is its one client and gives it one full-screen layer it composited. The engine protocol is written first as `docs/proto/display.md`, with simplefb its first user, as ADR-0026 asked. Both back ends are one opaque layer; vblank is the back end's (virtio-gpu has none: a timer at the output's refresh, never Fuchsia's fixed 30 Hz, display-engine.cc:80) and flushes cover the damage, not the screen.
5. **Write-combining mappings.** A physical VMO gains a cache policy (`VX_CACHE_WC`: PAT write-combining on x86_64, Normal non-cacheable on aarch64), set by its owner before mapping, as Fuchsia's `vmo_set_cache_policy` does; ADR. The boot framebuffer is handed to `devmgr` as a physical VMO with WC, as the boot console was handed to the UART driver.
6. **Input records.** Keyboards report HID usages with the held set after each event (9front's kbdfs sends the whole held set, kbdfs.c:670-700, which makes chords and focus changes trivial), the modifiers and the unmodified rune (03 §5); pointers report absolute or relative positions, buttons and a device timestamp on the one clock, batched per wake, never merged (01 §5). Binary records on a ring between driver, `winsrv` and the focused window; `/dev/input/*/events` reads the same as text. `docs/proto/input.md`.
7. **Focus and routing.** Click to focus, the stream latched to its window while a button is held (Fuchsia's mouse_system rule, mouse_system.cc:80-121; rio's, rio.c:560-639); a window losing focus gets its held keys released. Coordinates are the window's. An IME interposes as rio's `kbdtap` does (rio.c:351-419), in-server per 03 §5.
8. **Per-app views by attach, rio's trick.** Attaching to `/wsys` with `new …` makes a window and gives the app `/wsys/self` (rio's attach spec, xfid.c:168-243); the whole tree is a grant (ADR-0029). 03 §5's tree is the one built; 02 §5.5's older sketch (`/wsys/ctl new` at the root, `outputs/DP-1/frame`) is rewritten to match.
9. **v1 carries fields M7 cannot drive.** VRR's `target_min`/`max`, tearing (`present async`) and HDR (`vx_buffer_desc`'s transfer function, primaries, mastering) are in the v1 records, so version 1 never changes (rule 9); QEMU's outputs say they have none, `async` is refused with a reason, and feedback never says `tearing=yes`. The engine protocol's v1 stays flip-only, as ADR-0026 has it: the two v1s are different layers.
10. **Fonts.** stb_truetype and kb_text_shape, vendored with ADRs (D13); one font family (Inter, OFL) in `/lib/font`; the glyph atlas in `vxui` keyed by font, glyph, size and subpixel offset, a fixed-cell cache with oldest-slot eviction (libdraw's, font.c:163-200). 03's 1x check: small text at terminal sizes against a reference rendering, before the choice is final.
11. **Testing sees pixels.** `qemu_cmd` gains a QMP socket, virtio-gpu, a virtio keyboard and tablet; a scenario's `screen=` captures the output (`screendump`) and compares it with a reference image within a tolerance, and `type=`/`click=` drive input. aarch64's virt machine has no display but virtio-gpu, so simplefb is tested on x86_64 (OVMF's GOP) and virtio-gpu on both.

## 3. Contradictions settled

| Where | Settled |
|---|---|
| 03 §6's 12-call program needs sound (M13) and a gamepad (M9) | M7's exit is the 10-call program and the CPU pixel program; the 12-call program is M13's exit, its sound and gamepad calls numbered in `vxui` v0 (user, 2026-10-08) |
| `lib/vx-text` is M6's formatting and 08's piece tree | M6's becomes `lib/vx-fmt`; `lib/vx-text` is the editor's (user, 2026-10-08) |
| The terminal is measured by three M7 budgets but scheduled nowhere | An M7 step (user, 2026-10-08) |
| ADR-0026: virtio-gpu "in M7 and M8"; 04: virtio-gpu 2D in M7 | 2D in M7, Venus in M8 |
| 03's v1 has VRR, tearing, HDR; ADR-0026's engine v1 has none | Both hold: the /wsys records carry them, the engine is flip-only (§2 item 9) |
| 02 §5.5's `/wsys` tree against 03 §5's | 03's; 02 is rewritten (§2 item 8) |
| 07's header: nothing before M11; 07 §12: the plumber at M7 | M7 |
| 00 §8's M7 budgets on T1, which is now M9 | Measured under KVM by `./build bench` in M7; the T1 figures and the photodiode rig with M9 |
| GPU wording at M7 (03 §9's bevels, "GPU glyph atlas") | M7 is CPU: `vxui`'s CPU renderer and `winsrv`'s CPU compositor; Vulkan is M8 |
| known-gaps: "one profiling ring per process", due 6d | Stale: one ring per thread since 6d6b; the row goes |

## 4. Open, for later steps

03 §10's questions (remote windows, the shell's grant, `super+shift+h`, "Explain this window", dock pins, undoing "always ignore"), ADR-0026's (INFO's constraints, several outputs per engine), 20 §10's, 08 §18's piece tree against a rope, are taken up by the step that meets them, not here.

## 5. The steps

The order follows the dependencies: tracing first (20 §9: the desktop's budgets are latency problems across processes), then the path from a pixel to the screen, then input, then the window server, then fonts and `vxui`, then the programs.

- **7a1–7a5.** Tracing and profiling, as already stepped (20).
- **7b. Seeing pixels.** 7b1 the rename to `lib/vx-fmt`; the harness's QMP, `screen=` and input keys; the kernel's WC cache policy (ADR) and the boot framebuffer as a physical VMO. 7b2 `vx-buffer` (descriptor with v1's HDR fields, the Counter timeline) and `docs/proto/display.md`. 7b3 `displayd` with the simplefb back end: one output, adopted from the firmware, a timer vblank, damage flushes; a scenario's screenshot of a test pattern. 7b4 `drv-virtio-gpu` 2D: resources over guest VMOs, scanout, transfer and flush of the damage, EDID; both architectures.
- **7c. Input.** 7c1 `docs/proto/input.md` and `drv-virtio-input` (keyboard, tablet, mouse), `/dev/input`; the console's input from it, so a machine with no serial line can type.
- **7d. The window server.** 7d1 `winsrv` v0: the window tree, the CPU compositor with damage, one frame clock per output, the frame protocol with credits and feedback, `/wsys` and per-app attach (03 §5), configure and resize, focus and routing. 7d2 `wm` (Lua) and decorations, `vx-magic` drawn on the CPU; the trusted prompt path (physical input only, the mark only `winsrv` draws); the keymap, compose and repeat; the IME host's interface.
- **7e. Text and `vxui`.** 7e1 stb_truetype, kb_text_shape and Inter vendored (ADRs), the atlas, the 1x check. 7e2 `vxui` v0: `vx_wait` over the loop with windows bound, immediate mode with a retained cache, stable ids, the per-frame arena, sticky errors; `vx_pixels_begin`/`present`; the minimal program in 10 calls and the CPU pixel program, as scenarios with screenshots (M7's exit).
- **7f. The terminal.** A `vxui` terminal for rc over `ptyd`; keypress to glyph and `cat` of 1 GiB measured.
- **7g. The rest of 04's row.** 7g1 `lib/vx-text` (08 §16) and `dbg`'s GUI v0 with the timeline (tracks, flows, samples, frame events). 7g2 hot reload (03 §6.1). 7g3 the plumber, with the terminal its first client. 7g4 tzdata compiled to TZif under `/lib/zoneinfo`, the local zone in `/cfg`, `TZ` in `/env`.
- **7h. Close.** `./build bench` holding M7's budgets under KVM; the exit test.

**The exit test.** On both architectures under QEMU: the minimal program (10 calls) and the CPU pixel program each show their window, matched by screenshot; typing into the terminal runs an rc command whose output is matched; the budgets 7h holds pass.
