# Friction register

_From the study's `friction/` register (30 admitted entries, 2026-09-27). [README](README.md) has the method and the commit pins._

A friction entry is a place where applications fight the platform to get performance or correctness. Each one was admitted only with evidence from at least three independent projects. F-1xx entries cover graphics and compute, and F-2xx entries cover the system and the desktop.

Each entry below gives:
- the problem;
- the strongest evidence, as `project@commit path:line`, with the study's signal counts;
- how the five reference platforms handle it today;
- the VectraOS answer and where it lives. Where the study's own proposal for NeoDarwin differs, the difference is noted.

## Summary

| ID | Friction | VectraOS answer | Where |
|---|---|---|---|
| F-101 | Present timing is unknowable or approximate | Every frame event carries the actual presentation time of the previous frame | Rule 8; 03 §4 |
| F-102 | Frame pacing and queue depth differ on every platform | One frame clock per output; `ctl latency n`; `present` fails fast | 03 §4 |
| F-103 | Pipeline compilation at first use; caches don't survive drivers | GPL or shader objects guaranteed by the profile; a system pipeline cache | 03 §3 |
| F-104 | Engines keep three to five graphics backends in step | Vulkan is the only GPU API, with a published profile | D6; 03 §3 |
| F-105 | One compute backend per vendor stack | Vulkan compute baseline; a CUDA-shaped host API later | D7 |
| F-106 | Every engine rebuilds barrier and layout tracking | Unified image layouts in the profile | 03 §3 |
| F-107 | Sharing a GPU buffer across APIs and processes | One buffer currency: memory object + format + timeline fence | Rule 7; 01 §6.1 |
| F-108 | Process memory as GPU memory without a copy | Host-pointer import at page alignment; UMA is the design case | 01 §6.3, §6.4 |
| F-109 | GPU memory budget and residency are guessed | GPU buffers charged to the task group's memory budget, with a pressure port | 01 §5; 03 §6 |
| F-110 | Per-vendor driver quirk tables in every codebase | Drivers ship with the OS against one profile; no quirk database yet | 03 §3 (partly open) |
| F-111 | Shader IR and binding models translated per backend | SPIR-V only, compiled at build time | D6; 03 §3 |
| F-201 | The platform owns the UI thread and its wait | No main thread; one `port_wait` for everything | Rules 4, 9; 01 §4.4; 03 §5.1, §6 |
| F-202 | System modal loops freeze the app | No modal loops in any protocol or toolkit call | Rule 9; 03 §5.1, §6 |
| F-203 | No precise deadline sleep, so apps raise timer resolution and spin | Absolute deadline plus leeway; no resolution knob | Rule 5; 01 §4.4, §12 |
| F-204 | Threads cannot state intent; apps probe cores | Five intents, core reservations, topology as data | Rule 6; 01 §8; 02 §5.1 |
| F-205 | Per-output scale and display topology | Scale per window as n/120; one DPI mode | 03 §5.1 |
| F-206 | Negotiated geometry, state and popup placement | Synchronous geometry; explicit window kinds; anchored popups | 03 §5.1 |
| F-207 | Custom title bars and decoration ownership | Server-side decorations; `titlebar` regions, hit-tested by the server | 03 §5.1 |
| F-208 | Content out of step with the window during live resize | Every present carries its `config_seq` | 03 §4 |
| F-209 | Visibility is implicit, so hidden windows stall | Frame events throttled to 1 Hz, never withheld | 03 §4 |
| F-210 | Key events without a trustworthy layout or modifier model | HID keycodes, modifiers after the event, unmodified rune | 03 §5.1 |
| F-211 | IME needs a synchronous text model and a caret rectangle | IME runs in the server; asynchronous `ime` file and events | 03 §5.1 |
| F-212 | Pen input has no self-describing stream | Proximity and tool identity from HID usages | 03 §5.1 |
| F-213 | Relative motion and pointer lock emulated by warping | `pointer lock\|confine\|warp` with raw deltas | 03 §5.1 |
| F-214 | Apps ship per-vendor gamepad HID drivers | Gamepad class drivers in the system; one normalised device | 02 §5.2 |
| F-215 | Real-time audio needs three unrelated mechanisms | `realtime(period, budget)` with an admission test, unprivileged within a budget | 01 §8; 03 §7 |
| F-216 | Audio period, latency, clock and device have no single contract | One contract record per stream; server-side default-device following | 03 §7 |
| F-217 | Async, unbuffered asset reads exist on one platform per project | Rings are the batched I/O queue | Rule 11; 01 §4.3 |
| F-218 | Reservations, views and JIT need a recipe per OS | `as_reserve`, `as_map` views, W^X dual mapping | 01 §5 |
| F-219 | Every project writes a loader for optional platform libraries | One versioned ABI declared in the package manifest | 03 §6 |

---

## Graphics and compute

### F-101: Present timing is unknowable or approximate

**Problem.** Video players, browsers, editors and translation layers need to know when a frame reached the glass, so they can schedule the next one, count dropped frames and keep audio and video in sync. Every platform gives a different partial answer: DXGI frame statistics that must be correlated by guesswork, `MTLDrawable.presentedTime`, Wayland's `wp_presentation`, and three driver-gated generations of Vulkan extensions. Applications write per-platform estimators, sanity-check the values, and fall back to nominal refresh rates. Godot, Bevy and SDL's GPU API don't use present feedback at all.

**Evidence.**
- mpv@e470f8986e `video/out/d3d11/context.c:302-375`: correlates `GetLastPresentCount` with `GetFrameStatistics`; `S_OK` can come with all-zero statistics.
- zed@1a28cff4b4 `crates/gpui_windows/src/vsync.rs:44-78`: `DwmGetCompositionTimingInfo` can return an impossible 29 µs refresh period.
- chromium@7d084775ca `components/viz/service/display/display.cc:150-172`: feedback timestamps "may have a different source", can be in the future, and are sanitised on every platform except macOS.
- MoltenVK@50b3cbf373 `MoltenVK/GPUObjects/MVKImage.mm:1659-1734`: where `presentedTime` is missing, pretends the present happened when requested.
- Signals: `PRS.timing.feedback` used in 10 projects (136 files); 434 vsync and pacing workaround comments in 27 projects (shared with F-102).

**Platforms today.** Windows: frame statistics and DWM timing, correlated by counters. macOS: `presentedTime`, `addPresentedHandler:`. Linux: `wp_presentation` and driver-gated Vulkan `present_wait`/`present_timing`. Haiku: `WaitForRetrace` only. Plan 9: none.

