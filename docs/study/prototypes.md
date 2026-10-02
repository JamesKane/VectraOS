# Prototype measurements (S7)

_From the study's S7 report, 2026-09-27, with re-runs on 2026-09-28. Section and finding numbers match the original, because the blueprint cites them ("S7 finding 5", "S7 §3")._

Five programs were each written three ways, on a 60 Hz macOS host, plus a C-ABI minimal program:
- **candidate:** the API the study's toolkit charter proposed, run through a macOS shim;
- **SDL3:** built from the pinned corpus commit;
- **native:** AppKit, Metal, GameController and Core Audio.

The five programs were a minimal program, a game loop, a text editor, a synth UI, and GPU compute to display. All runtime numbers are **macOS-host baselines**. VectraOS's own numbers come when `winsrv` runs; they become the budgets in 00 §8.

## 1. Against the exit criteria

| Criterion | Result | Verdict |
|---|---|---|
| **Minimal:** ≤ 13 calls to window + frame + input + sound | candidate **12** call sites (C ABI **10**), SDL3 11, native 40. Heritage bar: Amiga about 12, Switch 13, Mega Drive 7, GEM 25. Game loop: candidate 10 toolkit sites, plus **26 `webgpu.h` sites** to reach the first GPU frame; SDL3 18; native 106 | **Pass on the toolkit surface.** GPU setup through `webgpu.h` costs more than the whole SDL program (§3.1) |
| Frame-pacing error p99 ≤ 1 ms | candidate **0 ms** at steady state, from actual presentation times; native 0 ms; SDL3 about 6 ms (no presentation feedback). Under live resize, candidate p99 33 ms with 22 of 466 frames dropped, because Metal reports no presentation time during a resize | **Pass at steady state**; live resize limited by the host |
| No timer-resolution call | none in any variant | Pass (macOS has no such knob, so it would not show) |
| **Editor:** zero dropped frames scrolling at display refresh | candidate 0/592; SDL3 0; native 0. Re-run with the display awake: 606 frames, p99 16.667 ms, 0 dropped, 0 idle wake-ups | **Pass at 60 Hz**; 120 Hz untested |
| IME composition with no app code beyond the adapter | preedit inline, commit, candidate window at the caret. The editor app is **44 lines** against 365 (SDL3) and 367 (native). Confirmed by a person with real input methods, 2026-09-28 | **Pass** |
| Live resize without artefacts | candidate: 88 configures → 88 presents at the new size; configure-to-present p50 9 ms, max 18 ms; the loop never blocked. A conventional AppKit pump stalled for 2,092 ms | **Pass by measurement** |
| **Synth:** no locks on the callback path | candidate: checked by the compiler, and a deliberate violation fails to build. SDL3: **3 locks per callback inside SDL** | **Pass** |
| Period and latency reported exactly | candidate: 128 frames, 8.44 ms from the contract record, matching native's hand-assembled figure. SDL3 reports 128 but delivers 4×128 bursts every 10.67 ms with ≥ 32 ms latency, and reports neither | **Pass** |
| No underruns at a 128-frame period under UI load | candidate 0 in 22,831 callbacks; native 0; SDL3 0. Re-run: 3,646 UI frames over a 60 s soak, 0 underruns, 0 callback allocations | **Pass** |
| **Compute:** zero copies from compute to composition | native 0; candidate 0 with a 7-line fix to wgpu-native (1 with the pinned release); SDL3 1, which cannot be removed (SDL_gpu window textures are render-target only) | **Pass**, conditional on the fix |
| GPU budget reported by the system | native: Metal's heuristic working-set size; SDL3: no API | Not tested for the candidate |
| **All:** nothing presented when idle | candidate 0 idle wake-ups/s; SDL3 0–0.14; native 1.44 in the editor and 61 in the minimal program (MTKView keeps drawing) | **Pass** |
| Every event source in one wait | timers, fd readiness, post, wake and a real audio-contract change all arrive through one `wait`, on the main loop and on a background loop | **Pass** |
| No modal call exists | by construction; the shim absorbs macOS's live-resize loop | **Pass** |

## 2. What it costs to give macOS apps this API

About 1,100 lines of shim exist only to hide macOS rules that a platform designed this way doesn't have:

