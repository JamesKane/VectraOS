# D57. VRAM and the process's memory budget (2026-10-16, proposed; open)

todhchai gives each process one budget covering CPU and GPU memory,
*because GPU buffers are VMOs* that the kernel accounts. That holds on
unified memory only. VRAM is not RAM the kernel's page allocator owns,
and a driver evicts it to system RAM under pressure.
- **Candidates:** (a) VRAM as VMOs backed by device memory (physical
  VMOs over the BAR or a GPU's local memory, accounted to the owner like
  any other), so a buffer object stays "a VMO" everywhere; the kernel then
  needs VMOs whose backing moves between VRAM and RAM. (b) The GPU system
  driver accounts VRAM and reports it into the process's budget; the
  kernel stays unaware of device memory, and there are two accountants.
- **Leaning (a),** for principle 1 and principle 8. It is a kernel design
  question, so it goes on `docs/kernel/roadmap.md` and is settled before
  V6 lifts buffer objects. Until then, buffer objects on discrete GPUs
  are system RAM (`.upload` and `.readback` only) and are reported, not
  budgeted.
