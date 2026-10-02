# Productive shapes, and where the wrappers converge (Q2)

_From the study's Q2 report, 2026-09-27. Citations are `project@commit path:line`; [README](README.md) has the commit pins._

**Question:** where several projects wrap one concept, which wrapper shape recurs, and what does the recurring wrapper add or hide?

**Libraries studied (13):** SDL3, GLFW, sokol (app, gfx, audio), raylib, winit, wgpu, Dear ImGui, egui (with eframe), bevy, Godot, zed's gpui, JUCE and LÖVE. A shape counts as convergent only if it recurs in three independent layers (bevy is not counted apart from winit, nor raylib from GLFW).

**Short answer:**
- The layers developers program against converge on:
  - one fixed-size tagged event record carrying a window id;
  - a loop with two modes (wait and poll) plus a deadline;
  - a coalesced "redraw requested" signal, paced by a per-output display clock;
  - resize and scale as events that separate logical from physical size;
  - a native-handle bag handed to the GPU API;
  - index-plus-generation handles wherever an object crosses a boundary;
  - a per-frame arena for UI scratch;
  - two-tier audio: a stream (pull callback plus push), and voices over a mixer;
  - theme-owned styling.
- The recurring wrappers exist mostly to hide three platform facts: **the main thread**, **the system modal loops** and **the swapchain**.
- VectraOS removes the first two by design (F-201, F-202), so it can adopt the convergent shapes without the workarounds.

## 1. API surface

Grep counts of public declarations, so approximate:

| Library | Public functions | Public types |
|---|---:|---:|
| SDL3 | 1,316 (GPU 97) | 297 |
| GLFW | 124 + 27 native | 8 (33 with callback typedefs) |
| sokol | app 56, gfx 156, audio 11 | app 70, gfx 262, audio 22 |
| raylib | 619 | 58 |
| Dear ImGui | 593 | – |
| winit (winit + winit-core) | 117 (+76 in the `Window` trait) | 114 |
| wgpu (wgpu + wgpu-types) | 368 + 230 | 220 + 229 |

The thin layers (GLFW's 151 functions, sokol_app's 56, sokol_audio's 11) cover the same window, input and frame concepts as SDL's 1,316. SDL's extra size is breadth (GPU, audio, gamepad, storage, process, tray), not a deeper take on the same concepts. Main-thread rules are a large share of the portable layers' documentation: GLFW marks 93 functions "must only be called from the main thread", and SDL has 273 such doc lines. Rust layers (winit, gpui) encode the rule in types instead (`!Send` event loops, main-thread markers).

Of the layers' own platform calls: SDL touches 140 concepts on 10 platforms; GLFW 79, winit 59, raylib 61, sokol 97. bevy touches 3, because it reaches every platform through winit and wgpu, which is the wrapper stack working as intended.

## 2. Convergent shapes

**C1. One fixed-size, tagged event record carrying a window id.**
- SDL's 128-byte union, asserted at compile time (SDL@1ce4c5bc29 `include/SDL3/SDL_events.h:1157-1161`); sokol's single `sapp_event` (sokol@2e75443dbd `sokol_app.h:1616-1636`); ImGui's fixed input-event queue (imgui@aa0181478b `imgui_internal.h:1598-1612`).
- Rust layers reach the same shape as enums: winit `WindowEvent`, egui `Event`, gpui `PlatformInput`.
- The window id is a small integer, never a pointer.
- No record holds variable-length data inline. SDL points into temporary strings freed on the next pump (`src/events/SDL_events.c:1531`).
- Exceptions: GLFW's per-kind callbacks (which can't be queued or replayed), Godot's refcounted per-event objects, LÖVE's untyped Lua tuples.

**C2. A loop with two modes, wait and poll, plus a deadline.**
- `SDL_WaitEvent`/`PollEvent`; `glfwWaitEvents`/`PollEvents`; winit `ControlFlow::{Wait, Poll, WaitUntil}` (winit@8b5f46d4be `winit-core/src/event_loop/mod.rs:504-523`); bevy's `desktop_app()` and `game()` presets; egui `request_repaint_after`.
- The deadline form converges on "wait for events or until time T". None of these layers uses an absolute-deadline sleep underneath (F-203).

**C3. Inverting the loop where the platform forces it, keeping the app-owned loop where it doesn't.**
- Callback mains (SDL's optional one, sokol's mandatory one, the `run()`s of winit, gpui, Godot, JUCE and LÖVE) exist for platform entry points, iOS and the web.
- App-owned loops survive in the desktop layers: GLFW, raylib, ImGui, egui's core, SDL's classic mode.
- **Only the inverted form gets live resize.** SDL renders during Win32 and Cocoa live resize only in callback mode (`src/video/SDL_video.c:4334-4344`).

**C4. Re-entering the frame function from inside the system modal loop.**
- The identical `SetTimer(USER_TIMER_MINIMUM)` on `WM_ENTERSIZEMOVE` in SDL, sokol, Godot and gpui; Cocoa equivalents in SDL, Godot and LÖVE.
- 9 of the 13 layers reference the modal markers. This is F-202 seen from the wrapper side.

