# D125. A boot is a production boot unless `croi.test=` names what it tests: all, the groups boot, kernel, programs and suites, or a suite by name; `croi.selftest=off` goes (2026-10-24, the owner's choice the same day; amends D35)

On the Orange Pi 6 Plus (V6) the first boots ran the whole self-test
chain, because the kernel ran it unless the command line said
`croi.selftest=off`. One test written for QEMU's machine (the driver
test, which named QEMU virt's physical addresses) then stopped every
boot behind it. The owner asked for the reverse: boot as in production,
and turn tests and debugging on when they're wanted.

## Before

Two options did overlapping jobs:

- `croi.selftest=off` turned off the kernel's self-tests (the early
  checks in kernel_main, the in-kernel tests, the test programs' modes,
  the Swift suites), which ran by default.
- `croi.test=1` turned on the test call's hooks and the debugging
  syscalls (D35), as `croi.debug_syscalls=on` does.

CMake's `CROI_CMDLINE` defaulted to `croi.test=1`, and 75 profiles added
`croi.selftest=off`: test hooks without self-tests.

## The decision

- **No option, no tests.** Without `croi.test=` the kernel runs no
  self-test, starts no test program, and refuses the test hooks and the
  debugging syscalls: a production boot. `croi.selftest=off` is gone.
- **`croi.test=` lists what to run**, comma-separated:
  - `all`: everything, in the old order;
  - `boot`: kernel_main's checks before the scheduler (PMM, heap, VM,
    the framebuffer pattern, stacks, SMP, IPIs, time, xstate, KASLR);
  - `kernel`: the in-kernel self-tests (scheduler through SMMUv2);
  - `programs`: the C and Swift test programs' modes;
  - `suites`: every Swift suite, or one suite by its name (`drivers`,
    `interrupts`, `vmo`, ...).
- **Any `croi.test=` also turns on the test hooks and the debugging
  syscalls**, as `croi.test=1` did. `croi.debug_syscalls=on` turns them on
  alone, for boots that test from user space.
- **One image, gated at run time.** The test programs stay in the kernel
  image and bootfs, so a board boots the same image for production and
  for tests. Leaving them out of a production build can follow if the
  size budgets want it.
- **Tests take a machine's facts from the machine.** The drivers suite
  (the driver test moved to a Swift suite, D21) finds RAM in the boot
  data, and gets PCI's ECAM, a page the kernel drives and whether the
  framebuffer pattern was drawn in its environment.

## In the tree

- CMake: `CROI_CMDLINE` (empty by default) begins every ESP's command
  line; `CROI_TESTS` (`all` by default) is the self-test ESPs'
  `croi.test=`. The profiles that said `croi.selftest=off` say
  `croi.debug_syscalls=on`. A build tree still caching `croi.test=1` is
  reset.
- `vx bench`'s `lean` profile and `vx bench --zircon` drop `croi.test=`:
  they time a production boot.
- The Orange Pi 6 Plus boots `croi.test=boot,kernel,drivers` (and so on)
  while bring-up needs it, and nothing once it doesn't.
