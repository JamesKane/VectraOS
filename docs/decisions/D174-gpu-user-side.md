# D174. The GPU's user side: native drivers serve a narrow core interface shaped like Loinnir, Loinnir runs on it everywhere, and Vulkan for ports is one layer over it; Mali's driver and our own SPIR-V compiler are the first (2026-11-20, proposed; the owner answered D55's open question; D173 §9's second half)

D173 ran command streams on the G720: a stream the client wrote by hand.
Drawing and computing need the user side:
- a compiler from SPIR-V to the GPU's ISA;
- descriptors, command-stream recipes and formats;
- an interface through which programs reach all of these.

chinese-wall's `specs/valhall` (00 to 17, reviewed) describes Mali's user
side. D55 left open whether all of Vulkan is the drivers' interface. The
owner answered (2026-11-20): Vulkan is exposed for low-level ports, and
native applications get Loinnir's shape.

## The decision

1. **The core interface** (`graphics/core`, module `GPUCore`) is what a
   native GPU driver implements. It has Loinnir's shape and nothing more:
   - **Devices and queues:** one device per GPU, a graphics-and-compute
     queue, and a compute queue where the GPU has one.
   - **Memory:** allocated by intent (D56: upload, device, readback).
     Each allocation has a 64-bit GPU address and, where the intent
     allows, a CPU pointer.
   - **Images:** a format, a size and a usage, and a layout the driver
     picks and tracks. There are no image layouts at the interface.
   - **One bindless heap per device:** textures, samplers and storage
     images by index. On Mali the heap is a resource table (valhall 03).
   - **Pipelines:** made from SPIR-V by the driver's compiler. A
     pipeline's only binding is the heap plus a 64-bit root pointer, one
     pipeline layout everywhere, as Loinnir has it.
   - **Command lists:** compute dispatches (direct and indirect), passes
     with dynamic rendering, draws (direct, indexed and indirect),
     copies, and barriers that name stages only (D58).
     - A render pass says what happens to each attachment's contents at
       its start and end (load, clear or don't-care; store or discard).
       A tiler needs that before the pass begins.
   - **Submission:** each submission takes a 64-bit timeline value to
     wait on and one to signal. These are the GPU class's counters
     (D121, D25).
   - **Queries:** the timestamp and the pass's occlusion counts.

   It is Swift and tier 0, as Loinnir is. It is built so the Vulkan
   layer (§4) can be written on it without reaching around it.
2. **Native drivers implement the core.** Mali's is `graphics/mali` (module
   `MaliCore`), a client of mali(3)'s `csf` capset (D173 §7). It
   contains:
   - the command-stream builder (valhall 01, 02);
   - the descriptors (03, 04);
   - formats and layouts (05);
   - draw state, tiler and framebuffer (06 to 08), and blend (09);
   - the compiler's backend (§3).
3. **One compiler** (`graphics/compiler`) has three parts:
   - a SPIR-V front end;
   - an SSA intermediate form and its passes, shared by every backend;
   - per-GPU backends. Valhall's (`graphics/compiler/valhall`) does
     instruction selection over 11a to 13, scheduling and wait slots
     (15), register allocation in the two classes (04, 15: the 32
     class is r0 to r15 plus r48 to r63), the ABI (14), and encoding
     (10).

   The compiler runs on the device, in the driver, at pipeline creation,
   with a cache keyed by the SPIR-V's hash and the GPU's id. Ports need
   that, since they hand the driver SPIR-V at run time. The same code
   builds on the host for its tests, and for `vx shaders` to check a
   shipped shader compiles for each GPU named in `docs/hardware`.
   SPIR-V itself is still made on the host (D55).
