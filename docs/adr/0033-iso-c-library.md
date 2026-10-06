# ADR-0033: An ISO C library for native programs, C++ support, and the native target

Status: accepted, 2026-10-05 (proposed 2026-10-04); amended 2026-10-06: the C library is llvm-libc and the C++ support libc++ and libc++abi, all toolchain runtimes, and the system supplies their platform layer (§1, §2). Further amended 2026-10-06: C++ on the native target (§2a), built in 6e2 and 6f2. Decides 10 §12, question 1. Built in M6 step 6e2.

## Context

A native VectraOS program has no C library. First-party code is freestanding: it links `vx-rt` and `libvx` (09), with no global `malloc` and no `FILE` (09 §4.3), and that is deliberate. The only C library in the system is musl (D8, ADR-0007), and it is the POSIX personality: its back end turns Linux system-call numbers into IPC, and it brings file descriptors, `errno` as an interface, signals and `fork`.

Nothing in the roadmap filled the gap, because nothing needed it. Through M12, clang, Git and Python are POSIX programs on musl. But native development on VectraOS means clang building native programs, and imported code that asks for ISO C and nothing more has nowhere to go but musl:

- **Swift.** The full runtime, Concurrency and FoundationEssentials take 98 ISO C functions: math 55, conversion and formatting 10, strings 11, stdio 10, the heap 5, and a few more (`swift-on-vectra`, inventory.md §6, gap G16). They also need about ten C++ ABI functions.
- **Lua.** Built without `LUA_USE_POSIX`, it needs only ISO C (10 §4). Today it goes through musl (ADR-0015), so the scripts and the `wm` policy that run on it sit in the POSIX personality.
- **Any C or C++ library a developer brings** that was written to the standard rather than to Unix.

The clang side is missing too. Native programs build with `--target=<arch>-unknown-none-elf -ffreestanding -nostdlib` and flags that only `./build` knows. There is no triple, no sysroot and no driver configuration that a developer, or clang running on VectraOS, could use.

10 §4 framed the choice. The C23 standard library (clause 7) is part of the language D1 chose; POSIX is a separate standard on top of it, and Plan 9 drew the same line, with its own libc for native programs and ANSI/POSIX in APE. Against that, a C library over `libvx` is a second interface beside the first, and rule 13 is wary of those. 10 §12 left it as question 1, with the alternative of patching each ISO C import onto `libvx`.

## Decision

### 1. The ISO C library is llvm-libc, from the toolchain

**A hosted C23 library, clause 7 and nothing beyond it, reaching the system only through `libvx`.** It is not POSIX and has no POSIX in it.

*Amended 2026-10-06.* As first accepted, this section built an OS library, `libvxc`, from musl's vendored sources. That planned a second C library for a target whose toolchain already brings one: the Swift work builds llvm-libc for both `*-vectraos` triples from the pinned llvm-project. The C library is a toolchain runtime, as compiler-rt is (ADR-0008), so the system does not build one. What the system owes is the platform layer beneath it and the sysroot around it.