**VectraOS answer.** `winsrv` owns scan-out, so it can promise exact feedback. Every frame event carries `prev_presented`, the actual presentation time of the previous frame, plus `refresh`, `zero_copy` and `dropped` (rule 8; 03 §4). The profile guarantees present id, present wait and present timing (03 §3). CPU surfaces get exact feedback too (S7 finding 5).

### F-102: Frame pacing source and queue depth differ on every platform

**Problem.** An interactive application wants a signal for when to start the next frame, and a bound on how many frames are queued ahead of the display. Windows uses a latency-waitable swap chain or `DwmFlush`. macOS uses display links. Wayland uses `wl_surface.frame` callbacks, which Mesa's EGL and Vulkan FIFO block on and which compositors may withhold indefinitely for hidden windows. Several projects found the same bug independently (the app freezes inside the swap call on Wayland), and each wrote its own pacing thread or busy-wait.

**Evidence.**
- SDL@1ce4c5bc29 `src/video/wayland/SDL_waylandopengles.c:67-99`: forces `eglSwapInterval(0)` and paces by frame callback itself, because a minimised window may never get one.
- blender@6580c5fc43 `intern/ghost/intern/GHOST_WindowWayland.cc:2137-2145`: the same swap-interval-0 workaround, citing SDL's report.
- zed@1a28cff4b4 commit 980a294: prefers Mailbox on Wayland because FIFO stalls the event loop "for tens of seconds".
- chromium@7d084775ca `components/viz/service/frame_sinks/external_begin_frame_source_{win,mac,android}.cc`: one frame-clock source per platform.
- wgpu@babefc0d26 commits b8f27c7, e7cdfc4: the portable API had to grow a D3D12-specific latency knob.
- Signals: `PRS.timing.pacing` in 20 projects (414 hits); 60 Tier A present/pacing commits touching GPU backends in 10 projects.

**Platforms today.** Windows: waitable swap chain, `SetMaximumFrameLatency`, `DwmFlush`. macOS: `CVDisplayLink`/`CADisplayLink`. Linux: `wl_surface.frame`, `wp_fifo_v1`, `drmWaitVBlank`. Haiku: `WaitForRetrace`. Plan 9: none.

**VectraOS answer.** One frame clock per output, owned by `winsrv`, delivered as an event into the client's one wait, never as a blocking call inside a GPU driver. `ctl latency 1|2|3` bounds queued presents, and `present` fails fast at the bound (03 §4). Hidden windows get a throttled clock, not a withheld one (F-209).

### F-103: Pipeline compilation at first use, and caches that don't survive drivers

**Problem.** Explicit APIs compile a full pipeline, ISA included, when the app asks for it. Apps often learn which state combination they need only at draw time, so the compile lands on the frame: shader stutter. Every engine builds the same machinery: background compilation with a slow "ubershader" meanwhile, and a disk cache keyed by the exact driver, because cache blobs are rejected after a driver update or on another GPU. Split compilation (`VK_EXT_graphics_pipeline_library`) helps where it exists, with its own vendor bugs.

**Evidence.**
- dolphin@bb3558a70e `Source/Core/VideoCommon/VideoConfig.h:43-49`: four user-visible compilation modes; `Source/Core/VideoBackends/Vulkan/ObjectCache.cpp:524-645` parses the pipeline-cache header itself and discards it on mismatch.
- godot@b13043816a `servers/rendering/renderer_rd/pipeline_hash_map_rd.h:109-205`: background compilation; `get_pipeline` returns empty until ready.
- blender@6580c5fc43 `source/blender/gpu/vulkan/vk_backend.cc:586-594`: adopted GPL in 2025, then disabled it on official AMD drivers because it crashed.
- qtbase@580c68c21e `src/gui/rhi/qrhimetal.mm:50-56`: Metal binary archives disabled entirely after two bug reports.
- Signals: `GPU.pipeline.cache` in 19 projects; stutter and ubershader comments in 16 projects.

**Platforms today.** Windows: `ID3D12PipelineLibrary` (may return `E_NOTIMPL`). macOS: `MTLBinaryArchive`. Linux: `VkPipelineCache`, `VK_KHR_pipeline_binary`, GPL, shader objects. Haiku and Plan 9: no pipeline objects.

**VectraOS answer.** The profile guarantees shader objects or graphics pipeline libraries, plus dynamic state. A system pipeline-cache service is keyed by (app, shader hash, driver build), is invalidated centrally when the driver changes, and is warmed at install time (03 §3). The study also proposed a compile-status query on pipelines; that is not yet in the blueprint.

### F-104: Engines keep three to five graphics backends in step

**Problem.** No single graphics API runs everywhere, so every portable engine carries one backend per API: 12 corpus projects have three or more. Each backend is a full correctness and performance surface, and features are implemented several times or cut back to the intersection of all backends. GPU backends churn 1.3 to 3 times as often per line as the rest of the project, and 17–31% of backend commits in the four Tier A graphics projects touch two or more backends at once.

**Evidence.**
- SDL@1ce4c5bc29: 5 GPU backends, 63,581 lines; 27% of 673 backend commits in 3 years touch 2+ backends. Commit ea77472 documents features that don't work on every backend, so the portable API is cut to the intersection.
- wgpu@babefc0d26: 4 HAL backends plus 4 shader backends, 93,229 lines; HAL backends 26.6–33.7 commits/kLOC against 13.4 for core; 31% of 783 backend commits touch 2+ backends. Portable limits are bounded by D3D12's 64-entry root signature (`wgpu-hal/src/dx12/mod.rs:406`).
- godot@b13043816a: 4 backends, 75,155 lines; 19% of 848 backend commits touch 2+ backends.
- blender@6580c5fc43: the Vulkan backend alone had 980 commits in 3 years, 0.80 times the whole of core.

**Platforms today.** Windows: D3D12 native, Vulkan and GL through vendor drivers. macOS: Metal only; GL deprecated; Vulkan only through translation. Linux: Vulkan and GL. Haiku: Mesa ports only. Plan 9: no GPU API.

**VectraOS answer.** No new API. Vulkan through Mesa is the only GPU API, with a published *VectraOS Vulkan Profile* (`vx-vk-2026`) that guarantees what engines probe for today (D6; 03 §3). An engine with a Vulkan backend ports without writing a new one. The study ranked WebGPU second and SDL3 GPU third as portability layers; VectraOS rejects both under rule 13 ([compat.md](compat.md)).

