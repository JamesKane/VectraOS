# Heritage platforms: what simplicity was lost (Q6)

_From the study's heritage phase (SH), 2026-09-27. Section numbers match the original report, because the blueprint cites them ("heritage §4")._

**Question:** what did AmigaOS/Intuition, Atari TOS/GEM and consoles with open SDKs do simply that modern platforms made complicated, and is the added complexity paying for something?

**Short answer:**
- **One simple idea recurs everywhere:** one wait for everything, a frame clock you can wait on, timers with absolute deadlines, and one request/reply protocol for devices. Modern platforms split each of these into several mechanisms, and that split is the main source of F-201, F-203 and F-101/F-102.
- **The complexity pays for real things:** protection, SMP, Unicode and IME, mixing, compositing and scaling, and hot-plugged heterogeneous hardware.
- **The heritage systems also left warnings:** global locks, modal loops inside platform calls, pointer-passing IPC and manual cache maintenance.

VectraOS keeps the simplicity and pays only for the complexity that buys something. Its shape (one `Port` wait, 9Px for every device, its own compositor) is closer to Exec and Horizon than to Win32 or AppKit.

## 1. Scope and method

| Family | Platforms | API source | Usage corpus |
|---|---|---|---|
| Amiga | AmigaOS 3.1 | AROS function lists and headers | AROS Workbench, aros-contrib: 4,100 files |
| Atari | TOS, GEM AES/VDI, MiNT | FreeMiNT `syscalls.master`, gemlib | EmuTOS desktop, FreeMiNT tools, XaAES tests |
| Consoles before about 2006 | N64, PS1, PS2, PSP, Dreamcast, Mega Drive, GBA, DS, GameCube/Wii | libdragon, PSn00bSDK, ps2sdk, pspsdk, KallistiOS, SGDK, libgba, libnds, libogc | SDK examples and ports |
| Recent consoles, open SDKs | 3DS, Switch, Vita | libctru, libnx, vita-headers | devkitPro and switchbrew examples; SDL's console backends |

Official SDKs under click-through licences, and leaked SDKs, were excluded.

**Filtering dead hardware.** An API whose purpose exists only because of hardware with no successor since about 2006 was classed *obsolete*. An API whose intent survives was mapped to its modern concept instead: `WaitTOF`/vblank to frame pacing, display lists to command recording, DMA audio to stream push. The obsolete share of usage is 0.8–2.9% on GameCube/Wii, Atari, Amiga, N64 and 3DS (the programming model outlives the hardware), and 36–41% on the Mega Drive and GBA, whose APIs largely *are* the tile hardware.

## 2. API surface

Mapped calls per platform, and calls per concept:

| Platform | Mapped calls | Concepts | Calls per concept |
|---|---:|---:|---:|
| Atari | 736 | 64 | 11 |
| Amiga | 1,080 | 79 | 14 |
| Dreamcast | 777 | 59 | 13 |
| GameCube/Wii | 799 | 57 | 14 |
| Haiku | 1,936 | 87 | 22 |
| Switch (libnx) | 2,201 | 78 | 28 |
| macOS | 3,991 | 143 | 28 |
| Linux (userland libraries + UAPI) | 9,168 | 90 | 102 |
| Windows | 10,968 | 157 | 70 |

Calls per concept for operations every interactive program needs:

| Concept | Amiga | Atari | Switch | Haiku | Plan 9 | Windows | macOS | X11 | Wayland |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Create a window | 3 | 9 | 4 | 2 | 4 | 26 | 18 | 34 | 6 |
| Wait for events | 9 | 7 | – | – | 2 | 7 | 1 | 4 | 2 |
| Present | 2 | 2 | 3 | 13 | 1 | 18 | 8 | 13 | 3 |
| Frame pacing | 7 | 1 | 1 | 1 | – | 21 | 33 | 2 | 5 |
| Timers | 8 | 4 | 3 | 14 | 2 | 12 | 33 | – | – |
| Push audio | 26 | 4 | 30 | 34 | – | 49 | 26 | – | – |
| Clipboard | 4 | 8 | – | 14 | – | 28 | 57 | 15 | 28 |

