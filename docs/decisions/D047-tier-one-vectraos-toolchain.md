# D47. Tier 1: the *-vectraos toolchain comes with V2 (2026-10-15, decided; amended 2026-10-16)

rc and FDIO are tier 1 (full Swift), and so is most of what follows them.
Tier 1 needs todhchai's toolchain: LLVM and the Swift compiler and driver
built from the pinned Swift 6.4.0 sources with a patch series that teaches
them the `*-unknown-vectraos` triple, and a sysroot (libc, pthreads,
libc++, libc++abi, libunwind, the Swift runtime and FoundationEssentials).
- **Lift it as todhchai has it** (owner's call: the precedent makes it
  straightforward): `tools/toolchain` (fetch, patch, build scripts and the
  series, about 3 GB of sources under `.cache/`, outside the tree), and
  the sysroot's build under the native CMake build. `vx` drives it, as
  `td` does today (D11).
- **The triple is VectraOS's, and so is its name** (owner's call,
  2026-10-16): `*-unknown-vectraos`, `__vectraos__`, `os(VectraOS)`, the
  platform module `VectraOSLibc` over the libc's `SwiftVectraOSLibc`, the
  `VECTRAOS` SDK and the `vectraos` executor, as swift-on-vectra spelled
  them. todhchai is an internal name (the userland's origin, its `td_`
  prefixes), not a stand-alone OS. The series was renamed as it was
  lifted, so nothing was built under the old name.
- **Tier 0 is unchanged:** the kernel, the floor and every tier 0 library
  build with the stock 6.4.0 from swiftly, as now.
- **Upstream LLVM and Swift are host toolchain under D4,** producing our
  artifact formats; nothing third-party runs on the device beyond what the
  Swift runtime already is.
- **Rejected:** porting rc to tier 0 (it would be ported again when tier 1
  arrives for the apps).