### F-105: Compute frameworks carry one backend per vendor compute stack

**Problem.** GPU compute has no portable native API with competitive performance: CUDA, HIP, SYCL, Metal, OpenCL and Vulkan compute each cover part of the hardware. ML and science codes keep one backend per stack and write each kernel several times. Unlike graphics backends, compute backends drift apart: in llama.cpp only 4% of backend commits touch more than one backend, and operator coverage depends on the vendor.

**Evidence.**
- llama.cpp@a97cce86a8: 8 compute backends, 354,373 lines (1.01 times core); the same operators written in five kernel languages (CUDA 46k lines, Vulkan GLSL 25k, OpenCL 45k, MSL 13k, WGSL 7k); HIP and MUSA reuse the CUDA backend through 126 and 113 macro aliases.
- blender@6580c5fc43 `intern/cycles/device/{cuda,hip,metal,oneapi}/device_impl.*`: four implementations of one device contract.
- openmm@ccc08b118e `platforms/common`: kernels written once in a macro dialect that expands to CUDA, HIP or OpenCL.
- pytorch@4b0647edac `aten/src/ATen/hip/impl/*MasqueradingAsCUDA.*`: HIP presented to the framework as CUDA; missing MPS operators fall back to the CPU.

**Platforms today.** Windows: CUDA, HIP, oneAPI, DirectML, D3D12 compute, OpenCL. macOS: Metal, MPS, Core ML. Linux: CUDA, ROCm, oneAPI, OpenCL, Vulkan compute. Haiku and Plan 9: none.

**VectraOS answer.** Vulkan compute is the baseline on every GPU, with vendor NPU drivers behind a uniform `/dev/accel` tree, and a CUDA-shaped host API later (D7). The HIP experience suggests that host API should be close to CUDA's rather than new.

### F-106: Every engine rebuilds hazard, barrier and image-layout tracking

**Problem.** Vulkan and D3D12 hand hazard tracking to the app: barriers, access masks, image layouts, queue ownership, and on tilers whether a barrier splits a render pass. Mistakes are silent on one vendor and corrupt the frame on another. Every portable engine contains a resource-state tracker or render graph whose main job is generating barriers. Shipped D3D12 games omit barriers, and vkd3d-proton keeps per-game quirk tables to force them.

**Evidence.**
- wgpu@babefc0d26 `wgpu-core/src/track/mod.rs:1-30` (3,681 lines): "some of the hottest code in the entire codebase".
- blender@6580c5fc43 `source/blender/gpu/vulkan/render_graph/` (4,265 lines, 149 commits in 3 years).
- godot@b13043816a `servers/rendering/rendering_device_graph.h` (3,853 lines).
- vkd3d-proton@472989aabd `libs/vkd3d/device_workarounds.c`: per-game quirks forcing barriers the game omitted.
- Signals: `GPU.sync.barrier` in 22 projects (1,828 hits).

**Platforms today.** Windows: D3D11 implicit, D3D12 explicit. macOS: Metal tracks hazards by default. Linux: Vulkan explicit, GL implicit. Haiku: GL through Mesa. Plan 9: none.

**VectraOS answer.** The profile requires unified image layouts, so `GENERAL` is always optimal and most engines drop layout tracking (03 §3). `vxui` draws with its own 2D renderer, so toolkit clients never see barriers. The study also proposed a system render-graph library and validation-layer sync checks on by default; neither is in the blueprint.

### F-107: Sharing a GPU buffer across APIs, processes and the compositor

**Problem.** Video decoders, compute kernels, renderers and the compositor often need the same pixels. Keeping them on the GPU means exporting a buffer from one API, importing it into another, and carrying a fence with it. Every OS has a different handle type, every API pair a different import call, ownership rules differ per handle type, and both sides must first prove they are on the same GPU. Browsers and players build large abstraction layers; compute tools fall back to copies.

**Evidence.**
- chromium@7d084775ca `gpu/command_buffer/service/shared_image/`: 20 backing implementations, about 42k lines.
- mpv@e470f8986e `video/out/hwdec/`: 18 files of per-API interop; "CUDA takes ownership of an imported FD *but not* an imported Handle".
- blender@6580c5fc43 `intern/cycles/device/cuda/graphics_interop.cpp:49-110`: the same ownership rule, documented separately.
- dawn@6c1e27710c `src/dawn/native/*/SharedTextureMemory*`: a separate import path per handle type.
- Signals: `GPU.interop.external` in 23 projects (1,712 hits).

**Platforms today.** Windows: NT handles, keyed mutexes. macOS: IOSurface. Linux: dma-buf with modifiers, sync_file. Haiku: no GPU sharing. Plan 9: named images inside the draw server only.

**VectraOS answer.** One currency: a buffer is a memory object plus a format descriptor plus a timeline fence, and CPU, GPU, NPU, display, video, network and disk all exchange it (rule 7; 01 §6.1). The `/wsys` present path takes that buffer for zero-copy presentation (03 §4).

### F-108: Turning ordinary process memory into GPU memory without a copy

**Problem.** Model loaders, emulators and compute frameworks already hold their data in process memory, often in a mapped file, and want the GPU to read it in place. Every stack has a different entry point with different alignment and coherence rules, and some silently copy. On unified-memory machines the copy is pure waste, yet apps must detect UMA themselves from heap sizes and vendor IDs.

**Evidence.**
- llama.cpp@a97cce86a8: wraps mapped weights with `newBufferWithBytesNoCopy` on Metal, `cudaHostRegister` on CUDA, `VK_EXT_external_memory_host` on Vulkan (disabled on MoltenVK); on Adreno `CL_MEM_USE_HOST_PTR` "is NOT zero-copy" (`ggml/src/ggml-opencl/ggml-opencl.cpp:9795-9808`).
- dawn@6c1e27710c `src/dawn/native/vulkan/UtilsVulkan.h:214-217`: alignment hard-coded to 4096 with a TODO, because the real limit is not surfaced.
- godot@b13043816a `drivers/vulkan/rendering_device_driver_vulkan.cpp:1597-1605`: infers UMA from a heap larger than 256 MiB.
- Signals: host-import and pinned-host symbols in 11 projects.