Windows and macOS spend their surface on *alternatives*: several windowing, audio and timing generations side by side. The heritage platforms have one way to do each thing. Breadth of concepts is real progress (Windows covers 157 concepts, Amiga 79); duplication within a concept is not.

## 3. Minimal programs

Window or video, plus a frame, input and sound, counted from real programs in the corpus:

| Platform | Program | Distinct calls |
|---|---|---|
| Mega Drive | SGDK samples | 7 |
| Vita | vita examples / SDL-vita | 8 (+2 teardown) |
| Amiga | cxhextris `arosio.c` plus `workbench/c/Play.c` | about 12, with 2 created objects, one thread, no callbacks |
| Dreamcast | KallistiOS example | 13 |
| 3DS / Switch | devkitPro / switchbrew examples | 13 (+3 teardown) |
| N64 | libdragon example | 18 |
| GEM | XaAES `tests/tbarmenu.c` | 25 call sites (21 functions) |
| GameCube/Wii | libogc example | about 48 |

These set the bar: **12 calls or fewer** for the minimal program (03 §1, §6). The modern native equivalent measured 40 on macOS (S7, [prototypes.md](prototypes.md)).

## 4. The simple ideas and what they would fix

| Heritage mechanism | Where | Modern state | Friction | What VectraOS keeps |
|---|---|---|---|---|
| **One wait for everything.** Exec `Wait(sigmask)` covers window, timer, device, IPC and Ctrl-C in one call: 138 of the 418 `Wait()` calls in the Amiga corpus combine several sources. GEM `evnt_multi` covers keyboard, mouse, message and timer. Horizon waits on up to 64 kernel handles. | Amiga, GEM, Switch/3DS | Several loops (run loop, message pump, fds, GPU fences, audio callbacks), each owned by a different framework | F-201, F-202 | Every source delivers into a `Port`, and one `port_wait` waits on all of them (rule 4; 01 §4.4) |
| **Self-post wake.** Exec `Signal`; a GEM app writing to its own AES id. | Amiga, GEM | Separate wake primitives, or a fake message | F-201 | Wake by posting to your own port (`port_post`); no separate primitive |
| **A frame clock you can wait on.** `WaitTOF`, TOS `Vsync()`, console vblank waits. On the Mega Drive, `SYS_doVBlankProcess` paces the frame, flushes uploads and reads the pads. | all | Display links, frame callbacks and present statistics, different per platform; exact presentation time mostly unknowable | F-101, F-102 | The frame event is one more source in the wait, and carries the *actual* presentation time of the previous frame (rule 8; 03 §4). Owning scan-out lets VectraOS promise what even the Switch does not |
| **Timers as requests with absolute deadlines.** Amiga `timer.device` delivers expiry into the same `Wait`, with no global resolution knob. | Amiga | `timeBeginPeriod`, spin-sleep hybrids; no absolute-deadline sleep in any Tier A project | F-203 | Absolute deadline with leeway, integrated with the one wait; the kernel decides precision (rule 5) |
| **One request/reply protocol for every device.** Exec IORequest: `DoIO`, `SendIO`, `WaitIO`, `AbortIO`. It is essentially 9P, with `AbortIO` as `Tflush`. | Amiga, Plan 9 | A different API per device class | F-216, F-217 | 9Px for audio, input, timers and storage (02 §3); `Tflush` is `AbortIO` (02 §3.3). Plus the protection Exec lacked: no data passed by pointer between tasks |
| **Shared-memory rings for fast state.** Horizon's HID, time and GSP interrupt state is mapped into the app, so reading input costs no IPC. | Switch, 3DS | Input through event queues and IPC; present timing through queries | F-101, F-210–F-213 | Rings for bulk and hot paths, files for control (rule 2; 01 §4.3) |
| **Known, exact budgets.** 1 MB of PS1 VRAM, 4 MB of PS2 GS eDRAM, 2,048 polygons per DS frame. | consoles | GPU budget and residency are guessed | F-109 | Kernel memory budgets that include GPU buffers, with a pressure port (01 §5) |
| **Audio off the application's real-time path.** Dedicated sound processors; a DSP mixer with a fixed period on Switch and 3DS. Frame-loop mixing glitches on overrun, which is F-215 in miniature. | consoles | Three real-time thread mechanisms; apps mix on their own thread | F-215, F-216 | `audiod` mixer with a fixed period and deadline-scheduled streams; voices with no callback (03 §7) |
| **Reserved cores and strict priorities.** On the Switch, core 3 belongs to the system. | Switch | No portable core-intent API; apps probe | F-204 | Intents plus whole-core reservations (rule 6; 01 §8) |
| **Nothing compiled at runtime.** Microcode shipped precompiled; state changes are register writes. | consoles | Pipeline compilation at first use | F-103 | SPIR-V compiled at build time; pipeline cache warmed at install (03 §3) |

