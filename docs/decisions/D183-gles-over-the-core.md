# D183. OpenGL ES 2.0 and EGL are a first-party library over the core, beside the Vulkan layer: a GLSL ES front end that emits the Vulkan-style SPIR-V the layer's lowering already takes, one compiler after it; glmark2 is ported as a tier 1 program to measure it against AbyssBSD's Panfrost on the same board (2026-11-26, decided by the owner)

The owner asked for glmark2 ported and running on the Orange Pi 6 Plus,
scoring at least 98% of AbyssBSD's numbers (FreeBSD with panthor and
Mesa 26.2.2's Panfrost on the same board), and preferably more. VectraOS
has Vulkan only (D174): the core, its Mali backend, our SPIR-V compiler for
Valhall, and the Vulkan layer over the core. glmark2 is a GLES 2.0 and EGL
program; nothing on the device speaks GL.

## The decision

- **GL is ours, over the core.** A library, `GLES` (`graphics/gles/`),
  implements OpenGL ES 2.0 and the EGL 1.5 calls a windowed or off-screen
  program needs, in Swift on `GPUDevice` and `GPUQueue` as the Vulkan
  layer is, with the C names (`gl*`, `egl*`) exported for tier 1 programs.
  It is not written on our Vulkan layer: a second translation between GL
  and the core pays no rent (principle 3), and at glmark2's rates (4,000
  frames a second) every layer's cost shows.
- **One shader path.** A GLSL ES front end (`graphics/glsl/`: the
  preprocessor, the parser, the type checker, and SPIR-V out) turns a
  linked program into Vulkan-style SPIR-V, the default uniform block a
  std140 uniform buffer and each sampler a combined image sampler, the
  attributes at their bound locations and the varyings matched by name.
  The layer's lowering (`vulkanlowering(2)`) puts it on the root pointer
  and the heap, vertex input included, and the device's compiler takes it
  from there. No second lowering, no second compiler.
- **Windows are Radharc's,** through the same window images and timeline
  handle the Vulkan layer's `VK_VECTRA_window_surface` uses; an EGL window
  surface is that swapchain. An off-screen surface is a pbuffer.
- **glmark2 is a port, not a vendored library.** Its source is fetched at
  a pinned release (2023.01) into `.cache/ports`, with our patches (its
  VectraOS native state and its build) kept in the tree as a series, as
  the toolchain's are (D47); it runs on the device as a test program, as
  vulkan-test does, and installs nothing others link (D4's line is drawn
  at libraries: the libpng and libjpeg-turbo glmark2 carries are compiled
  into it alone).
- **The promise is a budget.** Each scene of glmark2's default run is a
  budget, `gl.glmark2.<scene>` in frames a second, its limit 98% of
  AbyssBSD's on the board at 800x600, and the score likewise. The
  reference is measured on the same board in the same session of work
  (`docs/boards/orangepi-6-plus/gl.md`), off-screen and windowed.

## What it replaces

Nothing: there was no GL. Rejected: Mesa (third-party code on the device,
D4), and GL on our Vulkan layer, as Zink is on Vulkan (above).

## Consequences

- The core's Mali backend takes what GL's programs draw: passes of more
  than 16 draws, depth textures and renderbuffers, RGB uploads, and a frame
  loop with no CPU wait inside a submission.
- `vx` builds glmark2 for tier 1, and the board's images carry it with its
  data.
- GLES 3.x, desktop GL and GLX are not promised.
