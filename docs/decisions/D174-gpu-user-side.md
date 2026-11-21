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

## Step 5, the design (2026-11-21)

The Vulkan layer is a driver in the loader's registry (D121), module
`VulkanCoreDriver` in `graphics/vulkan/drivers/core`, written on
`GPUDevice` and nothing beside it. Three parts:

1. **The lowering** (`graphics/vulkan/drivers/core/lowering`, module
   `VulkanLowering`). It is pure, the same for every GPU, and tested on the host. It
   rewrites a Vulkan program's SPIR-V into the core's interface, once per
   pipeline stage, at pipeline creation:
   - **Descriptor sets:** `Uniform`, `StorageBuffer` and `UniformConstant`
     variables with a `DescriptorSet` and `Binding` become loads through
     the root block. Buffers become `PhysicalStorageBuffer` pointers, with
     the same `Block` offsets and `Aligned` operands. Images and samplers
     become elements of the heap's arrays: set 0, binding 0 `texture2D[]`,
     binding 1 `sampler[]`, binding 2 storage images, indexed by the slot
     read from the set record. A combined image sampler is split into an
     `OpSampledImage` of the two.
   - **Push constants:** the program's block becomes a pointer to the root
     block's push-constant bytes. The core's own push-constant block (one
     buffer reference: the root) is added in its place.
   - **Vertex input:** each `Input` variable at a location is fetched from
     its binding's vertex-buffer address in the root block. The index is
     `VertexIndex`, or `InstanceIndex` for a per-instance binding. The
     format is converted in the shader. Offsets and strides are multiples of
     4.
   - Its interface: `SetLayout(bindings:)` assigns each binding its byte
     offset in a set record, and `lower(spirv:stage:entryPoint:layout:specialization:)`
     returns the rewritten words or a `LoweringError` that names what it
     can't lower.
