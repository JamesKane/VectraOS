# Release notes

What a release changes that programs built for an earlier one may see, newest first (ADR-0004 item 8, ADR-0048 item 4). `./build release` refuses a release whose behaviour suite differs from its level's frozen one (`abi/levels/<n>.behaviour`) unless a note here names the suite's new hash, as a line `behaviour-suite: HASH`, beside what changed. A Swift ABI change is a note here too.

## vx-abi level 1 (2026-10-08, M6's close)

The first frozen level: `libvx` v0, as ADR-0004 describes it, becomes level 1.

- `libvx.so.1` is the library's soname; a program names it, and a program built for level 1 runs on every later release.
- Its exports are `abi/levels/1.symbols`: the calls of `<vx.h>` and its headers (`<vx/sys.h>`, `mem.h`, `err.h`, `random.h`, `str.h`, `fmt.h`, `utf.h`, `ndb.h`, `time.h`, `thread.h`, `proc.h`, `loop.h`, `file.h`), `vx_start`, and the hooks the shared C, C++ and Swift libraries bind to. Each build holds `libvx.so` to it.
- Its behaviour is the suite's (`vxapitest`, `libvxtest`), frozen as `abi/levels/1.behaviour`.
- The Swift libraries' ABI baselines are `abi/swift/<triple>`; from this release on, a break fails `./build release`.
- `VX_ABI_LEVEL` is 1, and `vx_abi_level()` says 1: Swift's `#available(VectraOS 1, *)` holds. A declaration added later sits inside `#if VX_TARGET_ABI >= 2` (C) or carries `@available(VectraOS 2, *)` (Swift).
- What stays private: the syscall numbers and the spawn message's format (ADR-0004 item 7), the ring layout, and nsd's protocol, whose text form becomes binary records when a consumer first needs it (ADR-0009, `libvx.so` reading both until the release that drops the text).
- The C library keeps its soname, `libc.so`: its interface is ISO C's, llvm-libc's.