- **The library is llvm-libc**, built for each `<arch>-unknown-vectraos` triple from the llvm-project revision the pinned Swift toolchain uses (ADR-0034), with an entrypoint list and configuration (`LIBC_CONFIG_PATH`) that name clause 7 only. llvm-libc's math is correctly rounded by design, and its `strtod`, `printf` and `scanf` cores, strings, multibyte conversions, `qsort` and time formatting come with it. It is reviewed and pinned as part of the toolchain (ADR-0001, ADR-0034), not vendored into this tree.
- **Where it comes from, for now.** Fedora's clang (ADR-0001) ships no llvm-libc for these triples. Until ADR-0034's first gate puts the toolchain in this tree, the sysroot takes `libc.a` and its headers from `swift-on-vectra`'s build (`toolchain/build_libc.sh`), at the revision recorded in the sysroot. After the gate, `./build` builds it from the in-tree toolchain.
- **A VectraOS platform layer in llvm-libc.** The Swift work's patch 0004 maps `vectraos` to llvm-libc's baremetal layer, which takes a few hooks from the platform (`__llvm_libc_stdio_write` and `_read` with their cookies, `__llvm_libc_exit`, and `__llvm_libc_errno` in the external `errno` mode), all supplied by `libvx` and `vx-rt`. Baremetal has no files, and its streams need a platform mutex and a `File` back end that llvm-libc has only for Linux. So the layer grows into llvm-libc's own `vectraos` platform: a `File` back end over `vx_fd` and a mutex over futexes, in the toolchain's patch series beside the target's other patches and written to llvm-libc's conventions. Its only outward calls are `libvx`'s. It is upstreamable, and nothing in it is visible to this tree's first-party code.
- **What it contains:**
  - `<math.h>`, `<fenv.h>`, `<complex.h>`, `<string.h>`, `<ctype.h>`, `<inttypes.h>`, `<stdbit.h>`, `<stdckdint.h>`;
  - `<stdlib.h>`: conversions, `qsort`, `bsearch`, `rand`, the heap, `abort`, `exit`, `atexit`, `quick_exit` and `getenv`;
  - `<time.h>`: `time`, `clock`, `timespec_get`, `gmtime_r`, `strftime` and `mktime`;
  - `<wchar.h>` and `<uchar.h>`, in UTF-8 only (ADR-0013);
  - `<stdio.h>`, files included.
- **How each part reaches the system (the platform layer):**
  - **The streams.** `stdin`, `stdout` and `stderr` are buffers over `vx-rt`'s standard streams.
  - **Files.** `fopen` opens a `vx_fd` through `libvx` (09 §5), and a `FILE` is llvm-libc's buffer with the layer's read, write, seek and close. `remove` and `rename` are `libvx`'s, under those names.
  - **The heap.** `malloc`, `calloc`, `realloc`, `free` and `aligned_alloc` are `libvx`'s, over one process `vx_heap` (09 §4.3), made on first use and safe across threads once 6d's threads exist. The entrypoint list leaves out llvm-libc's own, a fixed free-list region that is neither thread-safe nor able to report usable sizes. The heap exists for imported code only.
  - **Errors.** `errno` is a thread-local word, owned by `libvx` (which owns thread-local storage) and reached through `__llvm_libc_errno`, set where clause 7 says it is set, and used nowhere else. `libvx` keeps `vx_errstr`.
  - **The environment and time.** `getenv` is `libvx`'s, under that name, reading `/env` (6e). `time` and `clock` read `clock_read`.
  - **Exit.** `exit` runs the `atexit` handlers, flushes the streams and ends the task through `vx-rt`.
- **What it leaves out:**
  - **Locales.** `setlocale` accepts `"C"` and `""` (both UTF-8) and refuses anything else (ADR-0013).
  - **`<signal.h>`.** `raise` and `signal` cover `SIGABRT` only. Notes stay native (ADR-0010).
  - **`<threads.h>`** waits. Native threads are `libvx`'s (6d, 6e), and C11 threads over them come with §2a's second stage.
  - **`system`** reports that there is no command processor, as clause 7 allows.
  - **`tmpfile` and `tmpnam`** fail cleanly until the system has a per-user temporary directory.
- **Headers.** The sysroot carries llvm-libc's generated headers, which declare only the configured entrypoints, so no POSIX name exists to call. The platform layer's `<features.h>` `#error`s on `_POSIX_C_SOURCE`, `_XOPEN_SOURCE`, `_GNU_SOURCE`, `_BSD_SOURCE` and `_DEFAULT_SOURCE`. A program that asks for POSIX is told so when it compiles, not when it links.

### 2. The C++ support library is libc++ and libc++abi, from the toolchain

*Amended 2026-10-06.* As first accepted, this section wrote about ten C++ ABI functions first-party in C23 (`vx-cxx`). The same reasoning as §1 applies: they are LLVM's runtimes, built by the toolchain against the C library above, in the same llvm-project. The Swift work builds them for both triples (`toolchain/build_cxx.sh`), and the system writes none of them.

