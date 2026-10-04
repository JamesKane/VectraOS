# Phase 3 — Desktop rendering and local-first agentic UX

_Blueprint v0, 2026-09-30._

## 1. Goals

- **Frame truth:** every client learns when its frame actually reached the glass, and paces on that (F-101, F-102).
- **Never stall:** no client, policy script or AI workload can make the compositor miss a vblank (rule 8).
- **Three ways to do everything:** each action has a pointer path (WIMP), a key path (tiling or power-user) and a script or agent path (a `ctl` verb). All three drive the same verb.
- **Simple apps are small:** the minimal program (window, frame, input, sound) takes 12 calls or fewer, matching the heritage bar the case study measured (Amiga about 12, Switch 13; [study/heritage.md](study/heritage.md) §3).
- **Idle is idle:** with nothing changing, nothing renders and nothing wakes up.

## 2. Stack

```
 ┌ apps ────────────────────────────────────────────────────────────────────────┐
 │ vxui apps                          │ engines (raw /wsys + Vulkan)            │
 └─────┬──────────────────────────────────────────┬─────────────────────────────┘
       │ /wsys files + surface/event rings        │
       ▼                                          ▼
 ┌ winsrv ─────────────────────────────────────────────────────────────────────┐
 │ window tree · input routing · IME host · frame clock · scene graph           │
 │ compositor (Vulkan; CPU fallback) · decorations (theme-drawn) · a11y broker  │
 │           ▲ layout decisions (async)                                         │
 │     ┌─────┴─────┐                                                            │
 │     │    wm     │  policy process: layouts, bindings, rules (Lua)            │
 │     └───────────┘                                                            │
 └──────┬───────────────────────────────────────────────────────────────────────┘
        │ atomic commit (planes, modes), vblank counter
 ┌──────┴──────┐        ┌──────────────────┐
 │  displayd   │◄──────►│ drv-gpu-* (UMD:  │  Mesa userland (RADV, ANV, NVK, honeykrisp,
 │  (per GPU)  │        │ Mesa; KMD: vx)   │  panvk, turnip, venus) over vx GPU drivers
 └─────────────┘        └──────────────────┘
```

**Why `wm` is a separate process:** a layout script that loops forever, or waits on the network, must not freeze the screen. `winsrv` asks `wm` for a layout *asynchronously* and keeps the last layout until a new one arrives. `wm` can crash and restart without a single window moving.

**`/wsys` is the only window protocol.** The OS ships no Wayland or X11 bridge, no SDL backend and no other compatibility layer (rule 13). Anyone who wants one can port it in their own user land.

## 3. Graphics API and the display path

| Layer | Choice |
|---|---|
| Native GPU API | **Vulkan 1.4 with the VectraOS Vulkan Profile** (`vx-vk-2026`). Guaranteed, not probed: dynamic rendering, synchronization2, descriptor buffers or descriptor indexing, shader objects or graphics pipeline libraries, timeline semaphores, unified image layouts, buffer device address, memory budget, present id/wait and present timing (F-103–F-106) |
| App drawing API | `vxui` draws with its own small first-party Vulkan 2D renderer, falling back to the CPU surface. Apps that need the GPU directly use Vulkan against the profile. A one-call helper, `vx_gpu_surface(win)`, returns a configured Vulkan device, queue and swapchain (S7 finding 1) |
| GL and GLES | None. The OS ships no GL implementation (rule 13) |
| Shader IR | SPIR-V only. GLSL and HLSL are compiled to SPIR-V at build time; there is no shader compiler on the device |
| Pipeline cache | A system service keyed by (app, shader hash, driver build), warmed at install time (F-103) |
| Device identity | Each `/dev/accel/gpuN/info` publishes the device UUID that Vulkan reports (`VkPhysicalDeviceIDProperties`), so two APIs or two processes sharing a buffer know they mean the same device, and `uma=yes|no coherent=yes|no`, so an app chooses the zero-copy path without probing (F-107, F-108) |
| Kernel-side GPU drivers | User-space `drv-gpu-*` processes, each serving the one native `accel` protocol over rings, with explicit sync on `Counter`s only and user-mode queues where the hardware has them. Mesa's drivers are ported to it at their own winsys seam; there is no DRM emulation. `displayd` back ends do modesetting, flip only at first. Only generations whose firmware does power and command processing are supported. Order of work: `simplefb` → virtio-gpu (2D, then **Venus** for Vulkan in QEMU) → Adreno a6xx (the Q8B, T1) → Apple AGX → NVIDIA Turing and later (GSP) → Mali with CSF → AMD RDNA3 and later (MES), last because of its display code (ADR-0018) |

**Displays:** `displayd` is a user-space KMS. Each output has CRTC and plane state, and the commit is atomic: it succeeds or fails as a whole, with no half-applied mode. It serves `/wsys/outputs/NAME/{info,ctl}` and signals a per-output **vblank Counter** from the display IRQ. Under it, each vendor's back end speaks a narrow engine protocol (check, apply, vblank) and knows only its registers; the DisplayPort and EDID code is shared (ADR-0026).

