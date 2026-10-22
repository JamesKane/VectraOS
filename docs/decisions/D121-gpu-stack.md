# D121. The GPU stack is todhchai's M5, lifted in its order: buffer objects, Venus generated from its XML, the client driver, our Vulkan loader, the GPU class over virtio-gpu's 3D, Loinnir, then Radharc's GPU renderer and UIGPU, all tier 0 and statically linked (2026-10-22, decided; Venus through Loinnir on the device built 2026-10-22; for the owner's review; extends D55-D62, D107, D120)

V5's step 6, after D120's display class. todhchai built this whole
stack against croi and ran its exit natively under QEMU: the game-loop
reference program on Venus. Its parts are mostly generated code (from
`vk.xml` and Venus's protocol XML) and tier 0 Swift. D107 says the GPU
comes last in V5, lifted rather than written again. The owner set the
goal of finishing V5 and left the choices here to the recommendations,
so this note is for their review.

## Decided

- **Lift in todhchai's order** (its M5b to M5j), each part with its
  tests, so each runs before the next is built on it:
  1. **Buffer objects** (`graphics/buffers`): a VMO, its layout and a
     pair of timeline counters (acquire and release, as Radharc's
     images already have).
  2. **Venus, generated:**
     - `data/venus`, with its provenance;
     - `vkgen --venus`'s C header and Swift encoders, regenerated and
       committed;
     - the clean-room account of the encoding
       (`docs/research/venus-protocol.md`).
  3. **The Venus client driver** (`graphics/venus/driver`), tested
     hosted against the host's `virgl_test_server --venus`: a tool we
     test against, never shipped (D4).
  4. **Our Vulkan loader** (`graphics/vulkan/loader`): the loader-driver
     interface over the drivers a program is built with, and no layers.
  5. **The GPU class** (`drivers/gpu`, Magma-shaped): capsets, contexts,
     blobs and fences. virtio-gpu (D120's driver) gains its 3D part when
     the device offers virgl, blobs and context init. The GPU class is
     served beside `display`, at `dev/gpu<n>`.
  6. **Loinnir, native:** a window's texture, `frame`, `present` and
     `clear`, and its tests read back through the GPU.
  7. **Radharc's GPU renderer:** the scene's display list drawn by
     Loinnir, the CPU renderer's twin. The frame is copied into the
     display's image, so `pixel` and the screendump read what is
     shown. The CPU renderer stays the fallback wherever there is no
     GPU.
  8. **UIGPU** (`ui/gpu`): UICore's display list drawn by Loinnir, for
     apps.
- **QEMU's Venus:** `-device virtio-vga-gl,blob=on,venus=on,hostmem=1G
  -display egl-headless` with memfd guest memory, on amd64 under KVM.
  The dev machine has Vulkan 1.4 (RADV on the Ryzen's iGPU, NVIDIA on
  the RTX 5070 Ti).
  - arm64's Venus tests run under TCG where QEMU allows them, else
    they're skipped and say so.
- **Budgets:** `theme.compose.4k` is judged under Venus on the dev
  machine's GPU, for each shipped theme (theming.md §8). The game loop's
  budget stays V9's (D107).

## Left out

- Our own SPIR-V compiler and native GPU drivers: the board's (V6, V8).
- A dynamic linker for drivers (todhchai's M5k): the stack stays
  statically linked, as tier 0 is (D80's tier 1 has its own ld).

## Built (2026-10-22)

Parts 2 to 6, in a different order from the list above: buffer objects
(part 1) wait for direct scanout and clients' GPU buffers, which nothing
here needs yet.

- **Generated:** Vulkan and Venus from their registries (vkgen(1)).
- **Hosted:** the Venus client driver, tested against the host's
  `virgl_test_server --venus`. vtest's descriptor passing is a C file of
  its own (`graphics/venus/vtest-c`), not todhchai's whole Linux shim.
- **On the device:**
  - The GPU class (`drivers/gpu`), served by virtio-gpu beside
    `display`, at `/dev/display<n>/gpu`. The interrupt's thread
    harvests the queue under the device's lock, so fences finish
    without the dispatcher; counters are raised by adding the
    difference (D25: counters only add).
  - Our loader with Venus linked in through a static registry (no
    dlopen).
  - Loinnir. Its `present` copies the frame through the CPU into the
    window's surface: VX's loop has no window buffers yet to take
    the GPU's own memory.
- **boot-venus** runs loinnir-test on QEMU's `virtio-gpu-gl-pci` with
  Venus and egl-headless: a triangle, a texture from the heap, and the
  timeline, drawn on the host's GPU (the RTX 5070 Ti here).

Then Radharc's GPU renderer (`services/radharc/gpu`, the RadharcGPU
module):
- It draws the CPU renderer's quads with todhchai's compose shader,
  extended for the dimming, the seal and images with alpha.
- It draws into an sRGB target, so the hardware blends in linear light
  as Light does (D110).
- The frame is copied back into Radharc's shadow, which the outputs and
  `pixel` read as before. The CPU composes any frame the GPU fails.
- `vx shaders` (vx-shaders(1)) compiles the shaders with the host's
  glslangValidator into committed SPIR-V and Swift arrays.
- boot-venus's compose-test checks that Radharc drew frames on the GPU
  and that its pixels are right. It composes a 4K scene of twelve
  windows in each shipped theme, and reports `theme.compose.4k.<theme>`.
- The reported time is about 6.3 ms on amd64 and 7 ms on arm64. That's
  submit to done, including the frame's copy into host-visible memory,
  not GPU time alone, against a 1.5 ms target. The bench judges it; it
  isn't green.

A bug was found and fixed on the way: an upload freed before its frame
was submitted lost the device.

Earlier, with nothing else on the GPU, a Loinnir instance took ten
seconds to close. The Venus ring's teardown waited out its timeout for
a timeline-0 fence, as if that fence's answer came without an
interrupt. virtio-gpu now harvests every 5 ms while a fence is in
flight, and the stall hasn't been seen since. The cause isn't confirmed.

Not yet: UIGPU, buffer objects, and the frame's copy through the CPU
(todhchai's Radharc used the display's image as the GPU's buffer,
VK_FUCHSIA_external_memory).
