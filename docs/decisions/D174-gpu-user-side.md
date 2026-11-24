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

   What a backend lacks (`DeviceFeatures`) stays lacking. Mali has no occlusion
   queries, atomics on storage images or the counted draws yet. A command buffer
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

### The layer maps the widened core (D174 amendment, step 5; 2026-11-21)

The layer reports and maps everything the core expresses, from the device and nothing else:

- **Features, limits and formats** are `DeviceFeatures`, `DeviceLimits` and `DeviceLimits.formats(_:)`, mapped onto
  `VkPhysicalDeviceFeatures(2)` and the 1.1 to 1.3 structures, the limits and properties, and the format and image
  format properties. A feature the device lacks is absent and never emulated; `vkCreateDevice` refuses one asked for.
- **Images** carry their mips, layers, volume, cube and samples, and views take levels, layers, dimension, aspect and
  a compatible format. Samplers carry the full state.
- **Passes:** a render pass is one core pass for each subpass; the first use of an attachment has the pass's load, later
  ones load, and the last has its store. Dynamic rendering and subpasses both carry depth and stencil, resolves, layers
  and the view mask (multiview).
- **State:** the pipeline's fixed state field for field, including each attachment's blend and the logic op; the state a
  pass's commands set is kept by the command buffer and sent before the draw that needs it.