**C5. A main-thread proxy plus a payload-free, coalesced wake.**
- `SDL_RunOnMainThread`; winit `MainThreadBound`; JUCE `callAsync`; gpui `dispatch_on_main_thread`; Godot `CommandQueueMT`.
- The wake is a single coalesced "wake up" with no payload, implemented differently per platform: a CFRunLoopSource, `PostMessageW`, a calloop `Ping` or a channel.

**C6. A coalesced "redraw requested" signal, paced by a per-output clock the layer runs itself.**
- winit `RedrawRequested`, gpui `cx.notify`, egui `request_repaint`.
- gpui runs one `CVDisplayLink` per display plus a `DwmFlush` thread (zed@1a28cff4b4 `crates/gpui_macos/src/display_link.rs:17-56`); JUCE runs display links and a `WaitForVBlank` thread.
- Pacing lives in the frame callback, not in `present()`.

**C7. Resize and scale as events, with physical size separate from logical size.**
- SDL `PIXEL_SIZE_CHANGED` and `DISPLAY_SCALE_CHANGED`; winit `SurfaceResized` + `ScaleFactorChanged`; gpui `on_resize(size, scale)`; Godot `WINDOW_EVENT_DPI_CHANGE`.
- 12 of the 14 layers touch display scale. Every UI layer lays out in logical units.

**C8. GPU hand-off through a native-handle bag; the swapchain reduced to "configure, acquire, present".**
- raw-window-handle in winit, gpui and bevy; SDL's property bag; sokol's `acquire_swapchain`.
- wgpu reduces image count and queue depth to one number, `desired_maximum_frame_latency` (wgpu@babefc0d26 `wgpu-types/src/surface.rs:940-970`).

**C9. Index-plus-generation handles wherever an object crosses a boundary.**
- sokol `{id}` = generation << 16 | slot (`sokol_gfx.h:6605-6607`); Godot `RID` = validator << 32 | index (godot@b13043816a `core/templates/rid_owner.h:157-162`); bevy `Entity` = index + generation; gpui `EntityId` as a slotmap key.
- Three independent designs, in C, C++ and Rust, reached the same layout. Inside a process refcounting is common; at a boundary, ids win.

**C10. Two-tier audio: a stream (pull callback plus push), and voices over a mixer.**
- Streams: `SDL_AudioStream`, sokol `stream_cb`/`saudio_push`, raylib `AudioStream`, JUCE's pull callback.
- Voices: Godot's bus mixer, bevy's per-entity player, LÖVE's OpenAL source pool, raylib `Sound`.
- Push is framed as the fallback. No layer lets the app choose its callback thread's scheduling class (F-215).

**C11. Centralised styling, and retained state keyed by id with per-frame scratch.**
- Styling outside the widget: ImGui `ImGuiStyle`, egui `Style`, Godot `Theme`, JUCE LookAndFeel.
- Retained state keyed by id, scratch rebuilt per frame: ImGui's ID stack + `ImGuiStorage`; egui `Id` + `IdTypeMap`; raddebugger's box cache keyed by `UI_Key` with double-buffered build arenas (raddebugger@2c226d8a4b `src/ui/ui_core.h:660-666`); gpui's retained entities rendered into a 1 MiB per-frame arena.
- Layout uses separate measure and arrange steps (taffy, Godot's minimum size, raddebugger's multi-pass layout). egui's single pass is its documented weak point.

**C12. C layers take a user allocator.** `SDL_SetMemoryFunctions`, `glfwInitAllocator`, sokol's allocator structs, ImGui `SetAllocatorFunctions`, raylib `RL_MALLOC`. sokol goes further with fixed pools and per-frame budgets set at setup: the console "known budget" idea (heritage §4).

**C13. No exceptions across the API; resize is a state, not a failure.** C layers return `bool` plus a thread-local message; sokol logs and treats an invalid handle as a no-op. wgpu reports resize as `Outdated`, which the app answers with `configure`: this is F-208's configuration problem pushed onto the app.

## 3. Divergent shapes

| Shape | Who diverges | Why | Lesson for VectraOS |
|---|---|---|---|
| **No per-event timestamps** | winit, gpui, ImGui, egui, sokol, Godot, LÖVE (SDL stamps every record) | Platform timestamps are on different clocks, or missing (F-101) | VectraOS owns input and the clock, so every event carries a device timestamp on the one system clock (03 §5.1) |
| **Callbacks per event kind** (GLFW), **hidden polled state** (raylib) | GLFW, raylib | Minimal portability; beginner audience | Suits a convenience layer over the event queue, not the base API |
| **Styling at the call site** | gpui, bevy_ui | One app, one design system; ECS uniformity | The user's theme is authoritative (03 §5) |
| **Single-pass immediate layout** | egui, ImGui | No retained tree; costs first-frame jitter | `vxui` is immediate-mode but lays out in a separate pass within the frame (03 §6, principle 2) |
| **The main-thread rule imposed everywhere** | winit, SDL, GLFW | Carry macOS's rule to every OS so code ports | No main thread (rule 9). Keeping the rule would re-import F-201 |
| **Fatal errors by default** | wgpu (the uncaptured handler panics) | WebGPU's async validation model | Never panic on a recoverable condition |
| **No audio** | GLFW, winit, wgpu, ImGui, egui, gpui | Scoped to window, GPU or UI | The toolkit owns audio (F-215, F-216) |