**Platforms today.** Windows: `OpenExistingHeapFromAddress`, `CacheCoherentUMA`. macOS: `newBufferWithBytesNoCopy:`. Linux: `VK_EXT_external_memory_host` with per-driver alignment, `udmabuf`. Haiku and Plan 9: CPU sharing only.

**VectraOS answer.** The unified-memory SoC is the design case: a buffer is mapped by CPU and GPU with no copy (01 §6.3). On a discrete GPU the GPU reads host-visible buffers through the IOMMU, with `minImportedHostPointerAlignment` equal to the page size (01 §6.4).

### F-109: GPU memory budget and residency are guessed, not negotiated

**Problem.** Apps need to know how much GPU memory they may use before performance falls off a cliff, and to say which allocations matter. Platforms give partial answers, and none is tied to the OS memory-pressure signal. Engines and ML frameworks write residency managers, keep safety margins, invent watermark ratios and read `/proc/meminfo` on UMA systems.

**Evidence.**
- dxvk@52fe923ca1 `src/dxvk/dxvk_memory.cpp`: its own eviction, keeping part of the budget unused because drivers misbehave near the limit.
- llama.cpp@a97cce86a8 `ggml/src/ggml-cuda/ggml-cuda.cu:5062-5085`: on UMA systems, replaces CUDA's free-memory figure by parsing `/proc/meminfo`.
- pytorch@4b0647edac `aten/src/ATen/mps/MPSAllocator.h:398-405`: watermark ratios of 1.7 and 1.4 times a heuristic working-set size.
- Signals: `GPU.mem.residency` in 14 projects. None of the 12 `MEM.pressure` sites subscribes to an OS pressure notification.

**Platforms today.** Windows: `QueryVideoMemoryInfo`, `MakeResident`. macOS: `recommendedMaxWorkingSetSize`, residency sets. Linux: `VK_EXT_memory_budget`; PSI for RAM, not linked. Haiku and Plan 9: none.

**VectraOS answer.** GPU and NPU buffers are charged to the task group's memory budget, because on unified memory they *are* system memory. A budget has a limit and a pressure level, and pressure changes can be bound to a port (01 §5). `vx_gpu_budget(app)` and `vx_memory_pressure(app)` are exact numbers from the kernel (03 §6, principle 6).

### F-110: Per-vendor, per-version driver quirk tables in every GPU codebase

**Problem.** The same call behaves differently by vendor, device, driver version and OS: advertised features crash, limits are wrong, correct programs draw wrong pixels. Every project that ships GPU code keeps a quirk table keyed by vendor ID, device ID or driver version, and the tables are not shared.

**Evidence.**
- chromium@7d084775ca `gpu/config/gpu_driver_bug_list.json`: 265 entries.
- dawn@6c1e27710c `src/dawn/native/Toggles.cpp`: 183 toggles; dynamic rendering force-disabled on Intel Gen9 and older, Mali-G68 and all PowerVR.
- wgpu@babefc0d26 commit 94d9f24: moves the Y-flip into the vertex shader because Arm drivers ignore negative viewport heights.
- dolphin@bb3558a70e `Source/Core/VideoCommon/DriverDetails.h`: 29 bug entries with driver-version ranges.
- Signals: 271 commits in the driver-vendor cluster in 10 Tier A projects, the largest named cluster in the graphics area.

**VectraOS answer (partly open).** Drivers ship and update with the OS against one profile, so apps can key on one OS version instead of vendor × driver × device (03 §3). The study also proposed gating every driver on the Vulkan CTS for the profile plus a conformance suite built from these quirks, and publishing a machine-readable known-issues database. Neither is in the blueprint yet; they belong with the per-vendor GPU driver ADRs before M8.

### F-111: Shader IR and resource-binding models must be translated per backend

**Problem.** Each GPU API takes a different shader representation (SPIR-V, DXIL, MSL, GLSL, WGSL) and a different binding model. A portable engine ships a translator in its runtime or build, or asks the app for every format, and the translator becomes a large component of its own.

**Evidence.**
- wgpu@babefc0d26: shader writers for four languages total 46,293 lines, about the same as its four HAL backends.
- dawn@6c1e27710c `src/tint/`: about 137k lines of compiler.
- SDL@1ce4c5bc29 `include/SDL3/SDL_gpu.h:119-133`: the app must supply SPIR-V, DXIL or MSL.
- godot@b13043816a `drivers/d3d12/rendering_shader_container_d3d12.cpp`: SPIR-V → NIR → DXIL through Mesa, with DXIL signed in-tree.

**VectraOS answer.** SPIR-V is the only shader IR. GLSL and HLSL compile to SPIR-V at build time; there is no shader compiler on the device (D6; 03 §3). The profile's binding model (descriptor buffers or descriptor indexing) gives engines one layout.

---

## System and desktop

### F-201: The platform owns the UI thread and its wait

**Problem.** Engines want to own their loop: render on threads they choose, and wait on one primitive for window events, their own descriptors, a cross-thread wake and a deadline. AppKit requires the first thread to run `NSApp`. Win32 binds each window to the thread that created it. Wayland and Xlib connections are single-queue sockets. Waking a loop from another thread works differently everywhere, and on X11 and Wayland it costs a round trip through the server. macOS cannot wait for window events and descriptors in one call. Cross-platform layers then impose macOS's rule on every platform so code ports.

**Evidence.**
- wine@4e819f054d `dlls/ntdll/unix/loader.c:1901-1935`: parks the original thread in `CFRunLoopRun()` and moves all of Windows to another thread.
- winit@8b5f46d4be `winit/src/event_loop.rs:59-70`: the event loop "must be created on the main thread" on all platforms, "imposed to eliminate any nasty surprises when porting".
- gtk@91ecb49fb9 `gdk/macos/gdkmacoseventsource.c:36-82`: "the macOS API's don't allow us to wait simultaneously for file descriptors and events".
- SDL@1ce4c5bc29: four wake mechanisms for one concept (`src/video/{x11,wayland,cocoa,windows}/*events*`); 273 API docs say "should only be called on the main thread".
- Signals: 315 comments in OS backends about the main thread or run loop, in 23 projects. The friction is structural, paid once in each backend's design.

**Platforms today.** Windows: windows bound to their creating thread, but one wait covers messages plus up to 63 handles; apart from modal loops, the most flexible model. macOS: the first thread must run `NSApp`, and fds and window events can't be waited on together. Wayland and X11: wakes go through the server unless the app adds its own eventfd. Haiku: a thread per window and no main thread, but no wait API an engine can own. Plan 9: every source is a file; libthread gives each device a helper proc feeding a channel, and `alt` waits on any set of channels; no thread affinity at all.