- **libc++ and libc++abi**, static, with no exceptions, RTTI, threads, filesystem, localization, wide characters or terminal detection, and libc++abi in its baremetal mode with no unwinder. They supply every `operator new` and `operator delete` (over the heap, §1), `std::nothrow` and the new handler, `__cxa_guard_*`, `__cxa_pure_virtual`, and the compiled parts of libc++ that its headers call out of line (`std::string`'s members, `std::to_string`, `__libcpp_verbose_abort` and the rest the Swift runtime's compile sweep lists, `swift-on-vectra` R8).
- **What they take from elsewhere.** `__cxa_atexit` is the C library's, guarded by the platform layer's mutex (§1). `__dso_handle` is the linker's. `__cxa_guard_*` need futexes once there are threads (6d), through libc++'s threading over `libvx`.
- **Where they come from** is the C library's answer (§1): `swift-on-vectra`'s build until ADR-0034's first gate, the in-tree toolchain after it.
- **No C++ enters this tree** (04 §1): the runtimes are the toolchain's, as compiler-rt is.

**Out of scope:** exceptions and RTTI. Code that needs them waits for an amendment building libc++abi with them and importing libunwind (§2a). The Swift runtime builds without both.

### 2a. C++ on the native target

*Amended 2026-10-06 (proposed and accepted the same day).* §2 builds C++ support only as far as Swift's runtime needs it. The C++ the system will import needs more. 04 §1 admits C++ only as vendored code with no C alternative, and the two named imports, Mesa's C++ parts (M8) and llama.cpp (M11), are exactly that code. Today the only place they could build is the POSIX personality, which would put the GPU stack and `aid` on musl for no reason but the C++ runtime. The compiler is not the obstacle: clang++ is clang, and Fedora's already compiles C++ for any triple. What is missing is the rest of libc++ and the platform layer under it.

**Decision: `clang++ --target=<arch>-unknown-vectraos` is a supported way to build vendored C++ and developers' C++ programs.** The runtime libraries stay the toolchain's (§2), and each feature turned on gets a VectraOS back end over `libvx`, in the toolchain's patch series beside §1's layer. None of them goes through POSIX names, which would make a shim (rule 13). First-party code stays C23 or Swift (04 §1, ADR-0034).

What is turned on, in the order it lands:

1. **RTTI.** A rebuild of libc++ and libc++abi with RTTI on, and nothing from the system. `dynamic_cast` and `typeid` work. Code built with `-fno-rtti`, Swift's runtime among it, links against the same libraries.
2. **Threads.** libc++'s external threading API (`LIBCXX_HAS_EXTERNAL_THREAD_API`, a vendor header of thread, mutex, condition and once primitives) over `libvx`'s threads and futexes (6d, 6e). That gives `std::thread`, `std::mutex`, `std::condition_variable`, `std::call_once`, thread-safe `__cxa_guard_*` and `thread_local` over 6d1's TLS. **`<threads.h>`** comes with it, the same primitives under C11's names in the C library, because Mesa's C code needs C11 threads natively too.
3. **Exceptions.** LLVM's libunwind, a toolchain runtime like the rest, and libc++abi rebuilt with exceptions on. The unwinder finds `.eh_frame_hdr` through the program's own headers while linking is static, and through the loader's list of loaded objects after 6f. An exception that would unwind through a `libvx` callback frame calls `std::terminate`: `libvx` is C and promises nothing to C++ unwinding. Code built with `-fno-exceptions` links as before, but libc++'s own throws (`std::length_error` from a string, for example) then reach libunwind, so Swift programs carry it too. Whether a no-exceptions variant is worth keeping for them is measured, not assumed. `dbg`'s unwinder (M14) and libunwind read the same CFI, and either can check the other.
4. **The system's edges.** `std::filesystem` with a `vectraos` branch in libc++'s `src/filesystem` calling `libvx`'s file API (09 §5.5) directly, with no POSIX in between. Paths are UTF-8 (ADR-0013). Permissions map from VectraOS's model as 09 sets it, and what has no equivalent fails with `errc::operation_not_supported`. `std::random_device` reads `vx-rand`. `<chrono>`'s `system_clock` and `steady_clock` read `clock_read`, and `std::this_thread::sleep_for` sleeps to a deadline.
5. **Streams and text.** iostreams, with libc++'s localization on over llvm-libc's C locale (`newlocale` and `uselocale` for `"C"` only). A named locale throws, as ADR-0013 has it. Wide characters come on when llvm-libc's wide functions cover what libc++'s build asks for, and the gap is listed until then.