2. **The ABI between the two,** fixed here:
   - The root block (the core's root pointer points at it), 288 bytes:
     - offset 0: `u64 set[4]`, the set records' addresses (0 when unbound);
     - offset 32: `u64 vertexBuffer[8]`, each bound buffer's address plus
       its offset;
     - offset 96: 128 bytes of push constants;
     - offset 224: `u32 dynamicOffset[16]`, the dynamic offsets of the bound sets, in the pipeline layout's order (the
       sets in order, each set's by binding and element). A dynamic buffer's record is the plain one, and the shader
       adds its word to the descriptor's address.
   - A set record: binding `b`'s element `i` is at `offset(b) + 16 * i`.
     Every descriptor is 16 bytes, which is also the descriptor size that
     descriptor buffers report:
     - a uniform or storage buffer: `u64 address, u64 range`;
     - a sampled image, a sampler or a storage image: `u32 slot`;
     - a combined image sampler: `u32 textureSlot, u32 samplerSlot`.
   - A heap slot belongs to the object: an image view with sampled or
     storage usage takes its slot when it is made, and a sampler takes its
     slot when it is made. Writing a descriptor writes only the slot number.
3. **The driver.** It hands out Vulkan's handles over the core's:
   - **Dispatchable objects** leave their first word for the loader
     (`ICD_LOADER_MAGIC`), as Venus's do.
   - **Devices and queues:** one physical device per `GPUDevice`, apiVersion 1.3, and
     one queue family (graphics, compute and transfer). Its limits are taken
     from `DeviceLimits`: heap sizes, 4 sets, 128 bytes of push constants.
   - **Memory:** there are three memory types, one per intent: device-local
     (`.device`), host-visible and coherent (`.upload`), and host-visible,
     coherent and cached (`.readback`). The core makes the bytes coherent at
     `submit` and at the timeline. A `VkBuffer` is its memory plus an offset,
     and its device address is the allocation's address plus that offset.
   - **Images:** a `VkImage` is a core image, 2D, one mip level and one
     layer, made at `vkCreateImage`. Its memory requirements are nominal and
     `vkBindImageMemory` records nothing. A view is the whole image. Layouts
     and layout transitions are ignored, since the core tracks them.
   - **Commands:** a command buffer records a `GPUCommandList`. A draw or a
     dispatch writes a root block into the command buffer's upload arena
     (64 KB chunks of `.upload` memory). Set records live in their
     descriptor pool's `.upload` memory and are read when the work runs, as
     Vulkan says.
     - A render pass of one subpass with colour attachments, and
       `vkCmdBeginRendering`, both become `RenderingInfo`.
     - Barriers keep their stages and drop everything else.
     - `vkCmdUpdateBuffer` and `vkCmdFillBuffer` become copies from the
       arena.
     - `vkCmdClearColorImage` becomes a pass that clears and draws nothing.
   - **Synchronisation:** every fence and semaphore is a value on the
     device's one timeline:
     - a submission waits for the greatest value among its waits and
       signals the next;
     - a timeline semaphore maps its own values to the device values that
       signalled them, and a host signal is reached at once.
4. **What the driver leaves out,** listed in its page:
   - depth and stencil, culling, and blend other than off or source-alpha
     over;
   - subpasses after the first, secondary command buffers, and blits and
     resolves;
   - images that aren't 2D, mip levels and array layers, and a view of
     part of an image or of another format;
   - partial image copies, presentation (WSI), and aliased image memory.

   What a backend lacks (`DeviceFeatures`) stays lacking. Mali has no indexed
   or indirect draws, queries or loaded attachments yet. A command buffer
   that needs one fails `vkEndCommandBuffer` with
   `VK_ERROR_FEATURE_NOT_PRESENT`, and the debug message names the feature.
5. **The registry and the check:**
   - The program `vulkan-test` (tier 1, C, `user/tier1/vulkan-test.c`) runs
     two tests:
     - a compute shader over two storage buffers and a push constant, read
       back exactly;
     - a triangle from a vertex buffer, in a render pass, read back and
       compared with the CPU's reference, exact away from the edges.
   - It is linked against tier 1's builds of the loader, the driver, the core
     and its backends.
   - The registry picks the device:
     - on the board, `MaliDevice`;
     - under QEMU, `VulkanDevice` over Venus, given Venus's
       `vkGetInstanceProcAddr` directly, not through the loader, which
       would find this driver again.
   - boot-venus and board-test run it, and each prints
     `ok: vulkan compute` and `ok: vulkan triangle`.

### Part 5, the plumbing as built (2026-11-21)

`vulkan-test` (`user/tier1/vulkan-test.c`) exists and passes on raw Venus under QEMU, which proves its two tests and tier 1's
builds of the GPU stack before the layer lands:

- **Tier 1 libraries** (`cmake/Tier1.cmake`): GPUDevice, GPUClient, VulkanLoader, Vulkan, Venus, VenusDriver, VenusClient (Venus's
  transport and `connectVenus`), VulkanDriversNative (the native registry), GPUCore, GPUCoreVulkan, ShaderCompiler, ValhallISA,
  MaliCore, ValhallBackend, GPUCoreMali and VulkanLowering, each shared, in bootfs's `lib/`. The compiler's parts are modules of their
  own here, as under SwiftPM; tier 0 still compiles them into GPUCoreMali.
- **Two registries, one linked:** the native one (raw Venus), and `graphics/vulkan/drivers/core/registry` (module
  `VulkanCoreRegistry`), which gives the loader `VulkanCoreDriver` over `MaliDevice()` where `csf` is offered, else over
  `VulkanDevice(library:)` made from `VulkanLibrary(getInstanceProcAddr:)` on Venus's. Tier 1's CMake builds `VulkanCoreDriver` and
  that registry, and `vulkan-test-core` against them, as soon as `graphics/vulkan/drivers/core/lib/*.swift` exists; the images then take
  `vulkan-test-core` as `bin/vulkan-test`. The registry sets `CoreDriver.device` (Mali, or `VulkanDevice` over Venus) and `CoreDriver.message`, and returns `coreGetInstanceProcAddr`; vulkan-test passes through the layer on Venus under QEMU (amd64, arm64).
- **boot-venus** runs it as a service beside loinnir-test; compose-test waits for it and fails unless it exited 0. **board-test**
  starts it as an app after loinnir-test where the image has it (tier 1 built).

## Step 5, as built (2026-11-21)

`vulkan-test` passes through the layer on the Orange Pi 6 Plus. There it
runs through the loader, then `VulkanCoreDriver`, then the lowering, then
`MaliDevice`, and our compiler produces the Valhall code. Under Venus it
passes on amd64 and arm64.
- On the board, the compute test reads back exactly, and the triangle has
  0 wrong pixels of 3771 judged.
- The layer gives Venus lowered SPIR-V, and Venus's drivers take it.

What the design didn't settle:
- **Bound sets:** they are kept per bind point (compute and graphics), as
  Vulkan says.
- **Buffer lengths:** `OpArrayLength` is computed from the descriptor's
  range. For a stride that isn't a power of two that takes an integer
  division, which the Valhall backend doesn't select yet, so such a
  program compiles only under Venus.
- **The tier 1 build:** the compiler's parts are modules of their own
  here, as under SwiftPM, where tier 0 compiles them into GPUCoreMali.

Tier 1's toolchain now builds on a macOS host as well as on Linux
(`tools/toolchain`), so board images made on the Mac carry tier 1.

## Amendment: the full feature set (2026-11-21, accepted by the owner)

The owner (2026-11-21): the GPU stack "is supposed to have a full GPU
feature set". §1's "Loinnir's shape and nothing more" now applies to the
*model*, not the *coverage*. The model stays:
- one bindless heap;
- one root pointer;
- command lists as data;
- layouts that are the device's own;
- one timeline.

What the GPU can do, the core says, and the Vulkan layer exposes it,
lowered onto that model. A backend that lacks something says so in
`DeviceFeatures` or `DeviceLimits`, as today.

### 1. The core's additions (all source compatible: new fields have defaults that mean today's behaviour)

- **Formats:** `PixelFormat` gains the colour formats Vulkan requires
  for sampling, rendering and storage, plus the depth/stencil and
  compressed formats.
  - Colour:
    - r8, rg8 and rgba8 in unorm, snorm, uint and sint, and rgba8 and
      bgra8 in sRGB;
    - r16, rg16 and rgba16 in float, uint and sint;
    - r32, rg32 and rgba32 in float, uint and sint;
    - rgb10a2 unorm, rg11b10 float and rgb9e5.
  - Depth and stencil: depth16, depth32f, depth24stencil8,
    depth32fstencil8 and stencil8.
  - Compressed: ASTC LDR (every block size, unorm and sRGB) and ETC2/EAC.
    BC is supported only where a backend has it.
  - The existing cases keep their names.
  - A format describes itself: `texelBlock` (width, height, bytes),
    `aspects` (colour, depth, stencil) and `isCompressed`.
  - `DeviceLimits.formats(_:)` returns a format's capabilities: sampled,
    filterable, render target, blendable, storage, storage atomic, depth
    target, and the sample counts for each.
- **Images:** `ImageDescriptor` gains `dimension` (2D, 3D, cube), `depth`,
  `mipLevels`, `layers` and `samples`, and the usage `depthStencilTarget`.
- **Views:** `ImageView` is an image, a format compatible with it, a mip
  range, a layer range and a view dimension (2D, 2D array, cube, cube
  array, 3D).
  - The heap's `writeTexture` and `writeStorageImage`, and a pass's
    attachments, take a view.
  - The image-only overloads stay, meaning the whole image.
- **Samplers:** `SamplerDescriptor` gains
  - minification and magnification filters, and the mip mode;
  - the U, V and W address modes, and a border colour;
  - a LOD bias, minimum and maximum, and anisotropy;
  - a compare operation, and unnormalized coordinates.
- **Pipelines:** `GraphicsPipelineDescriptor` gains:
  - **depth and stencil:** a format, test, write, a compare operation,
    stencil front and back (fail, pass and depth-fail operations; compare,
    masks, reference), and depth bounds;
  - **rasterization:** cull (none, front, back, both), front face,
    polygon mode (fill, line, point), depth bias, depth clamp, line width,
    and rasterizer discard;
  - **multisample:** a sample count, a sample mask, alpha to coverage,
    alpha to one, and sample shading;
  - **blend:** per attachment, every Vulkan factor and operation, a write
    mask and a logic operation. `BlendMode` stays, as shorthand for the
    two cases it has.
  - **topology:** line strip, triangle fan, primitive restart, and patch
    lists where there is tessellation.
  - Optional stages beyond vertex, fragment and compute, where a backend
    has them (`features.geometryShader`, `features.tessellation`).
  - Specialization constants: a map from constant id to value.
- **Passes:** `RenderingInfo` gains
  - a depth/stencil `Attachment` with its own clear;
  - a resolve view per colour attachment (MSAA);
  - a layer count, a view mask (multiview), and a render area.
- **Commands:**
  - `copyImage`, `blitImage` and `resolveImage`, with regions (mip,
    layers, offset, extent);
  - buffer↔image copies with regions and a row length;
  - `fillBuffer` and `updateBuffer`;
  - `clearColorImage`, `clearDepthStencilImage`, and `clearAttachments`
    inside a pass;
  - dynamic state: blend constants, stencil reference and masks, depth
    bias, depth bounds and line width;
  - `drawIndirectCount` and indexed-indirect-count;
  - pipeline-statistics queries;
  - barriers stay stages-only. A subresource range is accepted, for
    backends that can use it.
- **Memory and sharing:** `importHandle(_ vmo:)` makes memory or an image
  over another process's pages. It is the other half of `exportHandle`,
  and is what zero-copy present needs (see 3).
- **Features and limits:** one flag or limit per item above. The items
  are depth, stencil, maxSamples, mips, array images, cube, 3D, anisotropy,
  the compressed families, independent blend, dual-source blend, logic
  operations, the non-fill polygon modes, wide lines, depth clamp, depth
  bounds, geometry and tessellation, multiview, and the shader capability
  set (float16, int8 and int16, int64, float64, subgroup operations,
  32- and 64-bit atomics, image atomics, derivatives, and the rest SPIR-V
  names).
  - `GPUCommandList.validate` judges every new command, still in one
    place.

### 2. The compiler

The compiler covers every SPIR-V capability that a Vulkan 1.3 device on
the GPU must have, and the optional ones the hardware runs:
- the image operations: sample with bias, grad and LOD, gather, fetch,
  query, compare, and image read, write and atomics;
- derivatives, subgroups, all atomics, and 8-, 16- and 64-bit types;
- demote, and the built-ins.

A capability the spec doesn't document goes to the dirty room as a
question. Nothing is guessed.

### 3. Presentation (WSI) for ports, and zero-copy present for Loinnir

- One mechanism: a window's frames are GPU images whose pages Radharc
  composes directly, handed over by ownership of the VMO (the unified-
  memory rule). There is never a CPU copy.
  - Loinnir's on-device present (`graphics/loinnir/native/Present.swift`,
    which copies today) moves onto it.
  - Radharc imports a window's image with `importHandle` and samples it.