## 4. What the recurring wrappers add or hide

The additions are what applications want: a frame callback that always runs, a wake from any thread, a latency number, id handles, and an input queue that loses nothing. The hidden parts are platform accidents: modal loops, thread affinity, swapchain mechanics and timer resolution. Some examples:

- **SDL's modal-loop timer** only works in callback mode. Classic-loop apps get an EXPOSED event and must draw from an event watch, which is what LÖVE does.
- **sokol** skips per-tick resizes inside the timer because "resizing each frame explodes memory usage".
- **winit** posts a dummy `WM_MOUSEMOVE` to cut the 500 ms caption-click pause (`winit-win32/src/event_loop.rs:1301-1329`). On macOS it doesn't hide the resize loop; it delivers events after the resize.
- **winit's wake** has four implementations, one of which "may be ignored under high contention".
- **JUCE** takes a lock on the real-time audio path (JUCE@72782788ce `modules/juce_audio_devices/audio_io/juce_AudioDeviceManager.cpp:1078`).
- **raylib's `EndDrawing`** sleeps for 95% of the interval and then spins (raylib@2fbb15f49a `src/rcore.c:1649-1687`): F-203 inside a beginner API.
- **LÖVE's `love.run`** hard-codes `sleep(0.001)` after present.
- **bevy_winit's** "continuous" mode relies on a visibility heuristic that is disabled on wasm, mobile and Linux: F-209 seen from the wrapper.

The platform should offer the additions directly, so no program needs the hacks.

## 5. Recommendations, and where they landed

The study wrote these for a Swift toolkit over NeoDarwin's `wsys`. VectraOS's toolkit is `vxui`, a C23 API (03 §6).

| # | Recommendation | Shape | VectraOS |
|---|---|---|---|
| R1 | One fixed-size event record with a 64-bit monotonic timestamp, a window handle, and a payload span valid until the next wait; never an object per event, never a callback per kind | C1 | `vx_event` from `vx_wait`; device timestamps on one clock (03 §5.1, §6) |
| R2 | The app owns the loop, and the loop waits once: `wait(deadline, leeway)` and `poll()` over one wait, with frames, timers, audio contract changes and I/O completions as events in it | C2; F-201, F-203 | `vx_wait(app, &ev, deadline)` over one `port_wait`; zero deadline to poll (03 §6, principle 1) |
| R3 | A callback driver as a thin optional layer, shaped like SDL3's `AppInit/AppIterate/AppEvent/AppQuit` | C3 | **Not adopted.** `vxui` never calls back into the app except for real-time audio (03 §6, principle 1). The hot-reload host is app-owned code (03 §6.1) |
| R4 | No thread affinity, but a post-to-loop primitive and a coalesced wake | C5; F-201 | `port_post`; no main thread (rule 9) |
| R5 | The frame clock belongs to the window system; the toolkit exposes a coalesced "redraw requested"; queue depth is one number; hidden windows get a throttled clock | C6; F-101, F-102, F-209 | 03 §4: `ev.frame`, `ctl latency n`, 1 Hz when hidden |
| R6 | Logical units; resize and scale as one ordered event with logical size, pixel size, rational scale and configuration seq; presents tagged with that seq | C7; F-205, F-208 | Scale as n/120 per window; `config_seq` on every present (03 §4, §5.1) |
| R7 | One surface object handed to the GPU through a handle bag | C8; F-107, F-208 | `vx_gpu_surface(win)` returns a configured Vulkan device, queue and swapchain (03 §3) |
| R8 | Index-plus-generation handles at every boundary; an invalid handle is a no-op with a diagnostic | C9 | Kernel handles are per-task indices into a table (01 §3); generation ids at the toolkit ABI are not yet specified |
| R9 | Two memories: a frame arena and a node table | C11, C12 | A per-frame arena and the library's id-keyed cache (03 §6, principle 2) |
| R10 | Two-tier audio owned by the toolkit: a stream with an admitted real-time callback, conversion and a contract record; voices on the system mixer; no lock on the callback path | C10; F-215, F-216 | `audiod` stream rings, the callback convenience, and voices (03 §7) |
| R11 | Retained widgets with theme-owned style, plus an immediate-mode layer on top | C11 | **Inverted.** `vxui` is immediate-mode at the API, with the retained cache inside the library, after Ryan Fleury's UI series (03 §6, principle 2). Style is theme-owned (03 §5) |
| R12 | No fatal defaults; codes at the C ABI; asynchronous GPU and audio failures as events | C13 | C ABI by construction |
| R13 | No modal API anywhere: dialogs, menus, drag and drop and file choosers are asynchronous objects | F-202; heritage §5–6 | Rule 9; 03 §6, principle 3 |
| R14 | Measure the minimal program against the heritage bar (Amiga about 12, Switch 13) | heritage §8 | An exit criterion: 10 calls for `vxui`, 12 or fewer for the CPU-buffer path (03 §6) |