| Lines | Workaround | Friction | On VectraOS |
|---|---|---|---|
| ~107, 57 of them arm64 assembly; high risk | AppKit event dispatch run on a second stack, so the live-resize tracking loop cannot capture the app's wait | F-201, F-202 | gone: no main thread, no modal loop (rule 9) |
| ~200 | one wait built from run-loop sources, timers and observers | F-201 | `port_wait` (01 §4.4) |
| ~190 | audio contract assembled from five device properties; period set per device; default device followed by hand | F-216 | `audiod`'s contract record (03 §7) |
| ~120 | windows only on the main-thread loop | F-201 | any thread |
| ~100 | CPU surface on IOSurfaces; damage cannot be forwarded | F-208 | present with damage rects (03 §4) |
| ~90 | frame clock; actual present time for GPU surfaces only | F-101, F-102 | frame events with presentation feedback (03 §4) |

The native variants needed the same workarounds, written by hand in each app: transactional presents, display links in common run-loop modes, pointer lock assembled from four calls, latency summed from four properties. SDL3 hides some of them. It cannot hide missing presentation times, the live-resize timer, an audio thread that isn't real-time, or the compute copy.

## 3. Findings that changed the design

1. **GPU setup through `webgpu.h` is verbose:** 26 calls to the first GPU frame, against 12 for the whole CPU-surface minimal program. The toolkit needs a short path to "a GPU surface ready to draw". → `vx_gpu_surface(win)` returns a configured Vulkan device, queue and swapchain in one call (03 §3). VectraOS went further and dropped `webgpu.h` as the toolkit's drawing API.
2. **Zero-copy compute to display works,** once a 7-line wgpu-native bug is fixed (its texture-usage conversion dropped storage binding for surfaces). → On VectraOS, the buffer currency (rule 7) makes compute-to-display zero-copy by construction.
3. **Surface size independent of window size.** A fixed-size simulation should not need a rescale dispatch when the window resizes; the compositor should scale. The study asked for a viewport or buffer-size request on GPU surfaces (Wayland's `wp_viewporter`). → Not yet explicit in 03 §5; an open item for the `/wsys` v1 freeze.
4. **Real-time audio code needs a narrow, checkable discipline.** The study's Swift prototype passed compiler checks for no locks and no allocation only with a documented subset (no libm, no class first-use, no short-circuit operators), and the checker couldn't see into C calls. → VectraOS's callback is a plain C function on an admitted thread that must not allocate or lock, and a debug build traps if it does (03 §6, principle 5).
5. **CPU surfaces need presentation feedback too.** On the host, CPU-surface frames got only estimated times; it is not automatic. → Exact feedback for CPU surfaces is required (03 §4).
6. **UI in 44 lines.** The editor needed 44 lines of app code over a 1,163-line UI module, against about 365 for SDL3 or native, with 0 allocations per frame in layout and paint. The gap was **text shaping** (one character = one glyph). → `vxui` shapes text from v1 with kb_text_shape and rasterises with stb_truetype into a glyph atlas (03 §6, principle 2).
7. **Allocation accounting on the host:** a malloc zone hook counts nothing on current macOS, and dyld interposition works. Every audio-thread claim above was checked with interposition and a deliberate allocation test. Not design-relevant.

## 4. Open questions it answered

| Question | S7 answer | VectraOS |
|---|---|---|
| `webgpu.h`, or a smaller drawing API? | `webgpu.h` plus a one-call GPU-surface helper; the CPU surface plus the UI module covers 2D and tools at heritage call counts | Neither: a first-party Vulkan 2D renderer inside `vxui`, raw Vulkan for engines, and the CPU buffer path (03 §3, §6) |
| An immediate layer in v1? | Untested; defer until after the retained core | `vxui` is immediate-mode at the API (03 §6) |
| One loop per app, or per window? | Both worked; one per app by default | One `vx_wait` per app; any thread may run its own |

## 5. What was left unmeasured

- Manual checks for keyboard and gamepad, pointer lock, trackpad feel, resize artefacts and audible synth notes.
- Native Win32 and Wayland variants were not built; their costs come from the corpus.
- Platform numbers on the real system. These are the 00 §8 budgets, measured by `./build bench` from the milestone that makes each one measurable.
