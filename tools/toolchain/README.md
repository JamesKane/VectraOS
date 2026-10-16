# tools/toolchain: the *-vectraos toolchain

Tier 1's toolchain (D47; todhchai's M6, its triple renamed `*-vectraos`):
LLVM (clang and lld) and the Swift compiler and driver, built from the
pinned Swift 6.4.0 sources with a patch series that teaches them the
`*-unknown-vectraos` triple, VectraOS's tier 1 on croi, for x86_64,
aarch64 and riscv64. The full Swift runtime, its C and C++ floors and
FoundationEssentials are built with it in M6c to M6g: libc++, libc++abi
and libunwind by each arch's CMake tree (`cmake/cxx.cmake`, M6d).

The series and these scripts are adapted from
[swift-on-vectra](../../../../lang/swift-on-vectra/toolchain/README.md)'s,
which ported full Swift 6.4.0 to NeoVectra the same way, under the same
triple name; each patch says where it came from and what differs (croi's
link line, riscv64, our libc).
Upstream LLVM and Swift are host toolchain under D4 (D47).

## Building

Everything big lives outside the tree, in `.cache/toolchain/`: the
sources (`work/`, about 3 GB), the builds and the installed toolchain
(`out/bin`: clang, ld.lld, swiftc), shared by worktrees. The stdlib and
Foundation are built in each tree's own `build/{stdlib,foundation}-<arch>`,
configured for its sysroot.

```sh
# The sources at pins.txt's commits; from a local mirror of clones at the
# same pins (swift-on-vectra's), or from GitHub without the variable.
VECTRAOS_TOOLCHAIN_MIRROR=../../lang/swift-on-vectra/toolchain/work tools/toolchain/fetch-upstream.sh
tools/toolchain/apply-patches.sh        # patches/<component>/ onto each tree
tools/toolchain/build_stage_t1.sh       # LLVM: clang, lld (X86, AArch64, RISCV)
tools/toolchain/build_stage_t1_swift.sh # the Swift compiler (host Swift 6.3.1 builds it)
tools/toolchain/build_stage_t1_driver.sh # swift-driver, installed as swiftc
tools/toolchain/smoke-clang.sh && tools/toolchain/smoke-swiftc.sh
tools/toolchain/build_builtins.sh      # compiler-rt's builtins, all three triples
```

compiler-rt's builtins for the three triples come next
(`build_builtins.sh`, a minute: freestanding, into the toolchain's
resource directory). Then the arch's tree (`vx build amd64`;
`cmake/Tier1.cmake`, amd64 and arm64 so far: riscv64's LLVM has no
Swift calling conventions yet) builds tier 1's sysroot
(`build/<arch>/sysroot`) and runtime
libraries with this toolchain: libc++,
libc++abi and libunwind (`cmake/cxx.cmake`, M6d), and the Swift runtime
and standard library (`build_stdlib.sh`, M6e: two minutes from scratch,
incremental after; it configures again when the script changes), and
FoundationEssentials after them (`build_foundation.sh`, M6g, the same
way).

