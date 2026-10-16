# D56. GPU memory is named by intent; Loinnir places it per device (2026-10-16, proposed)

Metal served unified memory (Apple silicon) and discrete VRAM (Intel
Macs) for a decade through one API, because its storage modes name who
touches memory, not where it lives. Loinnir's `alloc(.upload / .device /
.readback)` already has that shape. It keeps it, and it defines each kind
on each memory model:

| Kind | Unified memory | Discrete, with resizable BAR | Discrete, without it |
|---|---|---|---|
| `.upload` (CPU writes, GPU reads) | one VMO: a pointer and a GPU address | device-local, host-visible VRAM | system-RAM staging that Loinnir copies to VRAM |
| `.device` (only the GPU) | the same VMO, with no CPU pointer | VRAM | VRAM |
| `.readback` (GPU writes, CPU reads) | the same VMO | host-cached system RAM | host-cached system RAM |

- **A program never branches on the memory model.** Loinnir picks the
  heap from the device's memory properties, and records any staging copy
  itself; its hazard tracking (D58) treats that copy like any other write.
- **`.device` never has a CPU pointer, even on unified memory,** so a
  program written on a board doesn't break on a desktop GPU.
- **Loinnir suballocates** from a few large allocations per device heap.
  v0's one `vkAllocateMemory` per `alloc` meets drivers' allocation-count
  limits, and costs a blob per call under Venus.
- **Several GPUs in one machine:** a window renders on the GPU Loinnir
  picks (the compositor's, unless the program asks), and buffer
  negotiation (principle 8) gains two constraints, which device's memory
  and whether a peer GPU can read it. When neither GPU can read the
  other's memory, negotiation falls back to system RAM and a copy rather
  than failing.
- **Tests:** Loinnir's draw tests run on Venus over a discrete host GPU
  and over its integrated GPU where the host has one, and a test forces
  the no-BAR path on a device that has BAR.
