# ADR-0033: An ISO C library for native programs, a C++ support subset, and the native target

Status: accepted, 2026-10-05 (proposed 2026-10-04). Decides 10 §12, question 1. Built in M6 step 6e2.

## Context

A native VectraOS program has no C library. First-party code is freestanding: it links `vx-rt` and `libvx` (09), with no global `malloc` and no `FILE` (09 §4.3), and that is deliberate. The only C library in the system is musl (D8, ADR-0007), and it is the POSIX personality: its back end turns Linux system-call numbers into IPC, and it brings file descriptors, `errno` as an interface, signals and `fork`.

Nothing in the roadmap filled the gap, because nothing needed it. Through M12, clang, Git and Python are POSIX programs on musl. But native development on VectraOS means clang building native programs, and imported code that asks for ISO C and nothing more has nowhere to go but musl:

- **Swift.** The full runtime, Concurrency and FoundationEssentials take 98 ISO C functions: math 55, conversion and formatting 10, strings 11, stdio 10, the heap 5, and a few more (`swift-on-vectra`, inventory.md §6, gap G16). They also need about ten C++ ABI functions.
- **Lua.** Built without `LUA_USE_POSIX`, it needs only ISO C (10 §4). Today it goes through musl (ADR-0015), so the scripts and the `wm` policy that run on it sit in the POSIX personality.
- **Any C or C++ library a developer brings** that was written to the standard rather than to Unix.

The clang side is missing too. Native programs build with `--target=<arch>-unknown-none-elf -ffreestanding -nostdlib` and flags that only `./build` knows. There is no triple, no sysroot and no driver configuration that a developer, or clang running on VectraOS, could use.

10 §4 framed the choice. The C23 standard library (clause 7) is part of the language D1 chose; POSIX is a separate standard on top of it, and Plan 9 drew the same line, with its own libc for native programs and ANSI/POSIX in APE. Against that, a C library over `libvx` is a second interface beside the first, and rule 13 is wary of those. 10 §12 left it as question 1, with the alternative of patching each ISO C import onto `libvx`.

## Decision

### 1. `libvxc`, the ISO C library

**A hosted C23 library, clause 7 and nothing beyond it, implemented on `libvx`.** It is not POSIX and has no POSIX in it.

- **Built from musl's vendored sources** (ADR-0007), unchanged: a subset of `third_party/musl`, listed in `ports/vxc/port.ndb` as the musl port lists its own. musl's math, `strto*`, `printf` and `scanf` cores, strings, multibyte conversions, `qsort` and time formatting are the hard and reviewed part. A small first-party back end, `ports/vxc/vx`, written under the house rules, supplies everything that touches the system. The library's only outward calls are `libvx`'s. No file of musl's that reaches `__syscall` is in the subset, and the port's build checks that.
- **What it contains:**
  - `<math.h>`, `<fenv.h>`, `<complex.h>`, `<string.h>`, `<ctype.h>`, `<inttypes.h>`, `<stdbit.h>`, `<stdckdint.h>`;
  - `<stdlib.h>`: conversions, `qsort`, `bsearch`, `rand`, the heap, `abort`, `exit`, `atexit`, `quick_exit` and `getenv`;
  - `<time.h>`: `time`, `clock`, `timespec_get`, `gmtime_r`, `strftime` and `mktime`;
  - `<wchar.h>` and `<uchar.h>`, in UTF-8 only (ADR-0013);
  - `<stdio.h>`, files included.
- **How each part reaches the system:**
  - **The streams.** `stdin`, `stdout` and `stderr` are buffers over `vx-rt`'s standard streams.
  - **Files.** `fopen` opens a `vx_fd` through `libvx` (09 §5), and a `FILE` is musl's buffer with the back end's read, write, seek and close. `remove` and `rename` are `libvx` calls.
  - **The heap.** `malloc`, `calloc`, `realloc`, `free` and `aligned_alloc` use one process `vx_heap` (09 §4.3), made on first use and safe across threads once 6d's threads exist. It exists for imported code only.
  - **Errors.** `errno` is a thread-local word, set where clause 7 says it is set, and used nowhere else. `libvx` keeps `vx_errstr`.
  - **The environment and time.** `getenv` reads `libvx`'s environment (`/env`, 6e). `time` and `clock` read `clock_read`.
  - **Exit.** `exit` runs the `atexit` handlers, flushes the streams and ends the task through `vx-rt`.
- **What it leaves out:**
  - **Locales.** `setlocale` accepts `"C"` and `""` (both UTF-8) and refuses anything else (ADR-0013).
  - **`<signal.h>`.** `raise` and `signal` cover `SIGABRT` only. Notes stay native (ADR-0010).
  - **`<threads.h>`** waits. Native threads are `libvx`'s (6d, 6e), and C11 threads over them can come later under an amendment.
  - **`system`** reports that there is no command processor, as clause 7 allows.
  - **`tmpfile` and `tmpnam`** fail cleanly until the system has a per-user temporary directory.