**The cost of kernel-side GPU drivers.** Mesa's user-space drivers need only a new backend at their existing winsys seam, a few thousand lines each. The kernel side is the largest piece of work in the whole system: amdgpu, with its display and power-management code, is hundreds of kLOC. The BSDs reached it through a Linux compatibility shim, which rule 13 rules out. Others did not: Fuchsia's Magma runs Mesa-derived drivers over one IPC protocol on native system drivers, and Haiku runs NVK on NVIDIA's OS-independent kernel modules. Firmware now runs power and command processing on every target, and schedules the queues on most (GSP, MES, CSF, AGX; Adreno's driver still writes the ring), which shrinks the kernel side to firmware loading, address spaces, queue setup, faults, reset and power. ADR-0018 builds on that: one protocol, one generation band per vendor, and display separate from rendering. Each vendor gets an ADR with its line-count estimate.

## 4. Frame lifecycle

```
       winsrv                                   client                         displayd / GPU
 t0  frame event → client ring:               ┐
     {seq=N, target=T_vbl(N+1),               │
      prev_presented=T_actual(N-1),           │
      refresh=8.33ms, flags}                  │
                                              ├─► renders into Buffer B (CPU or GPU)
                                              │   present {window, B, desc, acquire=ctr@v,
                                              │            damage rects, config_seq, target?}
 t1  latch deadline = T_vbl − composite budget◄┘   (ring submit, no syscall when winsrv is busy)
     choose per window: direct scanout plane (fullscreen, compatible modifier)
                        or composite pass (Vulkan; damage-limited)
 t2  atomic commit ───────────────────────────────────────────────────────────────► flip at vblank
 t3  vblank Counter ◄──────────────────────────────────────────────────────────────── IRQ
     presentation feedback → client events: {seq=N, actual=T, refresh, zero_copy=yes|no, dropped=0}
```

