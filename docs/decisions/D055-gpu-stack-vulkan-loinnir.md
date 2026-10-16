# D55. The GPU stack lifted from todhchai: Vulkan underneath, Loinnir on top (2026-10-16, proposed)

V6 lifts todhchai's `graphics` (provenance.md): vkgen and the Vulkan
headers and dispatch from `vk.xml`, our loader, the Venus client driver
over virtio-gpu, buffer objects and their negotiation, and Loinnir, the
SDK's GPU library after Aaltonen's "No Graphics API" (todhchai's
`sdk.md` §5). This entry and D56-D62 settle what changes on the way in,
weighed against the Metal and Vulkan ergonomics comparison the owner
supplied: Metal's lead comes from defaults (one-call setup, storage by
intent, hazard tracking, argument buffers, headers shared by the CPU and
the GPU), and Vulkan has been converging on them (dynamic rendering,
descriptor buffers and heaps).
- **Loinnir is the one GPU library** in the tree. Raw Vulkan stays
  available for ports (engines, DXVK-class layers, Zink, wgpu); those
  are tier 1 programs, not part of the tree.
- **Kept as todhchai has it:** one-call `open`, dynamic rendering only,
  one pipeline layout (the bindless heap and a root pointer per draw),
  timeline values for completion, SPIR-V compiled on the host (D4).
- **The targets have both memory models** (D56): unified memory on the
  boards (Adreno, Mali, the Ky X1's GPU) and dedicated VRAM on developers'
  desktops (AMD, Intel, NVIDIA, sometimes more than one GPU in a machine).
  Nothing in Loinnir may assume either.
- **Open: is all of Vulkan the drivers' interface?** Venus forces Vulkan
  under QEMU. For native drivers the alternative is a narrow interface
  shaped like Loinnir (GPU pointers, heaps, stage-only barriers,
  timelines), with full Vulkan as a layer over it for ports. That is the
  MoltenVK arrangement turned around, and the comparison's warning about
  translation layers applies to the ports, not to Loinnir. V8 needs only
  Adreno compute, so this waits until the first native driver is
  designed; nothing lifted in V6 assumes either answer.
