# The platform API study: what this design takes from it

_Extracted 2026-10-01 from the NeoDarwin platform API study (phases S0–S7, finished 2026-09-28)._

The application-facing parts of this blueprint rest on a research study that read platform APIs and the source of open applications that push them hard. The study was a private working repository, written for NeoDarwin (an XNU-based design), and is not published with VectraOS. Its tools, symbol tables, database and 4 GB of cloned sources stay behind. These files keep what the blueprint depends on: the findings, the evidence behind them in citable form, and where each finding lands here.

Most findings concern the platform surface rather than the kernel, so they carry over. Where the study proposed a NeoDarwin mechanism (Mach ports, kqueue, a Swift toolkit, `wsys`, `libnd`), these files give the VectraOS answer instead and say where it differs.

| File | Study phase | What it holds | Cited in the blueprint as |
|---|---|---|---|
| [friction.md](friction.md) | S4, S5 (Q3/Q4) | The friction register: 30 places where applications fight the platform for performance, with evidence and the VectraOS answer | F-101 … F-219 |
| [heritage.md](heritage.md) | SH (Q6) | What AmigaOS, Atari TOS/GEM and open-SDK consoles did simply, what the added complexity pays for, and what not to copy | heritage §N |
| [shapes.md](shapes.md) | S5 (Q2) | The shapes that 13 cross-platform layers converge on, and what their wrappers hide | Q2 |
| [compat.md](compat.md) | S5 (Q5) | Which compatibility layers buy the most reach, and why VectraOS rejects most of them | Q5 |
| [prototypes.md](prototypes.md) | S7 | Five programs written against the candidate API, SDL3 and native macOS; measurements and the findings that changed the design | S7 §N, "S7 finding N" |

## Questions the study asked

1. **Q1:** where have the platforms converged, and where are developers productive? (A concept matrix of about 197 concepts over 14 modern platforms.)
2. **Q2:** where several projects wrap one concept, which wrapper shape recurs, and what does it hide?
3. **Q3/Q4:** where do applications fight the platform to get performance, and what should the platform provide instead?
4. **Q5:** which compatibility layers remove the most porting cost per unit of platform effort?
5. **Q6:** what simplicity did modern platforms lose, compared with the heritage systems, and was the added complexity worth it?

It read APIs and source code. It did not survey developers.

## Method, in brief

- **Corpus:** 44 application projects, pinned at fixed commits, in three tiers: **A** (deep: SDL, wgpu, godot, bevy, winit, dxvk, vkd3d-proton, MoltenVK, wine, llama.cpp, blender, zed, JUCE), **B** (wide: about 25 more, among them chromium, firefox, qtbase, gtk, glfw, sokol, raylib, imgui, egui, dawn, bgfx, o3de, dolphin, rpcs3, mpv, ghostty, alacritty, raddebugger, pytorch, openmm) and **C** (reference). Another 20 repositories supplied API specifications (Vulkan-Docs, DirectX-Headers, wayland-protocols, libdrm, 9front, haiku and others), and 25 heritage repositories (tier H) supplied the AmigaOS, Atari and console material.
- **Platform tables:** about 153,000 symbols from 14 modern platforms (Windows, macOS, Linux userland and UAPI, Wayland, X11, Haiku, Plan 9, Vulkan, OpenGL, EGL, OpenCL, CUDA/HIP, WebGPU, POSIX), plus 14 heritage platforms, each symbol mapped onto the concept taxonomy.
- **Usage:** a lexical extractor found 193,000 call sites in 5,500 files. Checked against clang on 39 files, it measured 92.6% precision and 96.0% recall. Vendored API headers and loaders were counted separately as declarations, not usage.
- **Weight and churn:** lines and three-year commit counts per backend, compared with each project's core.
- **Mining:** 9,300 tagged workaround comments and 9,100 performance commits, triaged by hand into friction candidates.
- **Admission rule for a friction entry:** evidence from at least three independent projects (a wrapper and its user count once: bevy is not counted apart from winit, nor raylib from GLFW).
- **Counts are ordinal.** Compare them with each other; do not read them as exact call counts.

## How to cite

Evidence is cited as `project@commit path:line`, relative to the project's repository at the pinned commit. The commits are short hashes of the pins in the table below, so any citation can be checked against upstream without the study.

| Project | Commit | Project | Commit | Project | Commit |
|---|---|---|---|---|---|
| SDL | 1ce4c5bc29 | godot | b13043816a | chromium | 7d084775ca |
| glfw | 92dcf4ce74 | bevy | 9d12036130 | firefox | cdc95c93c9 |
| sokol | 2e75443dbd | o3de | 1b2a6bdb79 | ghostty | b40acce58d |
| raylib | 2fbb15f49a | ogre-next | 475f783d76 | alacritty | d692748d3f |
| bgfx | 7e3060ccb9 | love | b7daef0f7c | zed | 1a28cff4b4 |
| wgpu | babefc0d26 | winit | 8b5f46d4be | JUCE | 72782788ce |
| dawn | 6c1e27710c | raddebugger | 2c226d8a4b | mpv | e470f8986e |
| imgui | aa0181478b | dxvk | 52fe923ca1 | llama.cpp | a97cce86a8 |
| egui | 6e35807686 | vkd3d-proton | 472989aabd | pytorch | 4b0647edac |
| qtbase | 580c68c21e | MoltenVK | 50b3cbf373 | blender | 6580c5fc43 |
| gtk | 91ecb49fb9 | wine | 4e819f054d | openmm | ccc08b118e |
| DOOM-3-BFG | 1caba19795 | dolphin | bb3558a70e | rpcs3 | 3fa07db78b |

## Known limits of the evidence

- **Missing API families.** Headers not in the corpus were not in the tables: WinRT/WinUI, DirectStorage, the X11 extension libraries, some Wayland protocols, JACK, D-Bus, libusb and V4L2.
- **Dynamic loading hides calls.** Functions reached through `GetProcAddress` or `dlsym` show up only as function pointers.
- **Tag counts undercount.** Many workarounds are written as prose without HACK or WORKAROUND, so several entries rest on code sites rather than on comment counts. Each entry says which.
- **S7 numbers are macOS-host baselines.** The VectraOS numbers wait for `winsrv`, and become the budgets in 00 §8.