- The Vulkan layer adds `VK_KHR_surface`, a VectraOS surface extension
  (a Radharc window), and `VK_KHR_swapchain` over the same mechanism.
  - Swapchain images are exportable images.
  - `vkQueuePresentKHR` hands the image over at a timeline value.
  - Radharc's acquire returns it.

### 4. The order

Each item is checked on the board and under Venus, as before.
1. **The core's types and rules:** host-tested, every backend refusing
   what it hasn't got.
2. **The new state under Venus:** `GPUCoreVulkan` passes it through,
   checked by loinnir-test and vulkan-test under QEMU.
3. **Mali, fixed function:** depth/stencil, the rasterization state, the
   blend state, MSAA and resolve, mips, arrays, 3D and cube, the formats
   and compressed textures, blits and copies. Each gets a gpu-test check
   on the board.
4. **The compiler's coverage** (2), in step with 3.
5. **The Vulkan layer:** it maps everything onto the core, and its "left
   out" list shrinks to what the hardware lacks.
6. **Present:** zero-copy windows for Loinnir, then WSI for ports.
7. **Conformance:** the Khronos CTS (VK-GL-CTS) built as a tier 1 port, run
   as a report (D174 §4: conformance is a report, not a claim).

Spec gaps: an audit of `specs/valhall` against this list comes first.
Every gap goes to the dirty room as a question, so work isn't blocked
when it reaches the gap.