**VectraOS answer.** No main thread in any protocol (rule 9). Every event source delivers into a port, and one call waits on all of them: ring completions, timers, window and frame events, audio, file changes and user wake-ups (rule 4; 01 §4.4). `/wsys` files carry no thread affinity, and one thread may multiplex many windows (03 §5.1). `vx_wait` is one `port_wait` owned by the app (03 §6, principle 1). The study needed kqueue readiness on 9P fids for this; VectraOS gets it from the kernel `Port` directly.

### F-202: System modal loops freeze the application during move, resize and menus

**Problem.** When the user drags a title bar or border, opens the window menu or starts a drag, Windows and macOS run a nested loop inside the platform. The app's loop stops until the gesture ends: games stop, video stops, content is stretched, key-ups are lost. Every engine adds the same Windows workaround, a `WM_TIMER` at `USER_TIMER_MINIMUM` that re-enters the frame function from inside the system loop, and a matching hack on macOS. Wine has to *fake* the modal loop on X11 and Wayland because Win32 apps depend on it.

**Evidence.**
- The identical timer in SDL@1ce4c5bc29 `src/video/windows/SDL_windowsevents.c:1897-1930`, godot@b13043816a `platform/windows/display_server_windows.cpp:6853-6870`, zed@1a28cff4b4 `crates/gpui_windows/src/events.rs:295-330` and sokol@2e75443dbd `sokol_app.h:10112-10119`.
- winit@8b5f46d4be `winit-win32/src/event_loop.rs:1302-1326`: a caption click "causes a pause for about 500ms".
- wine@4e819f054d `dlls/winex11.drv/mouse.c:1496-1564`: emulates the modal loop by polling `XQueryPointer` every 100 ms.
- Signals: modal-loop markers used in 17 projects (57 sites); 9 of 13 cross-platform layers reference them.

**VectraOS answer.** No modal loops in any protocol (rule 9). Move and resize run in the server and are asynchronous (03 §5.1). Dialogs, file pickers and permission requests return at once and deliver results as events (03 §6, principle 3). The study also proposed an "interactive gesture" state bit so engines can pick a cheap resize path.

### F-203: No precise deadline sleep, so frame limiters raise global timer resolution and spin

**Problem.** Frame limiters, emulators and frame clocks need to sleep until a deadline with sub-millisecond accuracy without burning a core. Windows' default sleep granularity is the ~15.6 ms tick, so apps raise a process- or system-wide timer resolution and then still busy-wait the last millisecond or two. The same "sleep most of the way, spin the rest" code is compiled for Linux and macOS with a guessed granularity. Nobody in the corpus uses `clock_nanosleep(TIMER_ABSTIME)` or `mach_wait_until` for frame pacing.

**Evidence.**
- dxvk@52fe923ca1 `src/util/util_sleep.cpp:37-106`: sets the maximum timer resolution through ntdll, then busy-waits "for the last couple" of milliseconds.
- godot@b13043816a `platform/windows/os_windows.cpp:296-308`: `timeBeginPeriod` at startup, "otherwise Sleep(n) may wait at least as long as the windows scheduler resolution (~16-30ms)".
- raylib@2fbb15f49a `src/rcore.c:1649-1690`: sleeps for 95% of the interval, then spins.
- rpcs3@3fa07db78b `rpcs3/rpcs3.cpp:1062-1064`: `NtSetTimerResolution` on Windows, `PR_SET_TIMERSLACK` on Linux.
- Signals: timer-resolution calls in 13 projects, all on Windows except one; 59 comments about resolution, busy-waits or sleep precision in 19 projects.

**VectraOS answer.** Time is an absolute deadline with a leeway, and there is no timer-resolution setting (rule 5). `port_wait` takes the deadline and leeway, so a frame limiter is "wait for events or the deadline" in one call (01 §4.4). Accuracy target: p99 under 100 µs for an interactive thread on an idle core (01 §12).

### F-204: Threads cannot state their intent, so apps probe cores and fight throttling

**Problem.** An engine has a render thread with a per-frame deadline, workers that must finish together, background streaming, and a UI that should idle when occluded. On hybrid CPUs the scheduler places work by heuristics. Apps can't describe the work portably, so on Windows they switch throttling off, on Linux they pin a thread to each CPU in turn and execute `cpuid` to find efficiency cores, and on macOS they map priorities onto QoS classes by hand. "Real-time" is three unrelated mechanisms.

**Evidence.**
- llama.cpp@a97cce86a8 `common/common.cpp:160-212`: pins the calling thread to each CPU and reads `cpuid(0x1a)` to count performance cores; `ggml/src/ggml-cpu/ggml-cpu.c:2567-2583` disables power throttling because Windows 11 parks cores.
- wine@4e819f054d `dlls/ntdll/unix/system.c:1113-1147`: reads an Intel-only sysfs path to answer `EfficiencyClass`.
- ghostty@b40acce58d `src/renderer/Thread.zig:259-285`: renderer QoS follows window state by hand (occluded, unfocused, focused).
- zed@1a28cff4b4 `crates/gpui_{windows,linux,macos}/src/dispatcher.rs`: one `spawn_realtime` intent, three mechanisms.
- Signals: priority calls in 14 projects, affinity in 7, heterogeneous-core probing in 4.

**VectraOS answer.** Threads declare intent, or reserve whole cores, never priorities or affinity masks: `interactive-frame`, `interactive`, `throughput` (co-scheduled on one core type, the llama.cpp case), `background` and `realtime(period, budget)` (rule 6; 01 §8). The kernel places threads using HFI and Thread Director data. Topology is data under `/sys/cpu`, so nobody probes with `cpuid` (02 §5.1).

### F-205: Per-output scale and display topology

**Problem.** Apps want to render at the right density on every output, re-render when a window moves to an output with another scale, and know which outputs exist and which is primary. Windows has four DPI-awareness modes, X11 has one global factor read from folklore, Wayland has three generations of scale protocols, and macOS display IDs change when the GPU switches. Engines that can't rescale live force the largest scale everywhere.

