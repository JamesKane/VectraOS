# Compatibility layers (Q5), and why VectraOS takes almost none of them

_From the study's Q5 report, 2026-09-27._

**Question:** which compatibility layers (SDL3, Vulkan, WebGPU, a CUDA-like compute surface and others) remove the most porting cost per unit of platform effort?

The study answered for NeoDarwin, which planned to host Linux and macOS software through compatibility layers. VectraOS keeps the measurements and rejects most of the recommendations: rule 13 forbids the OS from shipping or offering any compatibility or portability layer, with POSIX as the sole exception. What users port into their own user land is their business. This file records both, so the rejection is an informed one.

## Short answer, as the study gave it

- **Vulkan through Mesa is the foundation.** 25 of the 37 applicable Tier A+B projects already render or compute through Vulkan, directly or through wgpu/Dawn. Vulkan also makes three cheaper layers almost free: WebGPU (wgpu/Dawn), GL through Zink, and DXVK/VKD3D-Proton.
- **Wayland "core+" is the second foundation:** 23 of 37 projects have a Wayland client path. The corpus uses 16 extension protocols in 6–12 projects each, including `linux-dmabuf`, which every Vulkan and EGL client needs.
- **Metal adds no unique graphics reach.** Every one of the 11 projects with a Metal backend also has Vulkan or GL.
- **Darwin-likeness buys little source compatibility.** Only 1.4% of macOS-path API usage is libSystem-level; 96% is AppKit, Core Animation, Metal and other frameworks.
- **Toolkit GPU layer:** expose Vulkan as the interop seam (surfaces and buffer objects), and make the toolkit's own drawing API WebGPU-shaped (`webgpu.h`, backed by Dawn). Not SDL_gpu-shaped.
- **First release:** POSIX plus Linux shims, Wayland core+, Mesa Vulkan with the profile, Zink GL/EGL, a PulseAudio-protocol audio door, SDL3, and wgpu and Dawn packages. With that set, 28 of 37 corpus projects run, and 32 of 37 with optional Xwayland. The remaining 5 are the Wine stack.

## Ranking by reach per unit of effort

Effort is marginal: it assumes the platform already has POSIX, its own window system and kernel GPU drivers with Mesa.

| Rank | Layer | Reach (of 37) | New platform code | Study verdict | VectraOS |
|---|---|---|---|---|---|
| 1 | WebGPU packages (wgpu, Dawn) | 8 (3 hard) | about 0.03–0.1k surface glue | highest, conditional on Vulkan | Rejected as an OS layer (rule 13); a user may port one |
| 2 | GL/GLES/EGL via Zink | 7 GL-only + 11 GL fallbacks | 0–3.3k | very high | **Rejected.** The OS ships no GL (D6; 03 §3) |
| 3 | Vulkan via Mesa: profile, WSI, CTS gating | 25 | WSI 0–4.7k, plus profile work; kernel GPU glue already planned | foundation | **Adopted.** The only GPU API (D6) |
| 4 | Wayland core+ (core + 16 extensions) | 23 | about 10–20k server side | high | **Rejected.** `/wsys` is the only window protocol (D11) |
| 5 | POSIX + Linux shims (epoll, eventfd, memfd) | 37 need it; 3 run on it alone | a few k | prerequisite | **POSIX adopted** as the one exception to rule 13 (01 §9); Linux shims rejected |
| 6 | SDL3: audio and HID now, native video later | 11 with SDL code; 3 depend on it | 1–13k | medium in the corpus, high outside | **Rejected** as an OS backend (D11) |
| 7 | Wine + DXVK/VKD3D-Proton | 5 (large outside the corpus) | a Wine port plus the F-218 VM API | low now, high later | Not offered; the F-218 VM API exists anyway (01 §5) |
| 8 | Compute: Vulkan compute, then OpenCL, then CUDA-shaped | 1 / +1 / potentially 4 | about 0 / moderate / very high | Vulkan compute high; CUDA-shaped lowest | Vulkan compute adopted; CUDA-shaped host API later (D7) |
| 9 | Metal | 0 unique graphics, ≤ 2 compute | very high | none | Not offered |

## Why the measurements still matter here

- **Vulkan reach is the reason D6 costs so little.** An engine with a Vulkan backend ports to VectraOS without writing a new backend. That is 25 of the 37 projects.
- **The Wayland extension list is a checklist for `/wsys`.** The 16 extensions the corpus actually uses name the features a native protocol must cover to be enough: fractional scale, viewporter, decorations, activation, cursor shape, relative pointer, pointer constraints, text input, primary selection, output geometry, idle inhibit, toplevel icon, dmabuf, presentation time, fifo and commit timing. `/wsys` covers each one natively (03 §4, §5), which is what makes refusing the Wayland bridge reasonable.
- **SDL's corpus value was audio and HID, not video or SDL_gpu.** VectraOS answers both in the system instead: `audiod` (F-215, F-216) and gamepad class drivers (F-214). A user-land SDL port would then be a thin file rather than 50 kLOC of HID drivers.
- **VectraOS does not adopt the WebGPU-shaped toolkit API.** S7 found that reaching the first GPU frame through `webgpu.h` took 26 calls, more than the whole SDL program, and a WebGPU implementation would be a second API over Vulkan. VectraOS's toolkit draws with its own small Vulkan 2D renderer and gives engines `vx_gpu_surface(win)` for raw Vulkan (03 §3; [prototypes.md](prototypes.md) §3).

## The study's layering, for reference

```
Applications:  toolkit apps | SDL3 games | Qt/GTK/winit apps | Windows games | ML/science
Compat:        webgpu.h     | SDL3       | libwayland, Zink  | Wine, DXVK    | Vulkan compute
Native:        Vulkan (one GPU API) | window protocol + Wayland door | audio service + Pulse door
               POSIX + Linux shims; one versioned platform ABI
Kernel:        GPU drivers; one GPU buffer object (memory + modifier + fence); VM views
```

VectraOS keeps the bottom two rows and the Vulkan column, and deletes the doors and the compatibility row from the base system.

## Data problems the study recorded

- Reach counts are corpus counts. The SDL and Wine catalogues outside the corpus are much larger than their corpus share.
- Effort figures for Wayland and the Linux shims are estimates, not measurements.
- Chromium and Firefox have window and GPU paths in the study's first-release set, but need OS-level ports (sandbox, IPC) that no compatibility layer provides.