## The layer: specialization, dynamic buffers, immutable samplers and descriptor buffers (2026-11-21)

- **Specialization constants** are the lowering's: `lower` takes the SpecId values and folds `OpSpecConstant*`,
  `OpSpecConstantComposite` and `OpSpecConstantOp` (the shader-capable ops, on scalars and per component on vectors) to
  plain constants, and a `WorkgroupSize` constant or `LocalSizeId` becomes `LocalSize`. The core sees none. The driver
  passes each stage's `VkSpecializationInfo` through; the core's pipeline descriptor gets no new field for them.
- **Dynamic uniform and storage buffers: offsets in the root block, not adjusted records.** The ABI grows after the push
  constants (offset 224, `u32 dynamicOffset[16]`, root block 288 bytes) and every existing offset stays. Chosen over a
  per-draw copy of the set record because:
  - a draw already writes a root block, and 64 bytes beside it is cheaper than copying each dynamic set whole;
  - the record stays what `vkUpdateDescriptorSets` wrote (or what the application wrote into a descriptor buffer), one
    format, read when the work runs;
  - the offset is one 4-byte load and one add in the shader, per dynamic descriptor used.
  `DescriptorBinding.dynamic` marks the binding; `SetLayout.dynamicIndex` and `LoweringLayout.dynamicBase(set:)` give the
  word, numbered as Vulkan numbers the offsets of `vkCmdBindDescriptorSets`. 16 words cover Vulkan's 8 uniform and 4
  storage dynamic buffers.
- **Immutable samplers** are the driver's: their heap slots go into every set of the layout when it is allocated and
  updates leave them alone. The lowering reads the same record.
- **Descriptor buffers** (`VK_EXT_descriptor_buffer`): the set record is the descriptor buffer's layout (size and
  binding offsets are `SetLayout`'s, every descriptor 16 bytes); `vkGetDescriptorEXT` writes the 16-byte descriptor;
  binding a buffer at an offset puts that address in the root block's set slot. Not provided: push descriptors, capture
  and replay, embedded immutable samplers, and dynamic buffers in a descriptor buffer.