**Evidence.**
- SDL@1ce4c5bc29 `src/video/windows/SDL_windowsvideo.c:538`: Explorer's compatibility setting silently pins the process to an older DPI mode.
- glfw@92dcf4ce74 `src/x11_init.c:991`: "Retrieve system content scale via folklore heuristics".
- godot@b13043816a `platform/linuxbsd/wayland/wayland_thread.cpp:3986`: "All platforms have resorted to forcing the highest scale possible".
- wine@4e819f054d `dlls/winewayland.drv/wayland_pointer.c:842`: three coordinate spaces in flight at once.
- Signals: 26 Tier A commits about DPI, scale or monitors on OS backends in 8 projects.

**VectraOS answer.** Scale is a property of the window, chosen by the server and delivered as a rational over 120. Buffers are in device pixels, and there is one DPI mode with no "unaware" mode (03 §5.1).

### F-206: Negotiated window geometry, state and popup placement

**Problem.** Apps want to place windows where they ask, know when a size, position or fullscreen change has actually happened, and place popups relative to a parent so they stay on screen and move with it. Win32 is synchronous but owned windows don't follow their owner. X11 is asynchronous and window-manager-mediated, with requests ignored or answered late. macOS runs fullscreen as a one-second animation during which requests fail. Wayland removes global coordinates from toplevels. Every portable layer builds a pending/current state machine with timeouts.

**Evidence.**
- SDL@1ce4c5bc29 `include/SDL3/SDL_video.h:2473`: `SDL_SyncWindow` exists only because window state is asynchronous; `src/video/cocoa/SDL_cocoawindow.m:3311` busy-waits on the fullscreen transition.
- godot@b13043816a `platform/linuxbsd/wayland/display_server_wayland.cpp:1160`: `window_set_position` is empty on Wayland.
- wine@4e819f054d `dlls/winex11.drv/x11drv.h:706`: pending and current state plus seven per-request serials; `dlls/winex11.drv/window.c:438` guesses from styles whether a window is managed.
- Signals: winewayland churns at 4.6 times Wine's core per kLOC; 35 Tier A commits on geometry and popups in 7 projects.

**VectraOS answer.** Synchronous geometry: a `ctl` write returns after the change is applied, and the resulting `seq` is readable at once. Window kinds are explicit (`toplevel`, `transient`, `popup` anchored and constrained like `xdg_positioner`, `tooltip`, `layer`), so nothing infers them from styles (03 §5.1).

### F-207: Custom title bars and who owns the decorations

**Problem.** Editors, terminals and browsers want their own content in the title bar while keeping the system frame's behaviour: drag, double-click to zoom, snap, resize edges, shadow and buttons. No platform offers "my content, your frame behaviour". On Windows the app removes the frame and hand-writes hit-testing, losing the shadow. On macOS it fights AppKit's title-bar layout every release. On Wayland decorations are optional and GNOME never draws them.

**Evidence.**
- winit@8b5f46d4be `winit-win32/src/event_loop.rs:1269`: shifts the non-client area by 1 px to keep the DWM shadow, leaving a 1 px border.
- zed@1a28cff4b4 `crates/gpui_macos/src/window.rs:696`: overrides a private AppKit selector to stop title-bar drags and click delays.
- godot@b13043816a `platform/linuxbsd/wayland/wayland_thread.cpp:1664`: libdecor's configure callback is "pretty much a reimplementation" of xdg-shell's.
- wine@4e819f054d `dlls/winex11.drv/window.c:486`: maps Win32 frame styles onto 1990s Motif hints.

**VectraOS answer.** Decorations are server-side, drawn by the theme. `flags -titlebar` gives the title strip to the client, and a `titlebar` ctl declares drag, gadget and no-drag regions; hit-testing stays in the server (03 §5.1).

### F-208: Keeping rendered content in step with the window during live resize

**Problem.** While the user drags an edge, each composited frame should show content rendered for that frame's size: no stretching, no stale size after a new one, no pause. Window geometry is owned by the window system and content by a render thread presenting through a separate path, and no platform ties "this buffer" to "this geometry". macOS apps discard mismatched drawables and fall back to main-thread transactions; Windows apps keep rendering from a `WM_TIMER` inside the modal loop; Wayland apps must ack configures themselves and get it wrong.

**Evidence.**
- qtbase@580c68c21e `src/gui/rhi/qrhimetal.mm:3305`: presents on the main thread with `presentsWithTransaction` and skips drawables of the wrong size.
- ghostty@b40acce58d `src/renderer/metal/IOSurfaceLayer.zig:109`: discards surfaces whose size doesn't match the layer.
- winit@8b5f46d4be `winit-win32/src/event_loop.rs:1274`: "the compositor is ahead of the window surface".
- SDL@1ce4c5bc29 `src/video/wayland/SDL_waylandwindow.c:983`: acks only the latest configure, at the next frame callback.

**VectraOS answer.** Every present carries the `config_seq` it was rendered for. A buffer of the wrong size is clipped or padded for at most one frame, never stretched, and resize is server-driven with no modal loop (03 §4). S7 measured the model: 88 configures, 88 presents at the new size, the loop never blocked ([prototypes.md](prototypes.md)).

### F-209: Window visibility is implicit, so hidden windows stall or waste frames

**Problem.** An app wants to stop rendering when nobody can see it, resume at once when visible, and never block because it is hidden. Wayland's only signal for years was the *absence* of frame callbacks, so a FIFO swap on a hidden window blocks forever. Windows reports minimise but not occlusion. macOS reports occlusion, but display links must be rebuilt on every change.

**Evidence.**
- SDL@1ce4c5bc29 `src/video/wayland/SDL_waylandopengles.c:118`: "compositors will intentionally stall us indefinitely".
- glfw@92dcf4ce74 `src/egl_context.c:293`: swapping on a hidden Wayland window makes it visible.
- firefox@cdc95c93c9 `widget/windows/WinWindowOcclusionTracker.cpp`: a 1,474-line occlusion tracker borrowed from Chromium.
- zed@1a28cff4b4 `crates/gpui_macos/src/display_link.rs:16`: display-link teardown on occlusion changes caused use-after-free crashes.

**VectraOS answer.** Occluded and hidden windows still get frame events, throttled to a documented 1 Hz. `present` never blocks and never changes visibility, and the frame clock belongs to the output, so visibility changes tear nothing down (03 §4).

### F-210: Key events arrive without a trustworthy layout, modifier and repeat model

**Problem.** A key press should give three things: the physical key (for WASD), the character under the active layout (for text), and a coherent modifier and repeat state. Windows reports AltGr as a fake Left Ctrl, macOS sends no events for modifiers and eats key-ups while Cmd is held, X11 reports modifiers from before the event, and Wayland makes repeat the client's job. Every toolkit carries a 1–6 kLOC keyboard translator per platform.