**Still out:** `std::locale` with named locales; `std::filesystem`'s hard links (none on VectraOS: symbolic links only, decided 2026-10-05 for `swift-on-vectra`'s R18); anything that needs `fork` or POSIX signals, which belongs to the POSIX personality.

**How it is tested:** each stage has a native C++ program built with only the target. Covered: virtual calls and `dynamic_cast`; four threads under a mutex and a condition variable; an exception thrown across frames and caught, and one uncaught that ends the task with a crash directory; a directory walked with `std::filesystem` on a vx-fs volume; and a `std::cout` round trip. The last test, before Mesa's import, is an unmodified llama.cpp built natively, which reaches every stage at once.

**Where it lands:** where each stage is cheapest. Stages 1, 2, 4 and 5 go in M6 step 6e2, which already configures and builds these libraries and the platform layer they stand on, after 6d's threads and 6e's `libvx` exist. Stage 3 goes in step 6f2, after the loader (6f). By then the unwinder's search for unwind tables is written once: a single call that `vx-rt` answers for a static program and the loader for a dynamic one. That matters because Mesa's Vulkan driver arrives at M8 as a shared library. llama.cpp's native build is 6f2's last test. Both steps come before M8 imports Mesa.

**Follow-on changes, made with it:** 04 §1's C++ row builds vendored C++ for the native target unless it needs POSIX. 14's table gains a "C++, native" row (`clang++ --target=<arch>-unknown-vectraos`, for imported libraries and developers' programs, not first-party code). 6e2 and 6f2 carry the stages. The sysroot's configuration file gains a C++ section (§3).

**Alternatives:**
- **Vendored C++ through the POSIX personality.** It works today, but Mesa and llama.cpp would live on musl only for their runtime, and `aid` and the GPU stack would be POSIX programs.
- **Patching each C++ import to `-fno-exceptions -fno-rtti` without threads.** That is a patch series per import against the habit of vendoring unchanged (ADR-0015), and llama.cpp's threads are not optional.
- **A first-party C++ runtime.** It is the `vx-cxx` reasoning that §2 withdrew, but larger.

### 3. The native target

- **The triple is `<arch>-unknown-vectraos`.** It is the name the Swift work already uses, beside the POSIX personality's `<arch>-vectra-unknown-musl`.
- **The sysroot is `out/<arch>/<mode>/vectraos/`,** laid out as the Swift work's clang driver (llvm patch 0003) searches it. It holds:
  - `usr/include/` with `<vx/…>` and llvm-libc's headers, and `usr/include/c++/v1/` with libc++'s;
  - `usr/lib/` with `vx-rt`'s start files, `libvx.a`, llvm-libc's `libc.a` and `libm.a`, `libc++.a` and `libc++abi.a`, and compiler-rt's builtins (ADR-0008). The libraries keep LLVM's names; `swift-on-vectra`'s provisional `-lvxc` and `-lvxcxx` follow them.
- **The driver configuration is a clang configuration file** in the sysroot, `<arch>-unknown-vectraos.cfg`, which clang reads for that target. It gives Fedora's clang everything patches 0002 and 0003 give the patched one:
  - `-D__vectraos__`, which patch 0002 predefines;
  - the sysroot, its `usr/include` and `usr/include/c++/v1`, and `-std=c23` (`-std=c++23` for `clang++`);
  - `-gdwarf-5`, `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer` (frame pointers in every function, leaf functions included, on both architectures) and `-fasynchronous-unwind-tables`;
  - `vx-rt`'s start file first, then the libraries in patch 0003's order: `-lc++ -lc++abi` for C++ (with libunwind from 6f2, §2a), then `-lvx -lc -lm` in one group, since they call each other, then compiler-rt's builtins;
  - `-static`, `--build-id=sha1`, `-z max-page-size=0x1000`, `-z noexecstack` and `-z now`.

  So `clang --target=x86_64-unknown-vectraos hello.c` builds a native program on the host with the pinned Fedora clang (ADR-0001), and on VectraOS with no further flags.
- **No compiler patches are needed to compile and link.** An unknown OS name in a triple is valid to clang and lld, and generates the same ELF code as `none`. A driver toolchain class in clang itself, like the Swift work's llvm patch 0003, comes only when clang is built from source, under ADR-0001. The C library is different: it is built by the patched llvm-project (§1), and Fedora's clang only links it.
- **The two compilers are checked against each other** (ADR-0034's "must stay in agreement"). While both exist, `./build` compiles one probe program, C and C++, with each. It compares the predefined macros (`-dM -E`), the link lines (`-###`) and the frame-pointer and DWARF attributes in the objects, and refuses to build the sysroot when they differ. A change to patch 0002 or 0003 then fails here until the `.cfg` follows.
- **Shared libraries:** static only, until the loader (6f). Whether the C library then becomes shared beside `libvx` is decided in 6f.
- **Shipping:** the sysroot ships in the `devel` set (06 §3.2) from M12, and is built by `./build` for every image before then.

### 4. The containment rule

**First-party code never includes the hosted headers and never links the C library.** That covers `cmd/`, `servers/`, `drivers/`, `lib/` and `kernel/`. Host tools under `host/` use the host's libc as before. Their programs keep `-ffreestanding` and `-nostdlib` against `vx-rt` and `libvx`, and `./build check` refuses a first-party source that includes a clause-7 header outside C23's freestanding set (`<stddef.h>`, `<stdint.h>`, `<stdarg.h>`, `<stdbit.h>`, `<limits.h>` and the rest). Imported code links the C library by naming it in its `port.ndb`. A developer's own program uses the native target and may use either.

### Why this is not a portability layer (rule 13)

It wraps no other operating system and imitates none. Everything in it is defined by the language standard D1 chose, and a compiler that implements C23 is expected to supply it. It comes with the toolchain, as the language's library does on most systems, and reaches VectraOS only through `libvx`. POSIX stays where ADR-0007 put it, in musl. The second way to open a file that 10 §4 worried about exists only for imported code, by the rule above.

## Alternatives

- **Patch each ISO C import onto `libvx`** (10 §12's alternative). This costs a patch series per import against the habit of vendoring unchanged (ADR-0015). It cannot work for Swift, whose runtime and Foundation call clause 7 from hundreds of places.
- **A floor without files**, as the Swift notes first proposed: math, conversions, strings and the two output streams only. It is smaller, but Lua's `io` library and most C a developer brings would still need musl. Files are clause 7 too, and over `vx_fd` they cost one small back end.
- **Native programs on musl whole.** That brings `errno` as an interface, file-descriptor integers and `__syscall` beneath native code: the POSIX personality under another name.
- **Writing the library first-party.** Correctly rounded math and `strtod` are exactly where independent code goes wrong.
- **musl's syscall-free sources with a first-party back end (`libvxc`)**, this ADR's decision as first accepted. It is a second C library for the target beside the one the toolchain builds, and two to keep in step with the Swift runtime's needs. Withdrawn 2026-10-06.
- **llvm-libc's baremetal layer as it is**, the Swift work's patch 0004. It suits Swift, which takes no files from C, but has no `fopen` and no streams beyond the hooks. It is the starting point the `vectraos` layer grows from.

## Consequences

- 10 §12, question 1, is decided. 09's "freestanding, with no libc" still holds for first-party code, and imported native code gains a C library.
- Lua can move out of the POSIX personality, built without `LUA_USE_POSIX`, with a native library giving back `io.popen` and temporary files over `libvx`. That is a later step, not part of this one.
- There is no `vx-cxx`. 04 §1's "no C++ in the tree" holds without writing the C++ ABI in C.
- The Swift port's S13 becomes this ADR's step. Its symbol inventory is one of the step's tests.
- There is no `ports/vxc`. musl stays the POSIX personality's alone (ADR-0007), and upgrading it touches nothing native.
- The C library's version moves with the toolchain's pin (ADR-0034), and its platform layer is reviewed with the toolchain's patch series. Until the first gate, the sysroot records which `swift-on-vectra` build it took the library from.
- 04 §3.3 lists three user-space targets: first-party freestanding, native through `<arch>-unknown-vectraos`, and POSIX through `<arch>-vectra-unknown-musl`.
