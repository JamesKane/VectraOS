# D60. GPU debugging is Loinnir's validation and the trace (2026-10-16, proposed)

Vulkan relies on validation layers; our loader has none (todhchai M5f),
and principle 28 keeps third-party layers off the device. Metal's
debugging comes from owning the stack, and we own ours.
- **Loinnir validates itself** in a debug build: heap indices in range,
  root pointers inside live allocations, untracked resources that a
  tracked pass would have ordered (D58), use after `free`. A failure is a
  typed error naming the draw.
- **GPU time is traced** (principle 14): Loinnir writes GPU timestamps
  per pass and per submission into the program's trace ring (D50), so
  `vx trace` shows CPU and GPU on one timeline. There is no separate
  profiler.
