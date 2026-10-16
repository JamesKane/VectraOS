# D49. The floor is the one user runtime (2026-10-15, decided)

croi's user runtime (`user/lib/runtime`: `_start`, the processargs read,
a heap over VMOs, stdout into the debuglog, about 500 lines of C) and
todhchai's floor (`system/sys/floor`) do the same job. The floor also
does what tier 1 needs: thread blocks and ELF TLS, its threads,
`environ`, initializers and exit handlers.
- **The floor stays.** It is lifted onto V1's calls, and userboot, m2
  and the Swift suites move onto it. `user/lib/runtime` is deleted.
  spawn → main is measured on the floor.
- **What isn't a runtime stays a helper.** MMIO and port I/O stay inline
  in `croi/runtime.h`. The suites' RELRO check and TCG check use the
  floor's `td_image_header` and `td_cpuid`. lib/rt keeps the stack
  guard and 128-bit division, which it shares with the kernel. (Amended
  2026-10-16: lib/rt kept `mem*` too until the libc landed; user programs
  now take `mem*` and `strlen` from the libc, and lib/rt's are the
  kernel's and the loader's.)
- **Assembly and C only where Swift can't reach:** the entry, the
  thread pointer, `__ehdr_start`, port I/O, and the C ABI's globals
  that a dlopen'd object must share (`runtime.c`).
- **Rejected:** both runtimes, split by role (two mechanisms for one
  job), and croi's runtime grown to tier 1's needs in C.
