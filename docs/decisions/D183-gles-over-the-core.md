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
  As built (2026-11-27): a budget line's limit is a ceiling, so each rate
  is printed as the time of one of its frames, as `remote.copy` prints a
  rate as a copy's time: a scene's frame time against a frame at 98% of
  the reference's rate, and the score as one second over it. glmark2
  prints them itself (ports/glmark2's patch 0002), as every program that
  measures prints its own, and exits with 1 when one is missed; the
  check is the board's run of `esp-board-glmark2`, judged by its last
  line (glmark2(8), gl.md's "The budgets").

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

## The Mali backend for GL, as built (2026-11-26)

What a GL frame costs on the Orange Pi 6 Plus, loinnir-test's frame budgets
(CoreFrames.swift: the median of 41 round trips at 800x600, from `submit`
to the waiting thread running again), before and after:

| budget | before | after |
|---|---|---|
| `gpu.mali.frame_empty_us` | 9 | 9 |
| `gpu.mali.frame_clear_draw_us` (clear, one draw over the target) | 295 | 158 |
| `gpu.mali.frame_100_draws_us` | refused (16 a pass) | 559 |
| `gpu.mali.frame_two_passes_us` | 579 | 277 |
| `gpu.mali.frame_small_pass_us` (64x64) | - | 102 |

- **One submit a list, the steps chained on the GPU.** A list's passes,
  dispatches, transfers and timestamps are streams on three queues of one
  group (tiler, fragment, compute), each step waiting (SYNC_WAIT64) for a
  sync object of the device's that every step adds one to; a stream on the
  queue the last step ended on doesn't wait. The group's queues are started
  together (slot state and resources) before any stream waits: a queue that
  asked for its resources while another waited on the chain hung the group
  (vulkan-test, whose first pass follows a transfer; loinnir-test probes it).
- **No buffers a frame.** What a submission lays out comes from 4 MiB
  chunks bound once and reused by timeline value; one thread storage and one
  workgroup memory for every step; the heap copied again only after a
  write. Before, each pass made and bound a buffer (73 us of layout of 108).
- **Passes of any number of draws**; `depth24stencil8` (D24X8 and S8) and
  `depth32fstencil8` attachments; vertex shaders sample (glmark2's terrain).
- **Where the 158 us of a frame go:** the CPU's submit 47 us (planning 3,
  layout 17, the driver's submit 23, of which the service's part is 9 us at
  the median); the GPU starts 16 us after the submit returns and takes 121
  us (64 us of it a 64x64 pass's fixed cost: two waits between queues, the
  tiler's and the fragment's, the jobs' cache maintenance); the waiting
  thread runs 25 us after the GPU's end. Two timestamps on one queue with
  nothing between them take the GPU 16 us.
- **The GPU's clock:** SCMI performance domain 0 reads level 1000 (its top,
  1000 MHz) with nothing asking for another; the agent refuses its limits.
- **Open:** a draw costs the CPU about 4 us (0.9 in the plan, the rest the
  pass recipe), so 100 draws take 440 us of a 559 us frame; windowed
  presentation is FIFO (Radharc takes the oldest present a vblank and a
  window waits for its credit), so swap interval 0 has no path yet;
  `gl_PointSize` is accepted and not stored; 16-bit colour targets
  (rgb565, rgba4, rgb5a1) are not core formats.