**Evidence.**
- wine@4e819f054d `dlls/winex11.drv/keyboard.c:1083`: 64 hand-written layout tables plus fuzzy layout detection, because X11 can't name the active layout.
- glfw@92dcf4ce74 `src/win32_window.c:716-747`: four scancode hacks and AltGr suppression by peeking at the next message.
- firefox@cdc95c93c9 `widget/windows/KeyboardLayout.cpp`: the Windows layout emulator alone is 5,439 lines.
- Signals: key-mapping calls in 27 projects (4,403 calls); SDL had 65 keyboard commits in 3 years.

**VectraOS answer.** Keycodes are USB HID usages, events carry the modifier state *after* the event and the unmodified rune, and repeat is generated by the server (03 §5.1).

### F-211: IME composition needs a synchronous text model and a caret rectangle the app doesn't own

**Problem.** CJK, Korean and Vietnamese users type through an input method that needs to see keys before the app's shortcuts, a caret rectangle to place its candidate window, and the surrounding text. Windows has two stacks, one asking synchronous questions the app must answer from its own text store. macOS asks synchronously on the main thread. XIM adds latency. Wayland's `text-input-v3` sends hints before the text they index. Engines that draw their own text must fake a native text view.

**Evidence.**
- firefox@cdc95c93c9 `widget/windows/TSFTextStore.cpp:2210-2225`: behaviour switches on which input method is active.
- SDL@1ce4c5bc29 `src/video/cocoa/SDL_cocoakeyboard.m:425-441`: a hidden 0×0 view is made first responder so Cocoa's IME has something to talk to.
- zed@1a28cff4b4 `crates/gpui_macos/src/window.rs:2680-2693`: a policy table decides which keys go to the IME and which to key bindings.
- Signals: SDL had 50 IME commits in 3 years, Godot 40.

**VectraOS answer.** IME runs in the server, through a per-window `ime` file and asynchronous `PREEDIT`, `COMMIT` and `DELETE_SURROUNDING` events. Keys the IME consumes never reach the window (03 §5.1). S7 measured the editor prototype's IME support at 44 lines of app code against about 365 for SDL3 or native.

### F-212: Pen input has no single, self-describing event stream

**Problem.** Drawing tools want per-sample pressure, tilt, tool identity, proximity and hover, in the same order and coordinates as the pointer. Windows has two incompatible stacks. X11 has no pen device class, so toolkits classify devices by substrings of their *names*. macOS can drop proximity events. Wayland's protocol is complete, but button mapping varies by compositor.

**Evidence.**
- godot@b13043816a `platform/windows/display_server_windows.cpp:5998-6014`: a user-selectable tablet driver; WinTab sends both packets and mouse messages.
- gtk@91ecb49fb9 `gdk/x11/gdkdevicemanager-xi2.c:487-500`, SDL@1ce4c5bc29 `src/video/x11/SDL_x11pen.c:99`, qtbase@580c68c21e `src/plugins/platforms/xcb/qxcbconnection_xi2.cpp:340-362`: the same device-name heuristic three times.
- blender@6580c5fc43 `intern/ghost/intern/GHOST_SystemWayland.cc:308`: GNOME swaps stylus buttons under Wayland but not under X11.

**VectraOS answer.** Pen events carry proximity and tool identity, with the tool type taken from HID Digitizer usages, never from device names (03 §5.1).

### F-213: Relative motion and pointer lock are emulated by warping

**Problem.** First-person cameras, viewport orbiting and value-dragging want unaccelerated deltas with the cursor hidden and held, and the cursor restored where it was. Windows gives deltas only through a separate Raw Input stream. macOS freezes input for 250–500 ms after a warp. X11 needs a grab that fails if another client holds one. Wayland forbade warping until 2025. Every toolkit ends up with warp-to-centre emulation, software cursors or both.

**Evidence.**
- wine@4e819f054d `dlls/winemac.drv/cocoa_app.m:1159-1180`: a warp "disassociates the mouse from the cursor position for 0.25 seconds… horribly laggy and jerky".
- SDL@1ce4c5bc29 `src/events/SDL_mouse.c:1339-1360`: "warp emulation" switches into relative mode after two warps within 30 ms.
- glfw@92dcf4ce74 `src/win32_window.c:559-995`: the disabled cursor must be postponed or re-enabled around caption clicks, moves and the window menu.
- Signals: pointer lock used in 21 projects; SDL had 57 commits on it in 3 years.

**VectraOS answer.** The pointer belongs to the server, so lock, confine and warp are requests: `pointer lock|confine|warp` delivers raw deltas (03 §5.1). High-rate devices deliver every event with its device timestamp, batched but never merged.

### F-214: Gamepads bypass the platform; apps ship per-vendor HID drivers

**Problem.** A game wants every controller to appear once, with stable identity, standard button names, and rumble, LEDs, gyro and touchpad. No desktop platform's gamepad API covers the controllers people own. Windows has five overlapping APIs, and the same pad can appear in several. So engines read HID reports directly, one driver per controller family, and write code to hide the duplicates the OS creates. This is the largest input backend in the corpus by an order of magnitude.

**Evidence.**
- SDL@1ce4c5bc29 `src/joystick/hidapi/`: about 30 per-vendor HID drivers, 49,920 lines, 507 commits by 67 authors in 3 years; `src/joystick/windows/SDL_rawinputjoystick.c:43-51`: "Using XInput at the same time as raw input will turn off the Xbox Series X controller".
- rpcs3@3fa07db78b `rpcs3/Input/`: its own DualShock, DualSense and PS Move drivers.
- godot@b13043816a commit 0b3496fb4: deleted its own gamepad code and vendored SDL3 (+154,930 lines) to get controller coverage.

**VectraOS answer.** Gamepad class drivers live in the system, each exposing one normalised device with optional rumble, LED and gyro, at `/dev/input/gamepads/N/{info,ctl,events}` (02 §5.2). There is one enumeration path, so nothing needs de-duplicating.

### F-215: Real-time audio threads need three unrelated mechanisms

**Problem.** An audio callback must finish its work inside every buffer period, however busy the machine is. Windows uses MMCSS, loaded at runtime. macOS uses the Mach time-constraint policy plus workgroups. Linux uses `SCHED_FIFO`, which fails without privilege, so programs ask rtkit over D-Bus, subject to polkit. Every project picks its own subset, tunes its own numbers and falls back silently.