4. **Vulkan for ports is one layer over the core** (`graphics/vulkan/
   drivers/core`). It is behind our loader (D121), for tier 1 programs
   (D55's ports). It is not a Vulkan driver per GPU: each new native GPU
   gets Vulkan by implementing the core.
   - It implements Vulkan 1.3 with dynamic rendering, descriptor
     buffers, buffer device address and timeline semaphores. Render
     passes, descriptor sets and pipeline layouts are lowered onto the
     core's one heap and root pointer.
   - What the core can't express is left out and listed in its page.
     Conformance is a report, not a claim.
5. **Loinnir runs on the core everywhere.** Its Vulkan calls today become
   a core backend over Vulkan (`graphics/core/vulkan`), the one Venus is
   reached through under QEMU. So Loinnir has one interface, not two.
   boot-venus keeps testing the Loinnir-over-core-over-Venus path, and
   the board tests the native path.
6. **The order,** each step checked on the board before the next is built
   on it:
   1. **Compute.**
      - Pieces: the core's memory, heap and compute dispatch; MaliCore's
        command-stream builder, buffer descriptors, shader program and
        thread storage; the compiler's front end, IR and the Valhall
        backend for ALU, memory and control flow.
      - Check: `gpu-test` dispatches a compiled compute shader that
        writes a buffer, read back exactly (`ok: a compute shader ran`).
   2. **A triangle.**
      - Pieces: IDVS position and varying shading, the tiler with its
        heap, and the framebuffer. mali(3) has to acknowledge TILER_OOM
        here (D173's open item).
      - Check: a triangle drawn offscreen and read back, compared with
        the CPU's reference image.
   3. **Textures and blend.**
      - Pieces: images and their layouts (linear and u-interleaved
        first, AFBC later), samplers, texture instructions, fixed-
        function blend and blend shaders.
      - Check: loinnir-test's draw tests, natively on the board.
   4. **Loinnir on the core everywhere** (§5).
      - Check: Radharc's GPU renderer composes the desktop on the board,
        and boot-venus still passes.
   5. **The Vulkan layer** (§4).
      - Check: a tier 1 Vulkan test program runs its compute and its
        triangle on the board and under Venus.
7. **Tests the host runs:**
   - **The encoder:** every word against the encoded examples in valhall
     10 to 13.
   - **A Valhall interpreter** in Swift, from the spec's semantics, for
     the ALU, memory and control-flow subset. Compiled shaders run on it
     on the host, against the same shader's result computed on the CPU.
     It tests the compiler, not the hardware: where the board disagrees,
     the spec's text is fixed first and then the interpreter.
   - **The front end:** a corpus of SPIR-V from the tree's own shaders
     and Loinnir's tests.
   - **The scheduler and wait-slot rules** (15) checked over every
     compiled shader as a validator. A missed wait is a test failure,
     never a hang found on the board.
8. **Budgets.** Each step's check reports its time:
   - `gpu.mali.compute_dispatch_us`: submit to done, for a one-workgroup
     dispatch.
   - `gpu.mali.triangle_ms`.
   - `gpu.mali.textured_quad_ms`: the textured quad of step 3, submit to done.
   - `compiler.valhall.compile_ms`, for each corpus shader.

   Their limits are set from the first recorded board runs.
   On the Orange Pi 6 Plus, which aims at 1080p or lower (the owner,
   2026-11-21), `theme.compose.1080p` is judged natively once step 4 is
   done (target 2 ms); `theme.compose.4k` is reported there, not judged
   (its ceiling and the paths to it are in docs/performance.md).
9. **The clean room holds:** every agent writing this code reads
   `specs/valhall`, `specs/panthor` and this tree, and never Mesa, Linux or
   chinese-wall's provenance. A question the spec can't answer is sent to
   the dirty room as a question. The answer comes back as spec text, never
   as code.

## Not chosen

- **All of Vulkan as every driver's interface,** with Loinnir over it (what
  runs under Venus now). Each native driver would carry render passes,
  descriptor sets and layouts, and Loinnir would pay for translating its
  own model into Vulkan's and back.
- **A Vulkan driver per GPU** beside its core. That doubles each driver,
  and the layer's lowering is the same for every GPU.
- **Compiling to the ISA on the host,** as for SPIR-V today. Ports need
  run-time compiles, and one compiler in two places is the same code.

## Open

- Whether the core keeps a separate compute queue on Mali. CSF groups make
  any number of queues cheap; a priority group for the compositor is
  likely.
- The cache's home for compiled shaders: per process, or a system cache
  in fs.
- Whether an sRGB colour target's render target descriptor should set its
  own sRGB bit (valhall 08 8.4.1, word 1 `[14]`) as well as the blend
  descriptors' (09 9.6.1). Step 4 leaves it clear, reading the tile as
  encoded (08 8.7.2 rule 3), and the board's colours came out exact; the
  spec does not say.

## Step 4, as built (2026-11-21)

Radharc's GPU renderer composes on Mali through Loinnir and the frame
reaches linlon with no copy: the targets are `scanout` images (Mali
buffers whose VMOs are exported to the display driver), drawn into in turn
and presented. The compiler makes a texture handle uniform across a warp
with a loop over the distinct values (12b.2.1, Q16), which compose.frag
needs because its texture index is a flat varying. The numbers are in the
Orange Pi 6 Plus notebook.