- **Headers.** The sysroot carries musl's headers, plus a `<features.h>` of our own placed ahead of musl's. It `#error`s on `_POSIX_C_SOURCE`, `_XOPEN_SOURCE`, `_GNU_SOURCE`, `_BSD_SOURCE` and `_DEFAULT_SOURCE`, then includes musl's. The native target compiles with `-std=c23`, so `__STRICT_ANSI__` hides every POSIX declaration. A program that asks for POSIX is told so when it compiles, not when it links.

### 2. `vx-cxx`, the C++ support subset

**About ten C++ ABI functions, first-party and written in C23.** The C++ runtime ABI is plain symbols, so these can be defined in C and no C++ enters the tree (04 §1). The set:

- `__cxa_guard_acquire`, `__cxa_guard_release` and `__cxa_guard_abort`, over an atomic word and a futex;
- `__cxa_atexit`, `__cxa_finalize` and `__dso_handle`;
- `__cxa_pure_virtual` and `__cxa_deleted_virtual`, which abort with a message;
- every form of `operator new` and `operator delete` (sized, aligned, nothrow), over `libvxc`'s heap. A failed `new` aborts, because there are no exceptions.

**Out of scope:** exceptions and RTTI. Code that needs them waits for an ADR importing libc++abi and libunwind. The Swift runtime builds without both.

### 3. The native target

- **The triple is `<arch>-unknown-vectraos`.** It is the name the Swift work already uses, beside the POSIX personality's `<arch>-vectra-unknown-musl`.
- **The sysroot is `out/<arch>/<mode>/vectraos/`.** It holds:
  - `include/` with `<vx/…>`, `libvxc`'s headers and our `<features.h>`;
  - `lib/` with `vx-rt`'s start files, `libvx.a`, `libvxc.a`, `libvxcxx.a` and compiler-rt's builtins (ADR-0008).
- **The driver configuration is a clang configuration file** in the sysroot, `<arch>-unknown-vectraos.cfg`, which clang reads for that target. It holds the sysroot, `-std=c23`, the start files, the libraries in their order, `-static`, `-z now` and 4 KiB pages. So `clang --target=x86_64-unknown-vectraos hello.c` builds a native program on the host with the pinned Fedora clang (ADR-0001), and on VectraOS with no further flags.
- **No compiler patches are needed for this.** An unknown OS name in a triple is valid to clang and lld, and generates the same ELF code as `none`. A driver toolchain class in clang itself, like the Swift work's patch 0004, comes only when clang is built from source (M12), under ADR-0001.
- **Shared libraries:** static only, until the loader (6f). Whether `libvxc` then becomes shared beside `libvx` is decided in 6f.
- **Shipping:** the sysroot ships in the `devel` set (06 §3.2) from M12, and is built by `./build` for every image before then.

### 4. The containment rule

**First-party code never includes the hosted headers and never links `libvxc`.** That covers `cmd/`, `servers/`, `drivers/`, `lib/` and `kernel/`. Host tools under `host/` use the host's libc as before. Their programs keep `-ffreestanding` and `-nostdlib` against `vx-rt` and `libvx`, and `./build check` refuses a first-party source that includes a clause-7 header outside C23's freestanding set (`<stddef.h>`, `<stdint.h>`, `<stdarg.h>`, `<stdbit.h>`, `<limits.h>` and the rest). Imported code links `libvxc` by naming it in its `port.ndb`. A developer's own program uses the native target and may use either.

### Why this is not a portability layer (rule 13)

It wraps no other operating system and imitates none. Everything in it is defined by the language standard D1 chose, and a compiler that implements C23 is expected to supply it. POSIX stays where ADR-0007 put it, in musl. The second way to open a file that 10 §4 worried about exists only for imported code, by the rule above.

## Alternatives

- **Patch each ISO C import onto `libvx`** (10 §12's alternative). This costs a patch series per import against the habit of vendoring unchanged (ADR-0015). It cannot work for Swift, whose runtime and Foundation call clause 7 from hundreds of places.
- **A floor without files**, as the Swift notes first proposed: math, conversions, strings and the two output streams only. It is smaller, but Lua's `io` library and most C a developer brings would still need musl. Files are clause 7 too, and over `vx_fd` they cost one small back end.
- **Native programs on musl whole.** That brings `errno` as an interface, file-descriptor integers and `__syscall` beneath native code: the POSIX personality under another name.
- **Writing the library first-party.** Correctly rounded math and `strtod` are exactly where independent code goes wrong. musl's are already vendored and reviewed.

## Consequences

- 10 §12, question 1, is decided. 09's "freestanding, with no libc" still holds for first-party code, and imported native code gains a C library.
- Lua can move out of the POSIX personality, built without `LUA_USE_POSIX`, with a native library giving back `io.popen` and temporary files over `libvx`. That is a later step, not part of this one.
- The Swift port's S13 becomes this ADR's step. Its symbol inventory is one of the step's tests.
- `ports/vxc/port.ndb` is captured from musl's sources alongside `ports/musl/port.ndb`. Upgrading musl rebuilds both, and both are checked.
- 04 §3.3 lists three user-space targets: first-party freestanding, native through `<arch>-unknown-vectraos`, and POSIX through `<arch>-vectra-unknown-musl`.
