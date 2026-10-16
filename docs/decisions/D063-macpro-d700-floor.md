# D63. The Mac Pro's D700s meet D62's floor; descriptor heaps are required; the fan fails safe (2026-10-16, proposed)

D62 left open whether the 2013 Mac Pro's FirePro, the oldest GPU on either
list, meets the floor, which decides whether descriptor heaps are
required. The test unit is the dual D700 model (Tahiti, GCN 1.0), and the
owner notes that it overheats unless power and fan management are close to
flawless. Its facts, sources and open checks are in
`docs/boards/macpro6-1/`.
- **The D700 meets the floor** as D62 states it (hardware capabilities):
  GPU pointers through `addr64` buffer instructions or synthesized
  descriptors (GCN 1.0 has no FLAT instructions), descriptors that
  shaders always load from memory (heaps are the hardware's own model),
  timelines and dynamic rendering in software, and few layouts to track
  (no DCC). Today's drivers agree in part: RADV is conformant to Vulkan
  1.3 on GFX6 and has buffer device address; whether it exposes
  descriptor buffers or heaps there doesn't bear on our drivers.
- **So Loinnir requires descriptor heaps.** No GPU on either list lacks
  bindless descriptors in memory.
- **The Mac Pro is D56's hardest case,** and its test machine: a discrete
  GPU without resizable BAR (`.upload` through staging), and two GPUs of
  which only one drives the displays.
- **Thermal safety comes first, as rules:**
  - the Apple SMC stays on its automatic fan curve, and VectraOS writes
    only the fan's minimum (`F0Mn`), so a dead power service or kernel
    leaves the machine louder, not hotter; manual mode needs its own
    decision, with a watchdog that hands the fan back;
  - one power service holds the combined budget for the CPU and both
    GPUs, which share one heatsink and one fan;
  - no D700 runs above its boot clocks until the soak budgets pass;
  - a GPU whose temperature can't be read counts as at its limit;
  - the D700s' `HARDWAREDC` capability and 300/150 MHz DC state are
    ignored, as for any desktop GPU (Linux's fix of 2026-09-23), and each
    GPU's VBIOS image is matched by exact bus before anything looser,
    refusing rather than guessing between the two.
- **Budgets, with their checks, on the desktop track's first Mac Pro
  milestone:** `thermal.gpu_peak_c` and `thermal.cpu_peak_c` over a
  30-minute full-load soak, with limits set from the Linux baseline run
  (`docs/boards/macpro6-1/`, "On the machine") before our driver raises a
  clock; and `thermal.fan_floor_reverts`, a check that killing the power
  service leaves the SMC in control (exact: any failure fails).
- **First steps on the machine:** the readings listed in the board file,
  then a read-only SMC driver (sensors and fan speeds), then the soak
  harness. Writing `F0Mn` comes after both.