`LINK_JOBS` caps parallel links (each takes several GB; the default is a
sixth of the machine's RAM in GB). A build loads the whole machine for
hours: warn the other sessions first. After a change to one LLVM
patch, `ninja -C .cache/toolchain/build-llvm install` relinks in minutes.

To change a patch: commit in `.cache/toolchain/work/<tree>/` (amend, or
reset to `vectraos-base` and re-apply), run `refresh-patches.sh`, review
the series' diff and commit it.

## The series

| Patch | What |
|---|---|
| llvm 0001 | `Triple::VectraOS`, `isOSVectraOS()`, parsed from `vectraos` |
| llvm 0002 | clang defines `__vectraos__` (`VectraOSTargetInfo`) on x86_64, aarch64 and riscv64 |
| llvm 0003 | clang's VectraOS toolchain and linker: static `ET_EXEC` at `--image-base=0x1000000`, entered at `_start`, separate loadable segments, a 256 KiB stack, `--build-id=sha1`, 4 KiB pages, no executable stack, `-z now`, as `cmake/croi.cmake` links tier 0; `crt1.o` first, default libraries `-lsys -lc -lm` (grouped) and `-lclang_rt.builtins`, `-lc++ -lc++abi` for C++; one sysroot; DWARF 5; frame pointers everywhere; C++ exceptions off (0004 turns them on) |
| llvm 0004 | C++ exceptions on by default for `vectraos`, a C++ link adds `-lunwind` after libc++abi, and every link but `-r` has `--eh-frame-hdr` (libunwind finds unwind tables through `dl_iterate_phdr`'s `PT_GNU_EH_FRAME`): M6d's C++ floor |
| swift 0001 | `os(VectraOS)`, the platform name `vectraos`, the C++ driver's GenericUnix toolchain for it |
| swift 0002 | The C++ driver links vectraos images statically by default |
| swift 0003 | The `VECTRAOS` stdlib SDK: `configure_sdk_unix(VectraOS)` for the three machines, each one's sysroot from `SWIFT_VECTRAOS_<arch>_SYSROOT_PATH`; the `pthreads` threading package (over our pthreads); static linking, `static-executable-args.lnk` (`-static -lswiftCore -lc++ -lc++abi -lunwind`, `--gc-sections`); the `SWIFT_MODULE_DEPENDS_VECTRAOS` and `SWIFT_SOURCES_DEPENDS_VECTRAOS` dispatch |
| swift 0004 | `VectraOSLibc`, the platform module: an overlay with `errno` over the clang module `SwiftVectraOSLibc`, whose module map our libc ships with its headers (no ClangImporter mapping, unlike swift-on-vectra's); no `tgmath` yet |
| swift 0005 | The runtime's platform sites: byte order from the compiler, `malloc_usable_size` (the floor's), random bytes from `getentropy` (croi's CPRNG), `CommandLine.arguments` from the floor's `td_argv`, `Pthreads.cpp`'s stack bounds unknown (it called `pthread_attr_getstack` regardless) |
| swift 0006 | No Float80 on VectraOS (decided 2026-10-11): a program means the same on the three machines; `CLongDouble` undefined; long double stays C's |
| swift 0007 | Synchronization on VectraOS: its atomics (Sys's `Lock` is over them); `Mutex` unavailable until M6f puts it over croi's futexes |
| swift 0008 | Synchronization's `Mutex` on VectraOS: Linux's futex lock, its shims waiting and waking through the floor's `td_futex_wait` and `td_futex_wake` (`td_floor.h`, in the sysroot) |
| swift 0009 | Concurrency with VectraOS's executors (`SWIFT_CONCURRENCY_GLOBAL_EXECUTOR=vectraos`, M6f; adapted from swift-on-vectra's): a default executor of a thread per CPU and a main executor on the main thread, over `VectraOSGlobalExecutor.cpp` (priority buckets, deadlines on the monotonic clock, threads sleeping on a croi port); `Clock.cpp`'s POSIX clocks; `_Concurrency` imported implicitly for `*-vectraos` (the frontend: rebuild it after this one) |
| swift 0010 | The global executor fires port waiters (M6f): its threads sleep on the process's executor port (`td_executor_port`), and a packet keyed by a `td_port_waiter` is handed to its `fire`, so an async wait on a handle resumes its task with no thread blocked (Sys's `Handle.wait(until:)`) |
| swift 0011 | `VectraOSLibc` wraps `open` (variadic in C: over `<fcntl.h>`'s `__td_open`) and gives the `S_IF*` mode constants as `mode_t`, as Glibc's overlay does (M6g: files through fdio) |
| swift 0012 | Observation over our pthreads (Glibc's pthread mutex path), for FoundationEssentials' ProgressManager (M6g) |
| swift 0013 | `VectraOSLibc`: `POSIXErrorCode` (`POSIXError.swift`'s Linux numbers, which our libc has) and the rest of the `S_IF` types and mode bits |
| swift 0014 | One timer sleeper in the global executor (croi's suggestion): a deadline wakes one idle thread, not all; a deadline set from a pool thread wakes none |
| swift-foundation 0001 | FoundationEssentials for `*-vectraos` (M6g): essentials only (swift-on-vectra's switch, no ICU), `VectraOSLibc` branches, VectraOS joining WASI where both lack something (users, xattrs, statvfs, sendfile, fchown), no mmap or setting times yet, UUIDs from `getentropy`, a UUID parsed and `Date.description` computed without `sscanf`, `gmtime_r` or `strftime` |
| swift-driver 0001 | swift-driver learns the triple, links statically by default, DWARF 5 |