**Evidence.**
- zed@1a28cff4b4 `crates/gpui_macos/src/dispatcher.rs:113-190`: hand-picked time-constraint constants; on Linux `SCHED_FIFO` fails and only logs a warning.
- SDL@1ce4c5bc29 `src/core/linux/SDL_threadprio.c:262-330`: an rtkit D-Bus client, with a comment listing the ways it fails.
- godot@b13043816a `drivers/wasapi/audio_driver_wasapi.cpp:602`: the mixing thread runs at normal priority.
- JUCE@72782788ce `modules/juce_audio_devices/native/juce_CoreAudio_mac.cpp:928-938`: re-exports the device's workgroup so plug-in threads can join its deadline.

**VectraOS answer.** One mechanism: `realtime(period, budget)`, scheduled by EDF with an admission test that accepts or refuses with a reason and never degrades silently, unprivileged within a per-user budget (01 §8). `audiod` requests admission for app callback threads, so apps never write magic numbers (03 §7).

### F-216: Audio period, latency, clock and device identity have no single contract

**Problem.** Anything that synchronises audio needs four facts about its stream: the real callback period, the end-to-end latency, a device-clock to system-clock mapping, and whether the stream is still on the device the user expects. CoreAudio spreads latency over four properties and every project sums a different subset. PulseAudio's latency reporting is buggy enough that mpv reimplements it. WASAPI invalidates streams when the default device changes, and every app re-opens and migrates by hand.

**Evidence.**
- mpv@e470f8986e `audio/out/ao_pulse.c:555-570`: does "what pa_stream_get_latency() _should_ do, but doesn't due to multiple known bugs".
- mpv@e470f8986e `audio/out/ao_coreaudio_utils.c:425-455`, wine@4e819f054d `dlls/winecoreaudio.drv/coreaudio.c:1379-1431` and JUCE@72782788ce `modules/juce_audio_devices/native/juce_CoreAudio_mac.cpp:2126-2144`: three different sums for the same latency.
- wine@4e819f054d `dlls/winepulse.drv/pulse.c:734-790`: opens a throw-away stream to learn the device period.
- godot@b13043816a and mpv@e470f8986e follow default-device changes with different WASAPI roles.

**VectraOS answer.** Each stream publishes one contract record: period, sample rate, ring size, total latency, device-clock to monotonic-clock mapping and device identity. A change to any of them is an event in the app's wait. A stream on `default` follows the default device on the server side (03 §7).

### F-217: Asynchronous, unbuffered asset reads exist on one platform per project

**Problem.** Engines and model loaders stream gigabytes. They want many reads in flight without a blocked thread per read, and a way to skip or steer the page cache. Linux has io_uring (through a version-dependent library) and `O_DIRECT` with alignment traps; Windows has IOCP, and IoRing on Windows 11 only; macOS has `dispatch_io`, which no project uses. Each project writes one fast path and keeps a thread pool of blocking reads for the rest.

**Evidence.**
- SDL@1ce4c5bc29 `src/io/generic/SDL_asyncio_generic.c:22-24`: "uses a threadpool to block on synchronous i/o. This is not ideal".
- o3de@1b2a6bdb79 `Code/Framework/AzCore/AzCore/IO/Streamer/StorageDrive.cpp:290-300`: every platform except Windows seeks and blocks.
- llama.cpp@a97cce86a8 `src/llama-mmap.cpp:184-205`: `O_DIRECT` loading on Linux only, falling back on EFAULT or EINVAL; `:700-725` runs into `RLIMIT_MEMLOCK`.

**VectraOS answer.** The rings are that queue: batched submission and completion in shared memory, waited on as an ordinary event source (rule 11; 01 §4.3). `fsd` offers rings for file reads and writes, beside its file interface (rule 2).

### F-218: Reserving address space, mapping aliased views into it, and JIT W^X need a different recipe on every OS

**Problem.** Translation layers and emulators need a fixed range of address space nothing else can allocate in, views of one shared memory object placed and remapped inside it ("fastmem"), and pages that are writable and then executable, repeatedly. Only Windows 10 1803+ can replace a reservation atomically; Unix programs use `MAP_FIXED` over `PROT_NONE` with per-kernel flags; macOS forbids `MAP_JIT` with `MAP_FIXED` or file-backed mappings.

**Evidence.**
- dolphin@bb3558a70e `Source/Core/Common/MemArenaWin.cpp:76-101`: without the newer calls, falls back to the legacy logic and "just hope[s]"; `MemArenaDarwin.cpp:28-35` splits large mappings into 128 MB chunks.
- rpcs3@3fa07db78b `rpcs3/util/vm_native.cpp:250-262`: "Apple explicitly fails mmap if you combine MAP_FIXED and MAP_JIT".
- wine@4e819f054d `dlls/ntdll/unix/virtual.c:593-615`: four implementations of a "try fixed" mapping.

**VectraOS answer.** `as_reserve` creates a reservation with no commit; `as_map` places a VMO view inside it atomically, and `as_unmap` returns the range to the reservation. W^X holds: a JIT maps one VMO twice, once RW and once RX, at unrelated addresses (01 §5).

### F-219: Every project builds its own loader for optional platform libraries and newer OS APIs

**Problem.** A portable binary must run where some libraries or entry points are missing, so projects write or generate `dlopen` tables, resolve newer Win32 functions one by one, guard macOS calls with `@available`, and work around version queries that lie. None of it is application logic.

**Evidence.**
- godot@b13043816a: 34 generated wrapper files, 48,110 lines, covering ALSA, Pulse, X11, Wayland, D-Bus and more.
- SDL@1ce4c5bc29 `src/video/x11/SDL_x11sym.h`, `src/video/wayland/SDL_waylandsym.h`: hand-kept symbol tables plus a loader per audio backend.
- glfw@92dcf4ce74 `src/win32_init.c:548-557`: uses `RtlVerifyVersionInfo` because `VerifyVersionInfoW` "lies".
- Counts: runtime lookups (`GetProcAddress` style) SDL 201, glfw 310, godot 46.

**VectraOS answer.** One versioned ABI. App packages declare `requires="vx-abi >= 1"` in their manifest, and the ABI version table generates availability annotations, so there is no `dlopen` probing (03 §6). Optional services are reached through the namespace, so a missing one is an ordinary `open` error.