- **One clock:** each output has one frame clock, owned by `winsrv`. A window follows the clock of the output it mostly covers.
- **Queue depth:** `ctl latency 1|2|3` bounds the number of queued presents. When the bound is reached, `present` fails fast and never blocks (F-102).
- **Configure sequence:** every present carries the `config_seq` it was rendered for. A buffer rendered for the wrong size is clipped or padded for at most one frame, and never stretched (F-208).
- **One configure record:** a change of size, scale, visibility or focus arrives as one event carrying the logical size, the pixel size, the scale, the `config_seq`, the visibility state, focus, and an `interactive` flag that is set while the user is dragging or resizing the window. Configure events during an interactive resize are coalesced to one per composited frame (F-202, F-205).
- **Buffer size apart from window size:** a surface may keep a fixed size, such as a simulation's grid or an emulator's screen, with `ctl viewport W H`; `winsrv` scales it to the window, so a resize needs no rescaling pass in the app (S7 finding 3, as Wayland's `wp_viewporter`).
- **Variable refresh:** on a VRR output the frame event carries a window, `target_min` and `target_max`, instead of one vblank, and a present may land anywhere in it. `refresh` reports the range. A client that presents late does not wait for the next fixed vblank.
- **Tearing:** a fullscreen window on a direct-scanout plane may ask for `ctl present async`. Flips then happen at once, without waiting for vblank, and feedback reports `tearing=yes`. Composited windows never tear.
- **HDR:** a `vx_buffer_desc` carries the transfer function (sRGB, PQ, HLG, linear), the primaries and mastering metadata. Outputs publish their capabilities in `info`, and `winsrv` maps content to the output. These fields are in protocol v1 even before any driver can drive an HDR output (rule 9).
- **Visibility** has four states, `visible`, `partial`, `occluded` and `hidden`, reported in the configure record and in the window's `info`. Occluded and hidden windows still get frame events, throttled to the rate `/wsys/info` states (`hidden_hz=1`). `present` never blocks and never changes visibility (F-209).
- **Idle:** if no client presents and nothing animates, `winsrv` commits nothing and the GPU stays in its low-power state.
- **CPU surfaces** get exact feedback too, not just GPU ones (S7 finding 5).
- **Compositor budget:** `winsrv` runs its composition thread with `realtime(period=refresh, budget=25% of the period)`: 2 ms at 120 Hz, 0.5 ms at 500 Hz. When a fullscreen window is on a direct-scanout plane, composition does not run at all. It gets the GPU's highest-priority queue and preempts other work mid-dispatch where the hardware allows it (§8.3).

**Performance targets on T1 hardware at 120 Hz:**
- a fullscreen game with direct scanout: input to photon in under 1 frame + 2 ms;
- a composited desktop: under 2 frames;
- compositor GPU time for a typical 4K desktop with damage tracking: under 1.5 ms.

## 5. The window system (`/wsys`)

### 5.1 Protocol properties (normative)

- **No thread affinity.** Any thread holding the files may use them, and a process may multiplex many windows on one thread (F-201).
- **No modal loops.** Menus, drag and drop, move and resize are server-side and asynchronous (F-202).
- **Server-side decorations,** drawn by the theme. `flags -titlebar` gives the title strip to the client, and a `titlebar` ctl declares drag, gadget and no-drag regions. Hit-testing stays in the server. A client that draws its own title strip starts a move or a resize from its own widget with `move` or `resize EDGE`, given no coordinates: `winsrv` takes over the current press and runs the drag itself, as it does for its own decorations (F-207).
- **Synchronous geometry.** A `ctl` write returns after the change has been applied, and the resulting `seq` can be read immediately (F-206).
- **Explicit window kinds:** `toplevel`, `transient`, `popup` (anchored and constrained, like `xdg_positioner`), `tooltip`, and `layer` (panels, docks, overlays; by grant only, because a layer can cover other windows, §5.7).
- **Scale per window,** as a rational number over 120. Buffers are in device pixels. There is one DPI mode; no "unaware" mode exists (F-205).
- **Outputs have stable names,** derived from the display's EDID, so a window placed on an output returns there after a reboot or a re-plug. Adding or removing an output is an event on `/wsys/outputs/events`, and the primary output is set in `/wsys/outputs/ctl` (F-205).
- **Input:**
  - keycodes are USB HID usages, with the modifier state after the event, and the unmodified rune, a `vx_rune` (a Unicode code point, ADR-0013) (F-210);
  - the active layout is named in the window's `keymap` file, and a change of layout is a `KEYMAP` event. Dead keys and compose are resolved in the server; key repeat is generated there and flagged as repeat (F-210);
  - IME runs in the server, through the `ime` file and `PREEDIT`, `COMMIT` and `DELETE_SURROUNDING` events. `ime purpose text|password|number|url|email|terminal` tells the input method what the field holds, and a key event the IME looked at and passed on carries an `imepass` flag, so the app does not act on it twice (F-211);
  - pen input has proximity and tool identity (F-212);
  - `pointer lock|confine|warp` delivers raw deltas, with the accelerated deltas beside them. A lock is honoured only while the window has focus and is dropped during a server-run drag; each grant and release is a `POINTER` event, and motion caused by a warp carries a `warped` flag, so a camera does not jump (F-213);
  - high-rate devices, such as an 8 kHz mouse, deliver every event with its device timestamp, converted to the system's one clock (01 §4.4) so it compares directly with frame times. Events are batched per wake-up but never merged, so a game sees the full history, as `getCoalescedEvents` gives on the web.
- **Capability queries:** `/wsys/info` lists protocol version and feature bits.

### 5.2 Hybrid WIMP and tiling

Every workspace has a **layout policy**. A window can be *tiled* (placed by the layout) or *floating* (placed by the user), and can switch between the two at any time.

| Layout | Behaviour |
|---|---|
| `float` | Classic WIMP: overlapping windows, title bars, drag to move, snap to edges and quarters |
| `tile master-stack` | dwm or xmonad style |
| `tile bsp` | Binary space partition, as in bspwm or yabai |
| `tile columns` | Scrolling columns, as in PaperWM or niri: an infinite strip of columns, and the view scrolls |
| `mono` | One window at a time, with tabs |

**Mouse users are first-class in tiled layouts.** Dragging a title bar in a tiled workspace shows the drop targets (split left, right, top, bottom, or tab), and dropping re-tiles. Dragging a divider resizes the split. Holding Super while dragging makes the window float.

### 5.3 Key bindings

Key bindings and window rules are data: ndb records (D14) in `/wsys/keys` and `/wsys/rules`. Each binding's action is an ordinary `ctl` verb. Lua is for policy that needs logic, such as a custom layout, not for lists of settings.

```
# ~/lib/wm/keys.ndb   (written to /wsys/keys at login; writing records directly works too)
bind key=super+enter        do="spawn term"
bind key=super+h            do="focus left"
bind key=super+shift+h      do="move left"
bind key=super+1            do="workspace 1"
bind key=super+t            do="layout cycle tile-bsp,tile-columns,float"
bind key=super+space        do="palette open"          # command palette (§8.4)
bind key=super+r            do="mode resize"           # modal key maps, as in i3; not modal UI
bind mode=resize key=h      do="resize -40 0"
bind mode=resize key=escape do="mode default"

# ~/lib/wm/rules.ndb
rule app=org.vx.calc float size=400x600 center
```

`wm` compiles bindings into a table that `winsrv` matches *in the input path*, without a round trip to `wm`. Shortcuts therefore still work while `wm` is busy.

### 5.4 Reactive theming

A theme is a set of **design tokens** served as files:

```
/wsys/theme/
    active          "vx-dusk"
    tokens          color.bg=#1b1d23 color.accent=#7aa2f7 radius.window=10 font.ui="Inter 10.5"
                        motion.fast=120ms border.width=1 shadow.window="0 8 24 #0008"
    ctl             set color.accent #e0af68 · load ~/lib/themes/paper · mode dark|light|auto
    events          token change notifications
```

- The theme owns styling, as the convergent shape in the case study's Q2 report recommends. `vxui` widgets and server-side decorations read tokens and never hard-code them.
- Changes arrive as events, and the next frame repaints only what changed.
- Tokens can be *derived*: an accent colour computed from the wallpaper, light or dark mode following the time of day or ambient light (`/dev/sensors/light0`), and high contrast from accessibility settings.
- Per-app overrides use the same rule syntax as `wm`.

### 5.5 Everything through the same verbs

```sh
echo 'tile left' > /wsys/windows/7/ctl           # script
wsys focus 'app=org.vx.hx'                       # CLI helper; same verb
# key:   super+shift+h                           # binding → same verb
# mouse: drag title to left drop target          # winsrv → same verb
# agent: tool call wsys.ctl(window=7, "tile left") → auditfs → same verb
```

### 5.6 Accessibility tree as files

`vxui`, and any toolkit that implements the adapter, publishes each window's semantic tree. `vxui` builds it from each frame's node list, and its stable widget IDs become the node IDs. A verb written to `ctl`, such as `press 42`, arrives as input to that widget on the next frame.

```
/wsys/windows/7/a11y/
    tree        one ndb record per node; parents by id:
                  node=1  role=window name="main.c — hx"
                  node=17 parent=1 role=textarea name=editor focused
                  node=30 parent=1 role=toolbar
                  node=42 parent=30 role=button name=Run actions=press
    nodes/42/{role,name,value,state,bounds,actions}
    ctl         press 42 · set-value 17 "hello" · focus 42 · scroll 17 0 -200
    events      node changes
```

This one interface serves screen readers **and** agents. An agent that "clicks Run" writes `press 42`. It does not synthesise pointer events or read pixels. Agents can therefore use only apps that are accessible, which gives developers a reason to support accessibility. A text field marked secret, such as a password field, publishes its role and state but never its `value`.

### 5.7 Who can see what

A global `/wsys` tree in every app's namespace would repeat X11's security model. Any client could read every window's key events (a keylogger), read every window's text through `a11y`, type into a terminal with `press`, or draw a fake approval prompt on a `layer` surface. So the tree is not in an app's namespace:

- **Apps get `/wsys/self`:** their own windows, plus a `new` verb that creates one. Nothing about other windows is visible.
- **The whole tree is a grant,** held by `wm`, the shell, the command palette, and assistive technology the user installs as such. `svcd` gives it through their namespace templates, and `/proc/N/status` shows it.
- **Approval prompts use a trusted path.** `winsrv` draws them in a layer no client can create or cover, with a mark only it can draw, and only physical input answers them. A `press` through `a11y`, a `pointer warp`, or any other synthetic input is ignored there, so an agent cannot approve its own request.

## 6. Application developer framework: hide complexity until it is needed

The case study's lesson is that platforms fail developers in two ways: they bury simple tasks under several mechanisms, and they block the escape hatch when an app needs more. VectraOS offers **three tiers over one substrate**, and a program can move down a tier for one subsystem without rewriting the rest.

| Tier | Who | Surface |
|---|---|---|
| **Script** | Automation, tools, small UIs | Lua (or any language) against files: `/wsys`, `/ai`, `/dev`. `vxui-lua` for declarative UIs |
| **App** | Most applications | `vxui`: a C23 API, `vxui.h`, which is also the stable ABI. Odin and other languages bind to it directly |
| **Engine** | Games, editors, emulators, browsers, DAWs | Raw `/wsys` rings, a CPU pixel buffer or Vulkan, `audiod` stream rings, `/dev/input` |

**`vxui` principles** (carried over from the case study's charter work; [study/shapes.md](study/shapes.md) §5 says which recommendations were adopted, changed or dropped):

1. **One loop, one wait, owned by the app.** `vx_wait(app, &ev, deadline)` blocks in one `port_wait` covering window events, frame events, timers, audio contract changes, file notifications, ring completions and user wake-ups. The toolkit never calls back into the app, except for the real-time audio callback (5). An engine calls the same function with a zero deadline inside its own loop.
2. **Immediate-mode UI with a retained cache inside the library,** as in Ryan Fleury's UI series. The app describes its UI on each frame it draws and holds no widget objects:
   ```c
   vx_ui *ui = vx_ui_begin(win, &ev.frame);
   vx_label(ui, "Name");
   vx_text_field(ui, "name", &name);        // name is an app-owned vx_textbuf
   if (vx_button(ui, "Run")) start_run();
   vx_ui_end(ui);
   ```
   - **Stable IDs:** each widget's ID is a hash of its key string, seeded with its parent's ID, as in Fleury's UI series. The key defaults to the label; `"Delete##row17"` or `vx_push_id(ui, i)` gives widgets with the same label, such as rows built in a loop, distinct IDs. Position in the tree is never part of the ID, so inserting a widget does not reset its neighbours. The library keys its cache on these IDs: scroll offsets, focus, animations and text layout. An entry is dropped when its widget is missing from a frame.
   - **Idle is still idle:** a frame is built only when there is an event or an animation. Damage comes from comparing this frame's node list with the last one.
   - **Layout is a pass of its own, inside the frame.** The app's calls build the node tree; layout passes then size and place it (content sizes, fixed and relative sizes, then resolving overflow); then the frame is drawn. Nothing on screen lags a frame behind the app's state. Only input uses the previous frame's rectangles: `vx_button` reports what the user did to the button where it was when they clicked, which is what they saw.
   - A per-frame arena, and no allocations per frame in layout or paint.
   - Text from v1 (S7 finding 6): shaping with **kb_text_shape** and rasterisation with **stb_truetype**, both single-header C, vendored. Rasterised glyphs go into a GPU glyph atlas keyed by (font, glyph, size, subpixel offset), as in refterm: each glyph is rasterised once, and after that every draw is a textured quad. The terminal uses the same cache, which is how it meets its budget (00 §8). stb_truetype does not defend against hostile font files, so it is fuzzed with the other parsers and `vxui` loads fonts only from `/lib/font` and `$home/lib/font`. stb_truetype does no hinting, so small text on a 1x display is the risk; M7 checks it there, at terminal sizes, beside a reference rendering, before the choice is final (04 §6).
   - There are no widget lifetimes, no callbacks for UI events, and no gap between the state the app holds and what the UI shows.
3. **Asynchronous everything the user can take time over:** dialogs, file pickers and permission requests return immediately, and their results arrive later as events on the same wait. None of them spin a nested loop.
4. **Frame events carry the truth:** `ev.frame` has `target`, `prev_presented` and `dt`, so game-loop interpolation needs no clock arithmetic.
5. **Real-time audio discipline:** the audio callback is a plain C function that runs on a thread `audiod` admitted as `realtime`, and fills the stream's sample ring (§7). It must not allocate or lock, and a debug build traps if it does (S7 finding 4). Voices (§7) give sound with no callback at all.
6. **Known budgets:** `vx_gpu_budget(app)` and `vx_memory_pressure(app)` are exact numbers from the kernel, not heuristics.

**Minimal program:** window, frame, input and sound in 10 calls, against the heritage bar of 12 or fewer.

```c
#include <vxui.h>

const char *vx_main(void) {
    vx_app    *app  = vx_app_open("org.example.beep");                  // 1
    vx_window *win  = vx_window_open(app, "Beep", 640, 360);            // 2
    vx_voice  *beep = vx_voice_open(app, VX_TONE(440.0f, 120));         // 3
    float x = 320.0f;
    vx_event ev;
    while (vx_wait(app, &ev, VX_INFINITE)) {                            // 4
        switch (ev.kind) {
        case VX_FRAME: {
            vx_canvas *c = vx_canvas_begin(win, &ev.frame);             // 5
            vx_clear(c, VX_THEME_BG);                                   // 6
            vx_circle(c, x, 180.0f, 20.0f, VX_THEME_ACCENT);            // 7
            vx_canvas_present(c);                                       // 8
        } break;
        case VX_KEY:     if (ev.key.down && ev.key.usage == VX_KEY_SPACE) vx_voice_play(beep); break; // 9
        case VX_POINTER: x = ev.pointer.x; vx_window_redraw(win); break; // 10
        case VX_CLOSE:   return nullptr;
        default:         break;
        }
    }
    return nullptr;
}
```

Errors are sticky: a failed open makes the next `vx_wait` return `false`, and `vx_app_error(app)` gives the reason. The minimal program therefore needs no error checks.

**Continuous frames:** the minimal program draws only when asked (`vx_window_redraw`), so an idle window costs nothing. A game calls `vx_window_animate(win, true)` once, and from then on gets a frame event for every frame the output shows, until it turns animation off. While a window is occluded or hidden, `vxui` sets the intent of the thread that draws it to `background`, and back to `interactive-frame` when the window is shown again; an engine with its own render thread reads the visibility state from the configure record and does the same (F-204).

**Pixels, with no GPU API:** the engine tier does not require Vulkan. A program can draw into memory itself, as a software renderer or an emulator does:

```c
vx_pixels px = vx_pixels_begin(win, &ev.frame);   // a mapped BGRA8 vx_buffer: px.data, px.w, px.h, px.stride, px.age
draw_my_frame(px.data, px.w, px.h, px.stride);
vx_pixels_present(win, &px);                      // with damage rects, if it has them
```

The buffer is a CPU surface (§4): it gets exact frame feedback, and `winsrv` puts it on a scan-out plane when it can. `px.age` says how many frames ago this buffer's contents were last presented (0 for a new buffer), so a program that redraws only damage repaints what changed since then, with no copy of the whole frame. A second exit criterion stands beside the minimal program: a window drawn by the CPU from this buffer, sound the program writes itself into a stream ring (§7), and a gamepad, in 12 calls or fewer, with no Vulkan, no callback and no widget.

**Distribution and ABI:**
- Apps are packages with a manifest that declares `requires="vx-abi >= 1"` and the namespace template the app needs, such as `needs=/wsys,/dev/audio,net:client`. Installing the app shows that manifest to the user (F-219).
- The ABI version table generates availability annotations, so there is no `dlopen` probing.

### 6.1 Hot reload and looped playback

Handmade Hero's live code editing is a convention of `vxui`, not a new mechanism:

- **The split:** during development an app builds as a small host plus a code image, `app.so`, which exports one function: `void vx_app_update(vx_app_memory *mem, vx_event *ev)`. All of the app's state lives in `mem`, one block that the host reserves with `as_reserve(AS_FIXED)` at the same address every run (01 §5), so pointers inside it stay valid across reloads and across runs. The host is app code too: a short template the app owns and may change. So the app still owns its loop (principle 1); the host's loop is the app's loop.
- **Reload:** `./build` writes a new image to a temporary name and renames it over `app.so`, so the host never sees a half-written file. The host watches for the rename with `notify` (02 §3.3), finishes the current frame, maps the new image at a new address and carries on.
- **Old images stay mapped** until the session ends. A string literal, function pointer or constant table that `mem` still points to keeps pointing at valid bytes after a reload, which removes Handmade Hero's classic reload crash. Address space is cheap; a long session costs a few megabytes. `dbg` sees each image as its own map event and keeps breakpoints by source line across them (05 §2).
- **Looped playback:** `vx_replay_start` snapshots `mem` and starts recording every event `vx_wait` returns, and `vx_replay_play` restores the snapshot and replays the events in a loop while you edit the code. Replay is exact only if everything the app depends on comes through `vx_wait`, so while replaying:
  - time comes from `ev.frame` (`target`, `dt`), never from `rdtsc`, `clock_read` or `/sys/clock/now`;
  - file contents and ring completions count only if they arrived as events; a direct `read()` is not recorded and is not replayed.
- **The snapshot is `mem` and nothing else.** GPU memory, windows, voices and open files are not restored; an app that keeps state in them redraws or reloads it from `mem`.
- **Release builds** link the code image into the host, and do not reload. `AS_FIXED` is open to any program (01 §5); what release builds lose is the reload, not the fixed address.

## 7. Audio

- **`audiod`** runs a mixer with a fixed period, `realtime(period=2.67 ms @ 128 frames/48 kHz)`, and schedules streams by deadline.
- **A stream is a sample ring.** Each stream is a ring of samples in a VMO shared with `audiod`, with two positions in its header: the *play position*, which `audiod` advances as the mixer consumes samples, and the *write position*, which the app advances. The app writes ahead of the play position by as much latency as it chooses, from any thread, usually once per frame from its game loop, as Handmade Hero does. Reading the play position costs no syscall. If the app falls behind, the ring underruns, `audiod` plays silence, and the underrun is counted in the stream's `status` and reported as an event.
- **Each stream publishes one contract record:** period, sample rate, ring size, total latency, device-clock to monotonic-clock mapping, and device identity. A change to any of them arrives as an event (F-216).
- **Default device:** a stream on `default` follows the default device on the server side.
- **Two conveniences sit on the ring,** and neither is a second mechanism:
  - the **real-time callback** (§6, principle 5): `vxui` runs it on a thread `audiod` admitted as `realtime`, and it fills the ring one period at a time;
  - **voices over the mixer** (`vx_voice_open`, `vx_voice_play`) give games and UIs sound with no callback and no ring at all.
- **Real-time admission** for app callback threads is requested by `audiod` on the app's behalf, so the app never uses magic numbers (F-215).
- **Helper threads join the stream's deadline.** A synthesiser that spreads its voices over several threads brings them into the callback's admitted budget (`vx_realtime_join`, 09 §5.7), so they are scheduled against the same period. The admitted parameters and every deadline miss are readable as text in `/proc/N/threads/T/sched` (F-215).

## 8. Local-first AI in the desktop

### 8.1 `aid`: the AI runtime service

`aid` serves `/ai` (02 §5.6). It is an optional install, and nothing else in the system depends on it. Without it there is no `/ai`: the palette takes fuzzy `ctl` commands only, search returns exact results only, and the other surfaces in §8.4 are absent. With it, the integration is as deep as described here. It owns four things:

- **The model registry.** Weights are files on `fsd`, mapped with `Tmap` rather than read, so several sessions share one copy in RAM (01 §5). Metadata comes from GGUF, ONNX or TensorFlow Lite headers. These files come from the internet, so their parsers are fuzzed with the others (04 §7); llama.cpp's GGUF parser has had memory-safety bugs.
- **Runtimes:**
  - llama.cpp/ggml (vendored C/C++) with its Vulkan backend on any profile GPU, and CPU fallback;
  - whisper.cpp for speech;
  - an ONNX-class runtime for vision and embeddings;
  - NPU back ends on `/dev/accel/npu*` where an open stack exists: Rockchip's, through Mesa's Teflon delegate and Rocket driver over `accel` (ADR-0023), on no tiered board since the RK3588 left T1 (00 §5). Intel NPU, AMD XDNA, Qualcomm Hexagon and Apple ANE wait for open user-space stacks (02 §5.3).

  Each runtime runs in its **own sandboxed process** with only its model files and accelerator context in its namespace. A crashing kernel inside a runtime takes down only that session.
- **Sessions:** the `clone` → `N/` files, streaming output, and the tool-call loop.
- **Placement:** for each request, choose local NPU, local GPU, CPU, a swarm node, or a frontier provider (§8.6).

### 8.2 Heterogeneous placement

| Workload | Preferred | Why |
|---|---|---|
| Embeddings, OCR, speech recognition, image classification: sustained and small | **NPU** | Performance per watt; leaves the GPU free for frames |
| LLM decode for interactive chat or completion | **GPU** (UMA: all of the weights resident) | Memory bandwidth dominates, and UMA GPUs see all system RAM |
| LLM prefill of long contexts | GPU, or a swarm GPU node when prefill is over 30k tokens and the round trip is small | Compute dominates; worth shipping |
| Background indexing | NPU, else CPU with `background` intent | Must never be noticed |
| Tasks beyond the local models | Swarm node, then a frontier provider, subject to policy | Local first |

### 8.3 Sharing the GPU with the compositor

The frame deadline always wins.
- GPU drivers expose **priority queues**, and `winsrv` holds the only `realtime` one. Inference submits on `interactive` or `background` queues.
- Where the GPU can preempt at compute-dispatch or instruction level (modern AMD, Intel and Apple parts), the driver preempts inference work for composition.
- Where it cannot, `aid` runtimes split work into dispatches that each take under 2 ms. `aid` reads the GPU driver's per-queue latency statistics and adapts the chunk size.
- **Memory:** UMA memory pressure (01 §5) makes `aid` unload the least recently used model or step down to a smaller quantisation *before* the desktop is affected.
- **Idle and battery:** a laptop on battery prefers the NPU and caps GPU inference according to `/sys/power` policy.

### 8.4 User-facing surfaces

- **Command palette** (`super+space`). Natural language or fuzzy commands produce a **plan of `ctl` verbs, previewed** in the palette ("tile editor left, open terminal in ~/src/vectra, run `./build qemu`"). The user confirms before anything runs. Plans that contain only read-only or reversible verbs can be set to run without confirmation, unless the session would send data off the machine: reading a file and then prompting a provider is exfiltration, however read-only each step is (§8.6).
- **Inline assist in text fields.** A `vxui` text field offers completion, rewriting and translation through the same IME-adjacent path, so it works in any `vxui` app and in any app with a text-input adapter.
- **System search.** Exact results (file names, `ctl` verbs, windows) are merged with semantic results from `/ai/ctx/*/query`. The results are files, so they can be opened, dragged or piped.
- **"Explain this window."** The assistant reads the window's `a11y` tree (text, not pixels) and answers in a side panel.
- **Shell integration.** In `rc`, a line starting with `?` asks for a command. The command is suggested and inserted into the line, never run automatically.
- **Live captions and dictation** use whisper on the NPU, taking audio from an `audiod` tap that the user has explicitly enabled.

### 8.5 Agents: permission, audit and undo

- An agent is a process started with a namespace template (02 §7). It can only name what the template gives it. It sees its own session in `/ai/self`, never another session or a context pool the user has not granted.
- **Permission prompts** appear when an agent writes a `request bind …` or invokes a `ctl` verb whose `.schema` class is `destructive`. The desktop shows who is asking, what for, and the exact verb. The choices are *allow once*, *allow for this session*, *always for this project*, or *deny*. Approvals become attenuated tokens with an expiry. The prompt uses the trusted path (§5.7). Effect classes come from `.schema` only for servers on the trusted list; any other server's verbs count as `destructive`. Standing approvals ("always for this project") are kept by `svcd` with the other grants, listed in the grant settings, and revocable there.
- **Broad grants are not prompts.** The whole home, another app's data, the dump, other windows and mixed context pools are broad grants (02 §7, ADR-0029). An agent never holds one, and no `request` can raise the prompt for one. A user who wants an agent to see more makes it a narrower view.
- **Agents the system did not start** (a coding agent's command-line client, installed as a package) are programs like any other. Their namespace is all that confines them: `/lib/ns/posix` with their own data tree and `needs=cwd`, not the user's home. `aid`'s labels, audit and undo do not reach them.
- **Audit:** every mutating operation passes through `auditfs` and is visible live at `/ai/sessions/N/actions` and in an activity panel.
- **Undo** covers files under `auditfs`. It snapshots them before an agent session starts, and one click rolls the session back. The filesystem must be copy-on-write for this, which ADR-0025 gives it in M5 (11 §5). Undo cannot reach anything that has left the file tree: `ctl` verbs already applied, network traffic, or prompts sent to a provider. The activity panel says so.
- **Screen contents are not available by default.** Pixels of other windows are never in an agent's namespace. It sees only what the user grants: a window's a11y tree, or a one-off screenshot the user approves.

### 8.6 Frontier fallback and the routing policy

Frontier providers, such as the Anthropic API with current Claude models, are mounted under `/ai/providers/NAME` with the same session files as local models. API keys live in `keyd`. The adapter's HTTPS goes through `tlsd` (00 D16), which asks `keyd` to attach the key inside the TLS session, so neither an app nor the adapter ever holds a key.

```
# /ai/policy — an ndb file (02 §4.1); first match wins
classify  path=/home/*/finance/**        sensitivity=secret
classify  source=mail                    sensitivity=private
route     sensitivity=secret             only=local
route     task=completion                prefer=local:qwen3-coder-7b  max-latency=150ms
route     task=chat                      prefer=local:qwen3-8b  then=swarm  then=provider:anthropic  max-sensitivity=internal
route     task=code-agent                prefer=provider:anthropic  max-sensitivity=internal  budget=5USD/day
default   prefer=local  then=swarm  deny=provider
```

- Every item in a context pool carries a sensitivity label. `aid` enforces the policy when it *assembles the context*, not after, so a secret document never enters a prompt bound for a provider.
- **Labels follow the data.** A tool result carries the label of what the tool read, and a session's egress limit is the highest label it has seen. A session that has read a `secret` file through a tool can no longer reach a provider, even though nothing came from a context pool.
- `usage` reports where each request ran, and the status bar shows when anything left the machine.

## 9. The desktop shell

_Storyboarded 2026-10-03. Like everything after M3, this is provisional and is rewritten against the code at M7._

### 9.1 The look

- **Lit chrome, not flat.** The desktop takes its look from Amiga MUI, NeXTSTEP and SGI's Indigo Magic: bevelled chrome, sunken wells, MUI's titled group frames, and NeXT's ring around the default button. With a GPU these cost nothing: `winsrv` shades every bevel from one light source, so they stay sharp at any scale.
- **Two themes ship,** both plain token sets (§5.4): `vx-magic`, warm grey after Indigo Magic, and `vx-next`, NeXT's charcoal with a black title bar on the key window. Proposed token families: `light.*` (angle, softness), `chrome.*` (face, light, shade, edge), `title.*` (active, inactive), `well.*` (light, dark), `lamp.*` and `lcd.*`. Switching theme is one `load`; the next frame repaints only what changed.
- **Status is a lamp.** Green means local or running, amber means an agent is live or data has left the machine, and blue means a swarm node is in use. The clock is an LCD strip. Lamps glow but never pulse: idle is idle (§1).
- **A black title strip is reserved for system panels,** such as the greeter and the palette.
- **Icons follow BeOS.** Each object is seen from above at three-quarters, with a heavy dark outline, flat-shaded faces lit from the same `light.angle` as the chrome, one highlight edge, and a shadow cast down and to the right. Devices are drawn as boxes and documents as tilted sheets. Icons are vectors, one file each in `/lib/icon`, drawn at any size; one drawing serves both themes.
- **No text-mode UIs.** Every first-party tool with an interface (palette, Activity, Settings, Disks) is a `vxui` app. The terminal is for the shell. Plan 9 never had curses, and the system does not add it.

### 9.2 The bar

The bar runs along the top of the screen, as Amiga's screen title strip did. It holds:

- a desk pager, as in IRIX, showing each workspace;
- the workspace's layout policy;
- the focused window's title;
- the lamps: egress (§8.6's "the status bar shows when anything left the machine"), a live agent session (§8.5), the swarm resources the foreground app uses (02 §6), and the holder of a broad grant while it runs (ADR-0029);
- the clock.

**Notifications drop from the bar as slips,** drawn by the shell from the adapters' `events` files (07 §6.3), with a lamp marking where each came from. A slip also reports what the user just did, such as an undo restoring files (§8.5).

### 9.3 The dock

- **A NeXT dock on the right edge.** The workspace tile is at the top and the recycler at the bottom. A small green lamp on a tile marks an app that is running.
- **The dock owns its strip.** It is a `layer` surface the shell holds, with an exclusive zone. `wm` lays tiles out in the work area outside it, so a tiled window never reaches under the dock. A floating window can be dragged there; it passes under the dock, which always stays on top.
- **Pinning.** Drag an app from Applications onto the dock, where a lit bar shows the slot, or write the record `pin app=org.vx.mail after=org.vx.activity`. Both become the same verb on `/wsys/dock`. Dragging a tile off the dock unpins it.
- **A full dock scales,** as Aqua's does. The tiles shrink together so the dock fits the screen's height, the strip narrows, and `wm`'s work area widens to match. The smallest tile is a legibility limit, measured at M7 across screen sizes and scales.
- **Magnification under the pointer** is a dock preference, off by default. It animates only while the pointer is on the dock.

### 9.4 The bench

Storage lives on the desktop surface, as on Amiga's Workbench.

- **One icon per volume,** with the volume's name and a `type · location` subtitle (`vx-fs · nvme0`, `dosfs · usb1p1`, `isofs · ro`). Swarm volumes appear too, as their node.
- **What the system cannot read is badged `?`.** This covers a partition whose filesystem no server reads (`Linux fs · mmc0p2`) and a device with no partition table (`no table · usb2`). Both get one menu: *Manage in Disks…*, *Ignore until unplugged*, *Always ignore this device*, *Eject*. Nothing is formatted or mounted until the user chooses.
- **"Always ignore" is an ndb record keyed by the device's serial number,** kept in the bench's own data tree (`#appdata/$user/PKG`, ADR-0029 decision 6), not in `$home`.
- **A pulled device leaves no ghost.** Its icon goes when the removal event arrives, and a slip says what happened. If writes were waiting, the slip's lamp is amber and it names the files that were lost.
- **Home is not on the bench.** It is `home` inside System. Each session binds only `#home/$user` at `/home/$user` (02 §2), so `/home` holds the user's own folder and no one else's.

### 9.5 The trusted path

Prompts on the trusted path (§5.7) are drawn in a material no client theme can use: a gunmetal frame, a gold rim and an embossed seal, under the title *SYSTEM · TRUSTED PATH*. The rest of the screen dims and the bar goes dark. An image the user picks at sign-in may replace or join the seal later.

## 10. Open questions

1. **Remote windows.** Is a compressed surface stream enough, or should a remote `vxui` app send its *node tree* for local rendering, which would be sharper and use less bandwidth?
2. **The login shell and `/wsys`.** §5.5 shows a script focusing another app's window, but §5.7 gives the whole `/wsys` tree only to `wm`, the shell and the palette. Does the user's interactive shell hold that grant, or does a script reach only `/wsys/self`?
3. **`super+shift+h`.** §5.3 binds it to `move left`, while §5.5 uses it for `tile left`. Which is it?
4. **"Explain this window" and ADR-0029.** Another window's `a11y` is a broad grant, and agents never hold one. Does the shell read the tree and hand the text to the session, so the agent never holds the grant?
5. **Dock pins.** Do they live in `~/lib/wm/dock.ndb`, beside the key bindings, which the user writes, or in the dock's `#appdata`, as state the shell writes?
6. **Undoing "always ignore".** Where does the user see and remove these records? Most likely the Bench section of Settings.
7. **Verb echo.** Should the shell offer a slip that names the verb each key or drag produced, to teach the key paths? Off by default?