## 5. What the complexity pays for, and what not to copy

**Worth paying for, and absent from the heritage systems:**
- memory protection and resource tracking (Exec shares one address space, and a crashing app takes its signals with it);
- SMP (`Forbid()`/`Permit()` is a global lock);
- Unicode and IME;
- system audio mixing and routing;
- compositing, fractional scaling and colour management;
- hot-plugged, heterogeneous devices and GPUs;
- security boundaries between applications.

**Do not copy:**
- **Global locks:** Exec `Forbid`; GEM `wind_update(BEG_UPDATE)`, which XaAES kept as a cross-process semaphore, so one application can still freeze the desktop.
- **Modal loops inside platform calls:** `form_do`, menu tracking and `graf_dragbox` run the loop for the app. This is F-202 at desktop scale.
- **Client-redrawn exposes as the only damage model:** GEM's redraw storms. VectraOS's compositor retains surfaces.
- **Pointer-passing IPC:** Exec messages carry pointers into the sender's memory.
- **Manual cache flushes before every DMA:** a recurring cost on every console, and the ancestor of F-106. In VectraOS the kernel does cache maintenance for non-coherent DMA, and user space never issues cache instructions (01 §6.2).

All four warnings are rule 9 or rule 7 in the blueprint, and the last row of 00 §6.

## 6. Evolving an API: FreeMiNT and XaAES

MiNT and XaAES retrofitted multitasking and a Unix-style kernel onto GEM without breaking applications.

**What worked, all additive:**
- new syscall numbers above the TOS range;
- services exposed as files under `u:\`;
- per-process opt-in with `Pdomain`;
- capability queries with `appl_getinfo`;
- `mt_*` variants that take an explicit context, with the old names kept as macros.

**What did not work:** semantics baked into version 1 could not be removed. The global screen lock and the modal loops survived even after XaAES moved the window server into the kernel for speed.

**Consequence:** whatever the first version of a protocol promises, and fails to rule out, is permanent. So every VectraOS protocol ships without a global lock, without system-run modal loops, and with capability queries from day one (rule 9; 9Px version negotiation, 02 §3.1; `/wsys/info`, 03 §5.1).

## 7. Taxonomy changes the heritage work proposed

These named friction sources the modern taxonomy had hidden: system-run modal loops (`EVT.modal`, F-202), system- or DSP-rendered voice mixers (`AUD.voice`, which became `audiod` voices), hardware audio decode, clock and power profile requests (with F-204), and input synthesis. Exec signal masks, ports, IORequests and screens were recorded as *mechanisms* that unify concepts, not as concepts of their own; that finding is §4.

## 8. Recommendations it made, and where they landed

1. **One loop, one wait.** → Rule 4; `vx_wait` (03 §6, principle 1).
2. **The frame event carries the truth:** actual presentation time and sequence of the previous frame, and the target for the next; no separate display-link object. → Rule 8; 03 §4.
3. **Timers, audio and input are requests on one protocol,** with absolute deadlines, no resolution knobs, and shared rings where state changes fast. → Rules 2, 5; 02 §3.
4. **Known budgets:** GPU memory and audio period reported exactly by the system. → 01 §5; 03 §6 principle 6; 03 §7.
5. **Version 1 of the window protocol has no global lock and no modal loops,** and has capability queries. → Rule 9; 03 §5.1.
6. **Minimal-program target:** no more calls than the Amiga (about 12) or the Switch (13). → 03 §1 and §6: 10 calls for `vxui`, 12 or fewer for the CPU-buffer path.