- **Commands:** copies, blits, resolves, region copies, clears, `clearAttachments`, fills, updates, counted indirect
  draws, pipeline-statistics queries, secondary buffers (their lists appended to the primary's), events (barriers) and
  image barriers.
- **Left out** (then; sparse resources and more than one viewport are in since "Elsewhere, as built") is what Vulkan has and the core has no word for: 1D and swizzled views, sparse resources, input
  attachments, adjacency topologies, the dynamic state beyond the core's, more than one viewport, texel buffers,
  `vkCmdCopyQueryPoolResults` and presentation. The lowering's ABI and its specialization folding are as they were; it
  lowers the geometry and tessellation stages as stages.

## Order step 2: the new state under Venus (2026-11-21)

`GPUCoreVulkan` implements the whole of the widened core, and every `DeviceFeatures` flag and `DeviceLimits` value
comes from what the physical device behind it reports (Vulkan 1.3's mandatory set from the reported version; depth,
stencil, multisample, arrays and 3D from the formats and limits; the optional features from the feature structures).
Three stay false by choice: `alphaToOne` and `depthStencilResolve` (not enabled or replayed), and `importHandle`
(Venus implements only the export side of the Fuchsia external memory extension, and graphics/venus has no import
command). loinnir-test prints the flags once and, on the Vulkan backend, draws and judges depth, stencil, MSAA with
both resolves, culling, blending, mips by level of detail, 3D and cube textures, and the copy, blit, clear, fill and
update commands against CPU references (exact where the work is exact, within a stated tolerance where the hardware
rounds). A case the device lacks the feature for is skipped with the reason.

`vulkan-test` also runs a depth test (two screen-sized triangles, the nearer drawn first, all that may show) and a multisample test (the triangle into four samples, resolved by the pass: exact away from the edges, mixed on them), each skipped, and said so, where the device has no depth attachment or no four-sample colour; they print `ok: vulkan depth` and `ok: vulkan multisample`.

## Five things the core and the layer had left out (2026-11-21)

The amendment's rule is that only true hardware lacks are left out. Five things were left out that no hardware lacks, and are in:

- **1D images and views** (`ImageDimension.d1`, `ImageViewDimension.d1` and `.d1Array`, `DeviceFeatures.images1D`). The lowering takes 1D sampled and storage images, arrayed or not; the compiler already read and wrote them.
- **Mapped views** (`ImageView.swizzle`, `DeviceFeatures.imageSwizzle`). A mapping is for sampling: a storage view and an attachment that map components are `.invalid`.
- **A sampler's own border colour** (`SamplerDescriptor.customBorderColor`, `DeviceFeatures.customBorderColor`), from `VK_EXT_custom_border_color` where the host's Vulkan has it. The layer exposes the extension where the core's device has the flag. Under Venus the flag was false at first: its driver offered no device extensions of the renderer's (it forwards this one now: "Elsewhere, as built").
- **Texel buffers** (`BufferView`, `writeTexelBuffer`, `writeStorageTexelBuffer`, `uniformTexelBuffers`, `storageTexelBuffers`). They are two arrays of their own in the heap (bindings 3 and 4), not slots among the textures and the storage images: Vulkan holds a buffer view and an image view in descriptors of different types that no one array can hold, and Mali's resource table would hold each in its own right. The compiler lowers buffer images to the storage image's accesses with one coordinate and `ImgFlags.buffer`.
- **Input attachments.** The layer runs each subpass as a core pass and puts a barrier between them; the lowering reads an input attachment as a fetch of the attachment's texture at the fragment's own position.

`MaliDevice` has each flag false and refuses each cleanly, but the texel buffers' (below).

## Presentation, as designed (2026-11-21; the amendment's part 3 and order step 6)

Presentation is one mechanism, used by Loinnir and by the Vulkan layer, and the window protocol did not change.

- **A window's frame is a GPU image whose pages the window was given as one of its images.**
  - Radharc's `addImage` already takes a VMO with an acquire and a release counter; `present` already names the images of its layers and holds an image until a later present replaces it.
  - The SDK gains the calls for images the program draws elsewhere (`Loop.addImage`, `presentImage`, `imageIsFree`, `canPresent`, `removeImage`), beside the CPU surface's two. Both go through one `presentBuffer`, so the acquire counter, the release counter, the credit and the replay for a restarted compositor are the same for both.
  - The core owns the frame: `GPUDevice.makePresentImage` gives a `PresentImage` (an image to draw into, and the VMO the window is given), and nothing else makes one. Loinnir's window is a ring of three of them (`Present.swift`: no readback, no CPU copy); a Vulkan swapchain is two or three (`Presentation.swift`).
  - **Direct:** where the device exports the image's own pages and the window's reader can use them, the window's image is the GPU's image and presenting adds nothing to the GPU's work.
  - **Staged:** where it can't, the list that presents the frame ends with the GPU's copy of the image into host-visible memory the device exports tightly packed (`width` pixels a row), and the window's image is that memory. Under Venus the image's own pages are the host's, in the host's tiling, which no CPU of the guest can read, so staging is the path; the copy is the GPU's and the CPU touches no pixel.
  - Direct was off until Mali's present (below, "Mali present, as built"): a device says it presents direct with `DeviceFeatures.presentDirect`, and its window export is `exportWindowHandle`, a VMO the window maps, beside the display's `exportHandle(image)`, which can't be mapped. A device that presents direct never stages.
- **The acquire counter can't be the device's timeline today, so the CPU waits.**
  - Both are kernel counters in principle (D25, D121: a GPU class sync is a counter of the client's that the driver raises), and Radharc only reads an image's acquire counter at its vblank, never waits on it, so the timeline's counter would serve as every image's acquire counter with `acquire: <the signal value>`.
  - It is not reachable: under Venus the device's timeline is a Vulkan timeline semaphore in the host's renderer, and Mali's is a sync id inside `CSFTransport`, whose counter the GPU client keeps and gives no handle for.
  - So the present waits on the CPU for the timeline value (`GPUDevice.wait`), then the SDK raises the image's own acquire counter, and Radharc sees it at the next vblank. The wait is bounded by the FIFO's depth (one present in flight), and costs the application's thread the GPU's time for one frame.
  - To change: a `GPUDevice` that can say "a new handle to a counter that tracks the timeline" (default nil), `addImage` taking it as the acquire counter, and `presentImage` skipping the wait. One call each side, none of the protocol.
  - The release counter is as it was: Radharc raises it once a later present stops reading the image, and the swapchain's acquire and Loinnir's `frame` give an image out only once `imageIsFree` says so.
- **What Radharc does with the image.**
  - The CPU renderer maps and reads it, as for any image.
  - The GPU renderer uploads it each frame, as for any image (`GPURenderer.texture(scene:window:image:)`), and that is the only path under Venus, which has no import.
  - The hook is there and unused: `ImageState` keeps the window image's VMO, and where `device.importHandle` succeeds the renderer would sample the client's image directly instead of uploading it. Mali's import is the Mali agent's.
- **`VK_VECTRA_window_surface`** (vulkansurface(2); the vendor tag VECTRA is ours and unregistered, and the extension number in `vulkan_vectra.h` is a placeholder no Khronos extension holds).
  - `vkCreateVectraWindowSurface(instance, {title, width, height}, ...)` opens a window of Radharc's through the SDK on the program's behalf. The layer is given a `WindowSystem` (`CoreDriver.windowSystem`); the registry (`graphics/vulkan/drivers/core/registry/Windows.swift`) gives it one over VX, which owns the loop the program does not have. A host test gives it a fake.
  - `vkPollVectraWindowEventsVECTRA` takes close, resize (the size in pixels), key down and up (the HID usage as the key code, the unshifted character, the modifiers), pointer (pixels, button, press) and wheel; it never blocks. A port quits on Escape (`0x29`) and sees resizes.
  - `vkSetVectraWindowFullscreenVECTRA` is the one call beyond the brief: it asks for the window to fill the screen or go back, which arrives as a resize. A port wants it, and the boot test uses it to resize a window the way a user would.
  - The two take the instance first, as every instance-level command does, so the loader dispatches them. They are not in vk.xml, so they are not generated: the loader's `Vendor.swift` has their trampolines, and `vulkan_vectra.h` declares them and the structure beside `td_vulkan.h`.
- **The swapchain** (`VK_KHR_surface`, `VK_KHR_swapchain`, from vk.xml as the other Khronos extensions are).
  - Surface: the extent is the window's size in pixels, 2 to 3 images, the formats `B8G8R8A8_UNORM` and `B8G8R8A8_SRGB` (the bytes Radharc reads, 0x00RRGGBB, sRGB-tagged; premultiplied composite alpha tags the images `premultiplied`), usage colour attachment, transfer source and destination, and sampled where the device samples.
  - Present modes: **FIFO only.** The protocol queues one present per credit and has no way to replace one Radharc has latched, so there is no MAILBOX, and pacing is Radharc's: a present waits for the credit the last one's frame gives back.
  - A swapchain image is a `PresentImage`: an ordinary core image (render target, copy source and sampled, and the application's usage) with its own window image behind it, one for one, so an image is acquirable once Radharc reads its window image no more.
  - `vkAcquireNextImageKHR` returns an image the application doesn't hold and Radharc doesn't read, with the semaphore and fence signalled (nothing of the GPU's is outstanding on it: a present waited for its copy); a timeout of 0 is `VK_NOT_READY`.
  - `vkQueuePresentKHR` waits for its semaphores' device value, adds the copy where staged, waits for the timeline, and presents.
  - A window that changed size makes the next acquire `VK_ERROR_OUT_OF_DATE_KHR`, and a present of an image drawn for the old size `VK_SUBOPTIMAL_KHR`: it is shown at its own size and never stretched. `oldSwapchain` retires the old swapchain (presents on it are out of date) and its images stay with the window until it is destroyed.
- **Checks.**
  - The layer's host tests (`graphics/vulkan/drivers/core/tests/PresentationTests.swift`) run the swapchain over the fake device and a fake window system that models the credit and the vblank: acquire, present and release in order, FIFO pacing, resize and `oldSwapchain`, events, and what is refused.
  - boot-venus runs `vulkan-present` (vulkan-present(8)): 120 frames, fullscreen and back, and the pixels Radharc composed, read from `/svc/windows/pixel`. compose-test judges its exit, and presents Loinnir's window the same way.
- **Open items.**
  - The timeline as the acquire counter: done for Mali (below); under Venus it stays a host semaphore and the CPU waits.
  - Mali: done (below).
  - Radharc's GPU renderer sampling a window's image without the upload: done on Mali (below).
  - MAILBOX, which needs the protocol to replace a queued present; IMMEDIATE, which needs it not to wait for a vblank.
  - A swapchain's staging buffers are tied to its images one for one; two staging buffers shared among the images would halve the memory under Venus.
The Valhall backend takes them (valhall 12b.14.1: `LEA_BUF`, word 7 of the descriptor through `LD_PKA`, `LD_CVT` or `ST_CVT`), and `MaliDevice` keeps each descriptor in table 2 of the resource table, after the storage images (slots 1024 to 2047 the uniform texel buffers, 2048 to 3071 the storage ones), so a binding's handle is table 2 and its base slot and no new table is needed. `MaliDevice` has both flags on; every format of the specification's table has the two kinds, and none has the atomic capability, because on the Orange Pi 6 Plus (2026-11-21) no atomic add of a compiled shader took effect (on a texel buffer or a plain buffer), where fetches as four channels, stores and loads were exact and `LD_CVT` filled the channels a format lacks with (0, 0, 1) as 12b.14.1 infers.

## Mali present, as built (2026-11-23)

The amendment's second open item. On the Orange Pi 6 Plus, Loinnir's window and a Vulkan swapchain present through `makePresentImage` with no CPU copy of a pixel, and the CPU no longer waits for the GPU before a present.

- **One mechanism, said by the device.** `DeviceFeatures.presentDirect` says a window's frames are the device's own images; `GPUDevice.exportWindowHandle(image)` (default nil) gives the VMO a window maps, reads and may import, beside the display's `exportHandle(image)`, which can't be mapped. `makePresentImage` has no `direct:` any more: where the device presents direct the frame is a `scanout` image and never staged, and a frame it can't share is `.unsupported`; elsewhere (Venus) it is staged as before. Loinnir's window and the swapchain take whichever the device gives.
- **Rows as the standard has them.** A linear plane's row stride is a multiple of 64 bytes (valhall 05 §5.5.5, R1.1, and 03 §3.9.8), and as the reference does, the driver pads the layouts it chooses and refuses imports that break the rule, with no fallback (R1.4). Every linear image Mali lays out, render targets and `scanout` images included, has rows of `width * 4` rounded up to 64; `exportWindowHandle` gives the row stride with the handle, a `PresentImage` reports it (`stridePixels`), and the window is told it through the protocol's existing image stride (sdk(2)'s `addImage`). A staged frame's rows are `width` pixels, as the core's copy into memory writes them. The display's `exportHandle(image)` still needs rows of `width * 4` bytes. (A first version gave windows rows of exactly `width * 4` bytes, a rule of ours, not the hardware's: the texture unit read zeros from rows of 160 and 400 bytes.)
- **Import is on** (`importHandle`, judged by the whole of loinnir-test on the board). Imported memory is bound GPU-cacheable, as a client's own memory is (atomics work in it); an imported image write-combining, as the owner's scanout image is: the texture unit only reads it, and every job begins with the driver's clean and invalidate, so neither binding reads a stale line. An image import names its row stride (`importHandle(_:as:rowBytes:)`), which must be a multiple of 64 and at least the width's bytes. Memory imported in one process takes 64 GPU stores through the import, which the exporter's pages read exactly (the check first named a buffer holding the address as the root pointer, the test bug K1 found).
- **Radharc's GPU renderer samples a window's image in place** where the device imports it, with the window's stride: `Pixels` carries the image's VMO and a number new for each image added (`source`), the renderer keeps the import until the image goes, and cleans the CPU's caches over the VMO when the window presents (a CPU client's pages may be mapped cached; a GPU's are write-combining). Every Mali window is imported; an image the device refuses (a CPU client's rows that break the rule) is uploaded as before.
- **The timeline is the acquire counter.** Mali's timeline is a sync of `CSFContext`, whose counter the client keeps; `syncHandle` duplicates it with the basic rights and read (no write), `MaliTransport.syncHandle` and `GPUDevice.timelineHandle()` give it out. The SDK's `addImage(..., acquire:)` takes it as the image's acquire counter and `presentImage(..., drawnAt:)` names the value, which the replay to a restarted Radharc keeps; Loinnir and the swapchain pass the value of the frame's work and don't wait. A swapchain image the window did not take is waited for before it is free again.
- **Checks.** Host: GPUCoreMaliTests (padded rows in the render target descriptor, the window's export and its stride, imports refused for rows of 400 bytes and too short ones, the timeline handle), GPUCoreTests, VulkanCoreDriverTests (a direct frame's padded stride; direct swapchains add no work; the timeline as acquire counter, direct and staged, with no CPU wait). Board (board-test passed, 2026-11-23): loinnir-test's `present` cases, frames 64, 80, 112, 40 and 104 pixels wide in rows of 256, 320, 448, 192 and 448 bytes, every pixel the window reads with the stride exact, each imported with its stride and sampled exactly, the unpadded rows' import refused; the timeline's counter reads 111 after 111 and refuses an add; compose-test's window images on a second context of the GPU, 128 and 100 wide (rows of 512 and 448 bytes), both imported, nothing uploaded, each composed as the CPU composes it twice over the same pages. Rows of 320 and 448 bytes, multiples of 64 and not of 128 or 256, sampled exactly: R1.1's open question is answered, the rule is 64.
- **The whole loop on the board's display** (2026-11-23, the desktop image): `compose-test desktop`, started from a cpu session, starts vulkan-present, whose swapchain on Mali presents 120 frames to a window of the desktop's Radharc, fullscreen and back, and reads the composed pixels exact (`ee1157`, `ffff00`); Loinnir's window presents 30 of 30 frames through its ring and composes exact (`f0175d`); Radharc composes on Mali throughout. The first runs read every pixel at a quarter of its light: chords' `shortcuts` had no recorded grant on the board's volume, so Radharc's trusted prompt asked at each boot and dimmed the screen beneath it. The owner had the grant recorded from a cpu session (`attr /data/Settings/Grants Grants:chords.shortcuts true`).
- **Left open.**
  - Whether the texture unit also checks a plane's base and slice stride for 64 (R1.2), and whether a plane that breaks the rule raises a fault (R1.4): the backend keeps both at 64 and never builds such a plane, so nothing here depends on them.
  - Present images stay write-combining for the GPU, as every image that is not a storage image is; K1 (GPU-cacheable memory, merged 2026-11-23) changed nothing for them.

## Mali multisampling, clears in a pass and kept depth, as built (2026-11-23)

The amendment's third open item, its first part: each claimed after loinnir-test judged it on the Orange Pi 6 Plus.

- **Multisampling** (`multisample`, `maxSamples` 16): 2, 4, 8 and 16 samples, the hardware's patterns (valhall 07 section 7.9), which are Vulkan's standard locations, so `standardSampleLocations` holds. A multisampled image has a sample plane each, a surface apart (05 section 5.5.3); the tile plan divides by the samples (08 section 8.8). The render targets and the three attachment formats take every count, and are sampled at every count (a fetch of a sample; the frame shaders do it).
- **Resolves** (`resolveAttachments`, `resolveImage`): a target resolved and not stored is written by the writeback's Average into the resolve image, the folded resolve of 08 section 8.10.5. One both stored and resolved has a second render-target descriptor over the same tile offset in mode Average, the first Layered: no post-frame shader. The spec names only the reference's post-frame path for that; the board shows the two descriptors exact (the stored samples resolved again by `resolveImage` agree). `resolveImage` is the CPU's, as every copy is: each byte the mean of the samples', rounded. Depth and stencil are never resolved (`depthStencilResolve` stays off; 08 section 8.10.5 has only sample 0 and a post-frame shader for it, not yet made).
- **Kept attachments of a multisampled pass**: the frame shaders read the sample they run for (`texelFetch` of a multisampled texture with `gl_SampleID`), so the pass runs them per sample (draw flags 0 `[11]`, 08 section 8.10.3).
- **Sample mask, sample shading, alpha to coverage and to one** (`sampleShading`, `shaderSampleRateShading`, `alphaToCoverage`, `alphaToOne`): the pipeline's mask is the draw's flags 1; shading per sample is draw flags 0 `[11]`, binary on this hardware (06 section 6.9.4: any fraction above 0 shades every sample, as the reference does), and also where a shader reads the sample id or position or a blend shader runs; alpha to coverage is the hardware's mapping (flags 0 `[22]`, with "shader modifies coverage" and the late update; 6.9.4 says the mapping is no source's, so it is measured, not chosen: alpha 0.5 covers two of four samples, `0x800080c0` over a blue clear); alpha to one is a blend shader (09 section 9.2.2, as the reference does, the descriptor bit being unknown).
- **Clears inside a pass** (`clearAttachments`): a draw of the pass, in order with the others: a rectangle over the target with the cleared rectangle as its scissor; a colour attachment's through one of eight fragment shaders (one a location) writing the push words' colour opaquely, the other targets off; depth and stencil in one draw at the cleared depth, the test Always and written, the stencil Always and Replace by the value, no colour.
- **Kept depth and stencil** (`loadAttachments` for the depth and stencil attachment): the second pre-frame shader (08 sections 8.2.1.1 and 8.10, Early ZS Always) fetches the plane and writes the depth, or gives the stencil reference with the test Always and every operation Replace, the tests late (8.10.3.2). The compiler gained FragStencilRefEXT (`ZS_EMIT.stencil`, StencilExportEXT and the StencilRefReplacingEXT mode), and a user shader's stencil reference goes to the test (the descriptor's "stencil from shader"); `shaderStencilExport` is not claimed until a check of its own runs.
- **Polygon modes stay off** (`fillModeNonSolid`): valhall 06 section 6.4.6 finds no hardware path and none in the reference, which reports non-solid fill unsupported; this backend does as the reference does. A geometry-route rewrite (14 section 14.6.3) would be a mechanism of ours for something the GPU does not do.
- **Checks.** Host: GPUCoreMaliTests (MultisampleTests: the sample planes, the framebuffer's count and pattern, Average to the resolve image, the second descriptor of a stored and resolved target, the sample mask in flags 1, a clear's draw and scissor, the second pre-frame shader's mode, flags and descriptor), ValhallBackendTests (the stencil reference and depth in one `ZS_EMIT`), MaliCoreTests, GPUCoreTests, VulkanCoreDriverTests. Board (board-test passed, 2026-11-23, loinnir-test 91 core cases passed, none skipped): `msaa: 2/4/8/16 samples resolved by the pass` (the edge pixel the mean of its covered samples within 2), `stored and resolved by one pass ... resolved again`, `kept by a second pass`, `a sample mask of samples 0 and 2 of 4`, `sample shading ... (gl_SampleID)`, `alpha to one`, `alpha to coverage ... 0.5 some (0x800080c0)`, `clears: a rectangle of a pass's attachment cleared inside the pass, 64 pixels exact`, `depth kept ... 1024 of 1024 pixels exact`, `stencil kept ... 1024 pixels exact`.

## Mali layers and depth resolves, as built (2026-11-23)

The rest of item 3 but multiview, each claimed after loinnir-test judged it on the Orange Pi 6 Plus.

- **Attachments are views.** A pass's attachments were the whole image before (a view's layer or level was not looked at, so a pass into a mip level or a layer drew into level 0 of layer 0); now each is its view's first layer's level, drawn at the level's size, its rows and layer stride the plane's.
- **Passes of layers** (valhall 08 section 8.12, 07 section 7.8): a descriptor group and a `RUN_FRAGMENT` each, the internal layer index and the layer as the frame argument, a tiler context for each eight layers (count and offset), every group naming its context. A draw whose vertex shader writes Layer (`shaderViewportIndexLayer`, now claimed) is issued once a context, with the layer index enable and the extended position record (06 sections 6.2, 6.6.1); one that doesn't goes into the first context only. Ten layers drew exactly, so the hardware drops a layer outside a context's range (7.8.1's open point, now measured).
- **A FINISH_FRAGMENT for each context** (01 section 1.9.7, 07 section 7.10, answered from the dirty room's inbox, L1): from context 0 up, each with its own completed top and bottom and the increment clear, then one `HEAP_OPERATION` fragment completed; one context keeps its single incrementing FINISH_FRAGMENT. Every one waits only for the fragment runs' slot and signals the finish slot. The first try chained them, each later one waiting on the slot it signalled, which never ends (01 section 1.11): ten layers drew right, then the queue stalled for 5 s and the group was lost. The interim fix, one FINISH_FRAGMENT with the last context's words, handed back only that context's chunks, a leak over many passes (7.10). On the board, 97 passes of 10 layers in a row are clean and the last exact; the heap's context and its chunk's header read zero throughout, also with the leaky form (each pass's heap descriptor starts the one chunk afresh and no kernel heap grows, so the leak can't show in this heap, which board-test's `OOM events 0` also says).
- **The frame shaders read arrays**: each loads its layer of an array view of the pass's layers (`gl_Layer`, register 62, the frame argument), so kept attachments of a pass of layers load each layer. `clearAttachments` of layers draws an instance a layer through a vertex shader that writes Layer.
- **Depth and stencil resolves** (`depthStencilResolve`): sample 0, the only depth resolve 08 section 8.10.5 has; a plane not stored is written by the writeback (Single) into the resolve image, one stored and resolved has its sample 0 copied by the CPU after the pass (the CPU does every copy).
- **Multiview stays off.** The vertex stage of arch 12 has no view number: the compiler would replicate every output for each view at the view's slot offsets (07 section 7.8.2, 12c.4.1), which the spec infers; the questions it leaves (bit position or ordinal, which views to store, the varying buffer per view) are in the same inbox file (L3).
- **Checks.** Host: GPUCoreMaliTests (a pass of 10 layers: ten groups with their layer index, frame argument, context and target layer, the two contexts' counts and offsets, ten fragment runs, a draw without Layer issued once). Board (board-test passed, 2026-11-23, loinnir-test 97 core cases passed, none skipped): `layers: a draw of an instance a layer into 3 layers ... 768 texels exact`, `into 10 layers ... 2560 texels exact`, `3 layers kept by a second pass ... 768 texels exact`, `a rectangle of layers 1 and 2 of 3 cleared inside a pass, 768 texels exact`, `a pass into a view of layer 1, level 1 ... 640 texels exact`, and the depth resolve of 4 samples (discarded and stored, every texel exact; its line was dropped by the console, the count of cases says it passed). vulkan-test's multisample case now runs on the Mali backend and passes.

## Mali multiview, as built (2026-11-23)

Built as the dirty room's answers to L3 and M1 say (07 section 7.8.2, 12c.4.1, 12c.4.2): one invocation shades all the views; the compiler replicates a vertex shader's blocks for each view of the pipeline's mask (`BackendOptions.viewMask`, `Prep.replicateViews`), ViewIndex a constant in each copy, every output stored once per view in the mask at `r59` plus the view's bit position times 4 slots (8 with the extended record; the offset on `LEA_BUF_IMM`'s index), `VARY_SIZE` one view's block, the basic record unless the shader writes point size, layer or primitive id; a fragment's ViewIndex is its layer (register 62). A multiview pass has one tiler context of (highest view + 1) layers, every draw's primitive flags name the mask, and a descriptor group and a `RUN_FRAGMENT` for each view in the mask; `clearAttachments` uses the clear's vertex shader replicated for the pass's mask; kept attachments load each view's layer. `multiview` is on, `maxMultiviewViews` 8 (no geometry or tessellation stages, so neither multiview flag of those).

The first build substituted the original's ViewIndex before cloning it, so every copy kept the first view's constant and stored the first view's values at its own slots: on the board the second view drew the first's, at the bit positions and (a probe) at the ordinals alike. The question went to the dirty room (M1); its answer pointed at the replication, and with the substitution after the cloning every mask is exact: 0b0011, 0b1010, 0b1100, 0b1001, 0b0001 and 0b0010, with the views at their bit positions (the ordinals still wrong, as the answer says). loinnir-test's case (views 1 and 3 of 4 layers, each its own position and colour, the others untouched; the views kept by a second pass and a corner cleared inside it in both) is exact, board-test passed with 102 core cases, none skipped. Host: ValhallBackendTests (mask 0b1010: positions and varyings at slot offsets 4 and 12, the views' own constants, 1.5 and 3.5).

## Mali transfers on the GPU, as built (2026-11-23)

The amendment's open item "copies and blits as GPU passes". Every transfer command runs on the GPU as a compute dispatch of the backend's own kernels (graphics/core/mali/shaders: `copy`, `blitRaw`, `blit`; compiled by our compiler at first use, as the clear and frame shaders are), a step of the list like any pass or dispatch: no submission split, no CPU wait or cache maintenance before it, no pixel the CPU writes. The clears of a pass with no draw, its queries' zeroing, and the sample-0 copy of a depth and stencil attachment both stored and resolved (which D174's multisampling section left to the CPU) are kernels too; `Step` has no CPU cases left.

- **Compute, not draws, for every transfer.** The spec allows either: a GPU copy "runs as a compute job or a draw", reading a buffer "through memory accesses, not through a texture plane", its rows landing in the image's 64-byte layout (valhall 05 §5.11.10.1, R1.4); copies may be compute work for ordering (02, the stage table). Every image here is linear (no AFBC, so no layout needs the tile writeback to produce it), so a copy is rows of bytes at known strides. A draw would need its destination to be a render target, and of the formats a blit or clear reaches only `rgba8`, `bgra8` and `bgra8srgb` are render targets on this backend; the tile clear of 08 §8.7 likewise. A draw-based path would cover three formats and need preloads for partial rectangles (08 §8.11: a tile cut by the box is written whole); compute covers all of them with one mechanism.
- **`copy`** moves rows of 1, 2, 4, 8 or 16-byte units (the largest the addresses and strides allow), in slices and layers, one dispatch for every region and aspect of a command (workgroup z names a slice of a job through a table in the parameters). It does memory to memory, buffers and images both ways (any row length and image height, mips, layers, volume slices), `copyImage` (blocks of a compressed format, a depth plane's 4 or 2 bytes and a stencil plane's 1, sample planes one to one), `fill` (a 16-byte pattern, a unit stride of 0) and `update` (its data staged in memory of the submission's), and the clears over subresource ranges (the texel's bytes, made once by the CPU's codec from the value). Moving bytes unchanged is what the reference's raw views give its copy paths (05 §5.3.2 [POLICY]: depth as a 4-byte unsigned colour, stencil as 1-byte; 03 §3.8.5: same-size reinterpretation, a compressed block as one 64 or 128-bit texel on linear layouts), without needing a view: memory accesses see bytes. `resolveImage` is the same kernel averaging each byte over the samples, rounded, as the tile writeback averages an 8-bit normalized target (08 §8.3.2) and as the CPU did.
- **`blitRaw`** does a blit of one format with the nearest filter (a depth and stencil blit's only form in Vulkan): each texel's bytes from the source texel nearest its centre, scaled, corners in either order flipping it. `depth`, `stencil` and the combined formats are now blit destinations.
- **`blit`** does one that filters or converts: the texture unit reads the source (the filter, the format's and sRGB's decoding are the hardware's), through a heap of the dispatch's own (a nearest and a linear sampler, clamp to edge, the clamp-integer bits clear as 03 §3.7 says the reference leaves them for its blit shaders; the source level as a 2D array, a 3D texture for a filtered volume, an integer volume's slices as an array, fetched), and the kernel encodes the destination's format and stores it (unorm, snorm, sRGB, float16 and 32, the integers saturated, rgb10a2, rg11b10f, rgb9e5). Integer sources are fetched at the nearest texel (never filtered).
- **The compiler** read an 8 or 16-bit integer type only with `Int8` or `Int16`; SPIR-V also declares one for storage alone under the storage capabilities (`StorageBuffer8BitAccess` and its kin), which is how glslang emits the kernels' byte loads and stores, so the reader takes either.
- **Ordering** is as before for every step: each step but the last is submitted and waited for before the next, the last signals the timeline; barriers stay stages-only. The CPU's caches over readback memory are brought up to date in `wait`, not between steps.
- **Checks.** Host: GPUCoreMaliTests run the kernels on the interpreter over the fake transport's memory (KernelRunner.swift; the texture unit modelled for `blit`), so the existing byte-level resource tests judge the GPU path, and TransferTests add a list of every transfer between two passes (eight dispatches on the compute group, only the last step signalling, no buffer maintained), rows of 1 to 16-byte texels with row lengths and image heights into a level of two layers, depth24stencil8 cleared by ranges, both aspects copied and blitted flipped, ASTC blocks into a level, a resolve's rounding, a linear flipped blit into rgba16float; ShaderCompilerTests (the narrow types for storage). Board (board-test passed, 2026-11-23, loinnir-test 110 core cases passed, none skipped): every existing case that copies, clears or resolves now runs the kernels, and eight new ones are exact: a pass, a copy, a flipped blit and a second pass that keeps it in one submission (256 pixels), with an update, a fill and a copy of memory at odd offsets (96 bytes); 1, 4 and 8-byte texels with rows of 13 and slices of 5 into level 1 of two layers; a level of two layers onto another image and a block of a volume (384 texels); depth24stencil8 cleared by ranges and aspects, copied in, across and out, and blitted 2x flipped (64 texels each); ASTC 4x4 blocks at block offsets and into a level (20 blocks); a linear flipped blit into rgba16float (within 0.01), rgba8uint into rgba16uint (exact) and rgba8 into rgba8srgb (within 1); a clear of two levels of two layers (336 texels); a resolve of a region at offsets (the edge within 2).
- **One expectation changed.** A depth24 clear's value is rounded to nearest in double precision: 0.75 is 12582911 (Vulkan's rounding of 12582911.25), where the CPU's float arithmetic had made 12582912, which the depth-image case had taken as its reference, and 1.0 had overflowed to 2^24.

## Elsewhere, as built (2026-11-23): custom border colours under Venus, more than one viewport, sparse resources

The amendment's open item "Elsewhere", done for the core, Venus and the Vulkan layer; the Mali halves of viewports and sparse
resources wait on the clean-room answers (below).

- **Custom border colours under Venus.** The Venus client driver forwards renderer device extensions it carries on the wire:
  `VK_EXT_custom_border_color` (extension 288) is in the generated protocol (its sampler, feature and property structs in
  their chains), offered by `vkEnumerateDeviceExtensionProperties` where the renderer's device offers it and the capset's
  extension mask (`vk_extension_mask1`, offset 20) carries it, and forwarded by `vkCreateDevice`; any other is refused.
  `GPUCoreVulkan` already asked for it where offered, so `customBorderColor` is now the host's. No other extension the core
  wants is gated this way: viewports and sparse resources are core 1.0 features.
- **Viewports.** `Viewport` (a rectangle and a depth range), `setViewports(first:)` and `setScissors(first:)`, a pipeline's
  `viewportCount`, `DeviceFeatures.multiViewport` and `shaderOutputViewportIndex` (ViewportIndex from the vertex stage;
  `shaderViewportIndexLayer` is now Layer from it alone), and `DeviceLimits.maxViewports` with the viewport size, bounds and
  sub-pixel bits. Every viewport and scissor starts as the whole first attachment. The old `setViewport` and `setScissor`
  stay, as the first. The compiler's front end already lowered ViewportIndex from the vertex stage (`storesViewportIndex`);
  under Venus the SPIR-V reaches the host as written. The layer maps the pipeline's viewport count, static viewports with
  their depths, and `vkCmdSetViewport`/`vkCmdSetScissor` of any first and count; a pass of one viewport at depths 0 to 1
  still gets the old commands, so the Mali path sees no change.
- **Sparse resources.** A sparse buffer (`makeSparseBuffer`: `.device` memory with an address and no pages, `GPUMemory.sparse`)
  and a sparse image (`ImageDescriptor.sparse`), with `SparseFlags` `.binding`, `.residency` and `.aliased`; their
  requirements (`sparseRequirements`: the range in whole pages and the page), `sparseImageRequirements` (block shape and mip
  tail for each aspect) and `sparseImageFormats`; and `GPUQueue.bindSparse` of buffer ranges, opaque image ranges (metadata
  too) and blocks of an image, each to a range of ordinary memory or to nothing. A bind waits for `wait` and for everything
  submitted before it, signals `signal`, and the queue's later submissions run after it. The features are Vulkan's
  (`sparseBinding`, the residency ones for buffers, 2D, 3D, 2 to 16 samples and aliasing, `shaderResourceResidency`) and the
  properties `DeviceLimits.sparse` and `sparseAddressSpaceSize`. Shape rules are the core's (`SparseBindings.validate`); a bind
  off the pages or of memory the resource can't take is the backend's. The design is what a GPU with its own page tables
  does: a bind is a run of a memory's pages (a VMO's) mapped at the resource's addresses at page granularity, and a range bound
  to nothing is unmapped or a page of zeros. `GPUCoreVulkan` enables the features where the queue it uses has
  `VK_QUEUE_SPARSE_BINDING_BIT`, binds with `vkQueueBindSparse` on the timeline semaphore (waiting for the last value
  submitted, and the next submission waiting for the bind: Vulkan doesn't order binds with command buffers otherwise), and
  reports `shaderResourceResidency` false (the lowering doesn't carry OpImageSparse*). The Venus driver sends
  `vkQueueBindSparse` in order with the queue's submissions, without a reply; its semaphores are the renderer's. The layer maps
  sparse buffers and images, their requirements, `vkGetImageSparseMemoryRequirements(2)`,
  `vkGetPhysicalDeviceSparseImageFormatProperties(2)` and `vkQueueBindSparse`.
- **Mali.** Every flag stays false and `maxViewports` 1; `setViewports` and `setScissors` of the first take it (with the depth
  range), more is `.unsupported`, and sparse buffers, images and binds are `.unsupported` through the defaults and the rules.
- **Checks.** Host: GPUCoreTests (Viewports, SparseResources: the shapes `.invalid`, the lacks `.unsupported`, the fake's
  binds on the timeline), VulkanCoreDriverTests (ElsewhereTests: the viewport commands and counts, the features, limits,
  queue family bit, sparse requirements and binds), VenusTests (the custom border structs' bytes in a sampler chain and a
  features chain) and VenusDriverTests (which extensions are forwarded, by offer and mask). loinnir-test, boot-venus on
  brimstone (the host's NVIDIA GeForce RTX 5070 Ti), amd64 and arm64, reports `customBorderColor`, `multiViewport` with 16
  viewports, `shaderOutputViewportIndex`, every sparse feature (binding, residency of buffers, 2D, 3D, 2 to 16 samples,
  aliased), unbound pages reading zero and 1 TiB of sparse address space, and `shaderResourceResidency` false. The cases: the
  custom border exact; two viewports
  by ViewportIndex, each cut by its scissor, 256 pixels exact; a sparse buffer of three 64 KiB pages, two bound and filled, then one unbound (reading zero) and its memory
  bound at another page, which reads its word; a 256 x 256 rgba8 sparse image of 128 x 128 blocks, two
  bound and sampled, 64 pixels exact and the unbound blocks zero. 47 core cases passed, 3 skipped (depth resolves and alpha
  to one, as before).
- **A first sparse buffer case was wrong.** It also filled and read the memory behind the sparse buffer through the memory's
  own buffer, which aliases a sparse and a non-sparse resource: undefined in Vulkan without `sparseResidencyAliased`. On
  brimstone's NVIDIA it passed once and then read, twice, what the other buffer had written last. The case now reaches the
  memory only through the sparse buffer, and shows the binding by moving pages between two binds.
- **Left open.** The Mali halves (built since: "Mali viewports and sparse resources, as built"; more than one viewport stays off
  there); `shaderResourceResidency` waits on the lowering carrying the sparse image operations; the layer has
  no `vkGetDevice*MemoryRequirements` (1.3), the sparse one among them. A fence given to the Venus driver's
  `vkQueueBindSparse` is reached at the queue's next sync, which Vulkan doesn't order after the bind; the core orders binds by
  its timeline semaphore, which is exact.

## Mali viewports and sparse resources, as built (2026-11-23)

The Mali halves of "Elsewhere", built from the clean room's answers to V1 and S1 to S5 (valhall 02 §2.9.4, 05 §5.7 and §5.7.3,
06 §6.2 and §6.6.1, 14 §14.3.3 and §14.3.7, 16 §16.8.6, 12b §12b.5.5; panthor 04 §4.8.3).

- **Sparse resources: on, as the reference reports them** (16 §16.8.6). `sparseBinding`, `sparseResidencyBuffer`,
  `sparseResidencyImage2D` and `sparseResidencyImage3D` true; 2 to 16 samples, aliased and `shaderResourceResidency` false;
  `residencyStandard2DBlockShape` true, the multisample and 3D shapes, aligned mip size and non-resident strict false;
  `sparseAddressSpaceSize` the user VA range the driver reports.
- **The driver's sparse MAP** (panthor 04 §4.8.3). The `csf` capset's `bind` takes flag 16: the range is backed by the client's
  dummy, 2 MiB of the driver's made zeroed at the first such bind and freed with the context, mapped at VA x from offset x mod
  2 MiB (a mapping a 2 MiB window, never executable, buffer and offset 0). A bind of a buffer over it replaces it as any bind
  does; an unbind of the range (UNMAP) unmaps it. No protocol change beyond the flag.
- **The backend** (graphics/core/mali/lib/Sparse.swift). A sparse buffer or image is a range of the VM reserved at creation and
  never moved, aligned to 2 MiB from 2 MiB on (02 §2.9.4); with residency it is mapped to the dummy over its whole range at
  creation, bound only as a whole it stays unmapped until bound; destruction UNMAPs it. A bind of memory maps that range of the
  memory's pages (the transport's new `bind(offset:size:)`), a bind to nothing maps the dummy (`bindDummy`), never unmaps. The
  bind granularity is 4 KiB for buffers and binding-only images, 64 KiB (a tile) for residency images. `bindSparse` runs as a
  submission does in this backend, which runs one at a time: it waits for everything submitted before it (so for `wait`), makes
  the maps (synchronous, each under the driver's lock-region update), and raises the timeline to `signal`, also when a map was
  refused.
- **Residency images are in the 64 KiB layout** (05 §5.7, §5.7.3), the first images this backend lays out other than linearly:
  `ImageLayoutKind.interleaved64K` (clump ordering 8, texel interleave set, a render target's block format 8), tiles of
  256 x 256 elements of 1 byte down to 64 x 64 of 16, 16 x 16 blocks row-major inside a tile, the u-curve inside a block, every
  level whole tiles. A block is a tile (one slice deep for 3D, flagged non-standard), and the mip tail is the last level of each
  layer (the reference's rule; a one-level image is all tail). Eligible: 2D, cube or 3D, one sample, one aspect, an uncompressed
  texel of 1 to 16 bytes; sampled, storage, copies and colour target (rgba8, bgra8, bgra8srgb), not depth or stencil targets,
  not compressed formats (03 §3.8.5 leaves block views of a compressed 64 KiB image open). Binding-only images stay linear. Plane
  descriptors of a sparse image live in a region of their own (its range has no pages until bound).
- **Transfers reach the tiles.** The `copy`, `blitRaw` and `blit` kernels take a tile word for each side (0 linear; else the
  tile's width and height and the element's size as log2): the element (x, y) is addressed through its tile, block and u-curve
  place (05 §5.7.2), the units of a row never wider than an element. A sampled source is the texture unit's, whose descriptor
  names the layout.
- **The VM's addresses are used again.** The backend took addresses in order and never gave them back, and the driver keeps a
  VM's page tables (at most 1024 table pages, 2 GiB of addresses at 4 KiB); with the new cases loinnir-test's samplers case
  crossed 2 GiB (a bind of 6 MiB at 0x7edbd000 refused, `noMemory`). A region released (after the work that used it) now gives
  its range back, merged with its neighbours, and a new one takes the first range given back that fits before new addresses.
- **More than one viewport: off, as measured.** Built as the inference says: a vertex shader that writes ViewportIndex takes
  its transform from a table of the draw's viewports by the index (`IRBuiltin.viewportTable`, a FAU slot holding the address;
  entry `index & 15`, so no index reads past it; 14 §14.3.7), stores the index in the attributes' byte 2 (extended record), and
  the draw sets primitive flags bit 21 with the scissor register the array's address in [55:0] and length in [63:56], 256
  8-byte boxes in the scissor box's format, box k viewport k's rectangle cut by scissor k, the viewport registers the
  rectangle and depth range around every viewport's. On the board (Sky1 G720, arch 12.8.7) every draw with the array raised
  `CS FAULT DATA_INVALID_FAULT data 0x0000010c` on the tiler queue (CS 0; CS 1 then exception 0x0f), its info a different
  value each time (0x1e722730, 0x1eced730, 0x1f2b8f30, 0x1f883970, 0x1fe4e730, 0x20419730, 0x209e4728, ...: never 4 KiB
  aligned, so not the array's address), and drew nothing, not even the pass's clear; the forms tried: 8-byte boxes 64-byte
  aligned with length 2, 1, 0 and 255, 16-byte elements (a box and 8 zero bytes), and the array 4096-byte aligned. With bit 21
  set and an ordinary box in the register there was no fault, and the draw was cut exactly as without bit 21 (the scene's 64
  pixels of box 0 for both instances' primitives, none of box 1: the byte the shader wrote picked nothing). What was measured
  fits the register being read as a box whatever bit 21 says (an address in it is a box whose maximum is below its minimum),
  but that is our reading, not a finding. So the inference did not hold: `multiViewport` and `shaderOutputViewportIndex` stay
  false and `maxViewports` 1; the shader's indexed transform stays (a shader that writes ViewportIndex still compiles, cut by
  the first scissor), and the array is a probe (`DrawPipelineState.scissorProbe`, `MaliDevice.probeScissorMode`) for when the
  question comes back. The box format of the array was the board's measurement of an inference, not a spec fact. Question
  for the dirty room: 06 §6.2 and 14 §14.3.7 leave open what arch 12 needs, beyond primitive flags bit 21 and the scissor
  register, for the scissor array (another enable, a firmware or GPU_FEATURES gate, a different register, or no array at all on
  arch 12), and what CS fault DATA_INVALID_FAULT with exception data 0x10c names on the tiler queue.
- **The scissor array, probed again after the clean room's 13b answer** (06 §6.2, §6.6.1, §6.7.1; 14 §14.3.7; 12c §12c.4.2; a
  probe build of loinnir-test, `scissorProbeOn`, off in the tree). The index path was already what 13b requires: the vertex
  shader stores ViewportIndex in the position pass, under shader_output bit 1, into the attributes section (the slot's +4 index,
  byte 2), with the extended FIFO format. One scene for every form: 16 pixels wide, both viewports the whole target, instance 0
  red with ViewportIndex 0 and instance 1 green with ViewportIndex 1, scissor 0 the top-left 8 x 8 and scissor 1 columns 8 on,
  rows 4 to 15. Measured on the board (G720, three boots):
  - **(a) the address and length in the scissor register, bit 21 clear:** no fault. The pass's clear was written and neither
    draw drew a pixel, which is what a box whose maximum is below its minimum would do. So the 0x10c fault needs bit 21, and
    without it the register is read as a box but not rejected.
  - **(b) bit 21 with the array at 0x1_0000_0000** (bits 31:0 zero), length 1 and then 2, on a target 600 rows high, so that the
    register read as a box is (0, 0) to (1, 256) or (1, 512), inside the target. The array's boxes were clearly different from that.
    Every draw raised DATA_INVALID_FAULT 0x10c, drawing instance 0 alone and instance 1 alone, and the pass drew nothing (not even
    its clear). The draw was not cut to the register's own box, so bit 21 is not ignored.
  - **(c) bit 21 with the array** (8-byte boxes, the length counting boxes, in the pass's block), instance 0 alone and instance 1
    alone: the same fault. Bit 21 with an ordinary box whose maximum y is 599 on the 600-row target (a length byte of 2): the same
    fault. Bit 21 with an ordinary box whose maximum y is 7 (a length byte of 0): the same fault this time, with either instance
    alone. The first probe, whose scene put instance 1 in the right half outside the box, had drawn this form's box with no fault.
    With every draw faulting, a 16-byte stride was not tried again.
  - **Where the fault is:** its info word was, every time, the GPU address 0x130 bytes into the pass's tiling stream (0x180
    bytes; for example stream 0x9b2e00, info 0x9b2f30; stream 0x9f4e00, info 0x9f4f30). CS_STATUS_CMD_PTR was in the queue's
    ring (0x0000800000001000, 4096 bytes), 0x80 further on for each pass: the ring's call into the stream. So the info word
    places the instruction in our stream that faulted, at the same offset for every form. It is not the array, a descriptor or the
    tiler context (the context was at block + 0x40, the array at block + 0xdc0 or 0x1_0000_0000).
  - So with bit 21 set the GPU does something other than read the register as a box. With an array in every form tried, and
    with an ordinary box too in this scene, the run raises DATA_INVALID_FAULT 0x10c. None
    of the forms gave a box picked by the index. `multiViewport` stays false.
- **Checks.** Host: MaliTests (the sparse bind: the dummy repeated every 2 MiB, replaced by a buffer and back, refused shapes,
  freed with the context); GPUCoreMaliTests' MaliElsewhere (the reported features, block shapes and refusals; a sparse buffer
  mapped to the dummy at creation, bound, filled and copied through on the interpreter, rebound, freed and unmapped; a
  rgba32uint residency image's layout, requirements, mip tail, plane and texture descriptors, block binds and their refusals,
  and rows copied into and out of two bound tiles at the addresses 05 §5.7.2 gives); ValhallBackendTests (ViewportIndex picks
  its viewport's transform from the table, run on the interpreter). Board: loinnir-test's sparse buffer, sparse image (now of
  two levels, level 1 the tail) and a new sparse image drawn into (one block bound, cleared and drawn into by a pass, copied
  out) pass exactly; the two viewports cases skip on Mali (the new "viewports at the most": the device's viewports up to 16,
  each its own transform and scissor, and an index past the count). Board-test passed (2026-11-23): loinnir-test 113 core
  cases passed, 2 skipped (the two viewports cases); brimstone (`vx test --changed amd64 arm64`, boot-venus on its NVIDIA) passed
  with the viewports cases run there.

## The amendment, where it stands (2026-11-21, end of day; main f8d3c683; Mali present 2026-11-23)

Done:
1. **The core's types and rules:** the full feature set, source compatible.
2. **Under Venus:** GPUCoreVulkan implements all of it, and loinnir-test's core cases pass in boot-venus.
4. **The compiler's coverage:**
   - textures, derivatives and built-ins;
   - subgroups, all atomics, the narrow types, and measured transcendental precision;
   - storage images and texel buffers;
   - integer division.
5. **The Vulkan layer:** it maps the whole core, plus specialization constants, dynamic buffers, descriptor buffers, 1D images, swizzles, custom border colours, texel buffers and input attachments.
6. **Presentation:**
   - Vulkan swapchains into Radharc windows (`VK_VECTRA_window_surface`) and Loinnir's window ring, with no CPU copy, under Venus;
   - the CPU still waits for the timeline before presenting.

Partly done (step 3, Mali fixed function), each feature on only after the board judged it:
- **Pipeline state:** depth/stencil, rasterization, primitive restart, wide lines, eight colour targets, dynamic state, and blend shaders (every factor and op, constants, dual source, logic ops).
- **Resources:**
  - mips, layers, cubes, volumes and 1D, with views and swizzles;
  - five depth/stencil formats;
  - about forty formats, plus ASTC, ETC2 and BC;
  - the full sampler state;
  - copies, blits, fills and clears;
  - image import.
- **Queries and indirect work:** indexed and indirect draws and dispatch (with zero-count guards), timestamps, occlusion counts, storage images, and texel buffers.

- **GPU-cacheable memory and atomics** (2026-11-23): a client's memory, storage images and occlusion query sets are GPU-cacheable, and `shaderAtomic32`, `shaderImageAtomics`, and storage-image and texel-buffer atomics on `r32uint` and `r32sint` are on. The earlier failure was the test's, not the memory's: the probe and the atomics case gave as the root pointer the address of a word holding the target's address, so the shader wrote into that word. Panthor 04's K1.3 experiments on the board, with a sentinel written first through the write-combining mapping, showed plain stores and atomics in GPU-cacheable memory exact after the stream's clean, whether or not the CPU's lines over fresh pages were cleaned, the root was cacheable, or the driver flushed after. The stream tail already was K1.1's chain (a WAIT on every slot, flush id 0 loaded just before the clean). Found on the way and fixed in the kernel: a page committed after its VMO became write-combining or uncached was zeroed through the cached physmap (`dc zva`) and never cleaned (Zircon cleans it), K1.3's item 3, which hadn't shown. 64-bit atomics wait for the Mali backend to claim 64-bit integers.

Open, in order:
- **Mali present:** done (2026-11-23, "Mali present, as built"): direct frames in rows padded to 64 bytes as valhall 05 §5.5.5 has them, the stride told to the window; import on; Radharc sampling every Mali window's image in place; the timeline as the acquire counter. The whole loop passes on the board's desktop (compose-test desktop, with vulkan-present and Loinnir's window under the desktop's Radharc).
- **Multisampling and resolve,** alpha to coverage and one, sample shading, depth/stencil load by a pre-frame shader and `clearAttachments`: done (2026-11-23, "Mali multisampling, clears in a pass and kept depth, as built"); polygon modes stay off, as the hardware and the reference have none. Layers and depth and stencil resolves: done (2026-11-23, "Mali layers and depth resolves, as built"). Multiview: done (2026-11-23, "Mali multiview, as built").
- **Copies and blits as GPU passes:** done (2026-11-23, "Mali transfers on the GPU, as built"): every copy, blit, clear, fill, update and resolve is a compute kernel of the backend's, in order with the passes, with no CPU wait or pixel touched.
- **Elsewhere:** done for the core, Venus and the Vulkan layer (2026-11-23, "Elsewhere, as built"): custom border colours
  under Venus, more than one viewport, sparse resources. On Mali (2026-11-23, "Mali viewports and sparse resources, as built"):
  sparse resources done; more than one viewport off, the scissor array having faulted on the board in every form tried (a
  question back to the dirty room).
- **Step 7:** the CTS as a report. And the vkmark port, which now has a surface to present to.
