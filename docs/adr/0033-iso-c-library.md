# ADR-0033: An ISO C library for native programs, C++ support, and the native target

Status: accepted, 2026-10-05 (proposed 2026-10-04); amended 2026-10-06: the C library is llvm-libc and the C++ support libc++ and libc++abi, all toolchain runtimes, and the system supplies their platform layer (§1, §2). Further amended 2026-10-06: C++ on the native target (§2a), built in 6e2 and 6f2; the platform hooks (§1) and Fedora clang's configuration and link files (§3), after `swift-on-vectra`'s review of them. Decides 10 §12, question 1. Built in M6 step 6e2.

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
  - **Files.** `fopen` opens a `vx_fd` through `libvx` (09 §5), and a `FILE` is llvm-libc's buffer with the layer's read, write, seek and close. `remove` and `rename` are llvm-libc's functions over hooks `libvx` implements (`__llvm_libc_remove`, `__llvm_libc_rename`), over its file calls.
  - **The heap.** `malloc`, `calloc`, `realloc`, `free` and `aligned_alloc` are llvm-libc's functions, built for `vectraos` over three hooks that `libvx` implements: `__llvm_libc_heap_allocate(size, alignment)`, `__llvm_libc_heap_free` and `__llvm_libc_heap_usable_size`. The hooks sit over one process `vx_heap` (09 §4.3), made on first use and safe across threads once 6d's threads exist. They replace baremetal's allocator, a fixed free-list region that is neither thread-safe nor able to report usable sizes. The heap exists for imported code only. *Amended 2026-10-06:* this bullet first had `libvx` define `malloc` itself, in place of llvm-libc's. But llvm-libc's generated headers declare only the functions it builds, so `malloc` would then be undeclared and libc++ would not build. Leaving `remove` out the same way breaks libc++'s `<cstdio>` (LLVM issue #85335). With hooks, `libvx` still implements each one and the headers stay clause 7.
  - **Errors.** `errno` is a thread-local word, owned by `libvx` (which owns thread-local storage) and reached through `__llvm_libc_errno`, set where clause 7 says it is set, and used nowhere else. `libvx` keeps `vx_errstr`.
  - **The environment and time.** `getenv` is llvm-libc's, over a `__llvm_libc_getenv` hook that `libvx` implements by reading `/env` (6e1c). `timespec_get` and `time` read the wall clock and the monotonic clock through two hooks, `__llvm_libc_timespec_get_utc` and `__llvm_libc_timespec_get_active`.
  - **Exit.** `exit` runs the `atexit` handlers, flushes the streams and ends the task through `vx-rt`.
- **What it leaves out:**
  - **Locales.** `setlocale` accepts `"C"` and `""` (both UTF-8) and refuses anything else (ADR-0013).
  - **`<signal.h>`.** `raise` and `signal` cover `SIGABRT` only. Notes stay native (ADR-0010).
  - **`<threads.h>`** waits. Native threads are `libvx`'s (6d, 6e), and C11 threads over them come with §2a's second stage.
  - **`system`** reports that there is no command processor, as clause 7 allows.
  - **`tmpfile` and `tmpnam`** fail cleanly until native programs have a temporary directory, which 6e1c decides.
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
3. **Exceptions.** LLVM's libunwind, a toolchain runtime like the rest, and libc++abi rebuilt with exceptions on. The unwinder finds `.eh_frame_hdr` through the program's own headers while linking is static, and through the loader's list of loaded objects after 6f. An exception that would unwind through a `libvx` callback frame calls `std::terminate`: `libvx` is C and promises nothing to C++ unwinding. Code built with `-fno-exceptions` links as before, but libc++'s own throws (`std::length_error` from a string, for example) then reach libunwind, so Swift programs carry it too. Whether a no-exceptions variant is worth keeping for them is measured, not assumed. `dbg`'s unwinder (M14) and libunwind read the same CFI, and either can check the other. *Built 2026-10-08 (M6 step 6f2a1):* libunwind's VectraOS branch (LLVM patch 0021) asks libvx for an address's `.eh_frame_hdr` (`__llvm_libunwind_find_eh_frame_hdr`) and locks with ISO C's `mtx_t`; libvx and `crt1.o` are built without unwind tables, which is how a libvx frame ends an unwind; images are linked with `--eh-frame-hdr` (patch 0022). Measured: Swift programs grow only by that index (`swifta` by 126,020 bytes, 2.8%; `.eh_frame` was there already), so no no-exceptions variant is kept for them.
4. **The system's edges.** `std::filesystem` with a `vectraos` branch in libc++'s `src/filesystem` calling `libvx`'s file API (09 §5.5) directly, with no POSIX in between. Paths are UTF-8 (ADR-0013). Permissions map from VectraOS's model as 09 sets it, and what has no equivalent fails with `errc::operation_not_supported`. `std::random_device` reads `vx-rand`. `<chrono>`'s `system_clock` and `steady_clock` read `clock_read`, and `std::this_thread::sleep_for` sleeps to a deadline.
5. **Streams and text.** iostreams, with libc++'s localization on in the C locale only. The C library declares no `newlocale` or `uselocale`, which are POSIX names. Instead, libc++ gets a `vectraos` locale support header in the toolchain's patch series, with no-op locale operations and libc++'s own placeholder `locale_t`. It is built on the C-locale helpers libc++ already has in `__locale_dir/support/no_locale/` (character classes and number parsing), which Fuchsia's support header also uses. A named locale throws, as ADR-0013 has it. Wide characters come on when llvm-libc's wide functions cover what libc++'s build asks for, and the gap is listed until then.

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
  - `usr/lib/` with `vx-rt`'s start file `crt1.o`, `libvx.a`, llvm-libc's `libc.a` and `libm.a`, `libc++.a` and `libc++abi.a`, and compiler-rt's builtins (ADR-0008). The libraries keep LLVM's names, and patch 0003's driver now links them by those names.
- **Two compilers build for the target, and they agree.** The patched clang (llvm patches 0002 and 0003, in the Swift toolchain until ADR-0034's first gate, then in this tree) knows the triple: `clang --target=<arch>-unknown-vectraos hello.c` compiles and links with no further flags. This is how programs will be built on VectraOS. The pinned Fedora clang (ADR-0001) does not know the operating system. It can compile for the triple, but it cannot link: for an unknown OS it links by running the host's `gcc`, which brings the host's start files and C library. Neither `-fuse-ld=lld` nor a `--target` inside a configuration file changes that. *Amended 2026-10-06*, from `swift-on-vectra`'s `toolchain/sysroot-cfg/`, tested with Fedora clang 22.1.8 on both architectures. That is why the configuration file this section first described, one file that also linked, is replaced by the following.
- **Compiling with Fedora's clang: two configuration files at the sysroot's root,** `<arch>-unknown-vectraos.cfg` for C and `<arch>-unknown-vectraos-clang++.cfg` for C++. Two are needed because `clang++` reads only its own file, and `-std=c23` is an error on C++ input. They are read with `--config-system-dir=<sysroot>`, since clang looks for `<triple>.cfg` in its own configuration directories and never in the sysroot, and they name the sysroot through `<CFGDIR>`. Between them they give Fedora's clang what patches 0002 and 0003 give the patched one, for compiling:
  - `-D__vectraos__`, which patch 0002 predefines;
  - `--sysroot=<CFGDIR>` and nothing of the host's, so clang's own headers come first, then `usr/include` (and `usr/include/c++/v1` for C++), in the patched driver's order;
  - ~~`-std=c23`, or `-std=c++23` for C++~~ *Amended 2026-10-07* (M6 step 6e2b2, decided by the project lead): no language standard. The language is the program's choice: the system's own native programs are C23, and `./build` asks for it when it compiles them, but a third party's code built for the target is not made C23 by it. Without `-std` both compilers use their default, gnu17, which is what patch 0003 leaves the patched driver with; the probe check found the file's `-std=c23` the one difference between them;
  - `-fdebug-default-version=5`, so DWARF 5 is the version when `-g` asks for debugging, without turning it on for every compile as `-gdwarf-5` would;
  - `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer` (frame pointers in every function, leaf functions included, on both architectures), `-fasynchronous-unwind-tables` and `-fno-pic`;
  - `-fno-math-errno`, patch 0003's default;
  - for C++, `-fno-exceptions` until 6f2a gives libc++abi an exception runtime (§2a). Patch 0003 should default to the same until then, so the two agree.
- **Linking with Fedora's toolchain: `ld.lld` with three response files** beside the configuration files: `ld.lld --sysroot=<sysroot> @link-head.rsp <objects> @link-tail.rsp`, or `@link-tail-c++.rsp` for C++. A configuration file's options come before the inputs, so libraries named in one would come before the objects in a static link. The response files reproduce patch 0003's link line:
  - `link-head.rsp` has `-static`, the entry `_start`, `--build-id=sha1`, `-z max-page-size=0x1000`, `-z noexecstack`, `-z now`, and `vx-rt`'s start file, **`crt1.o`**, first. That is the name patch 0003 looks for in `usr/lib`; either side may change it if both do;
  - `link-tail.rsp` has `-lvx -lc -lm` in one group, since they call each other, then compiler-rt's builtins;
  - `link-tail-c++.rsp` has the same with `-lc++ -lc++abi` first (with libunwind from 6f2a, §2a).
- **No compiler patches are needed to compile and link with Fedora's toolchain this way.** An unknown OS name in a triple is valid to clang and lld, and generates the same ELF code as `none`. A driver toolchain class in clang itself, like the Swift work's llvm patch 0003, comes only when clang is built from source, under ADR-0001. The C library is different: it is built by the patched llvm-project (§1), and Fedora's toolchain only links it.
- **The two compilers are checked against each other** (ADR-0034's "must stay in agreement"). While both exist, `./build` compiles one probe program, in C and C++, with each. It compares three things, and refuses to build the sysroot when they differ:
  - the predefined macros (`-dM -E`), apart from a list, kept in the check, of macros that come from the compilers' LLVM versions rather than their configuration. Fedora's clang is LLVM 22 and the Swift toolchain's is 21. The version macros differ, and so do feature macros such as `__cpp_modules`, `__cpp_trivial_relocatability` and `__MEMORY_SCOPE_CLUSTR`, and on aarch64 `__ARM_PREFETCH_RANGE` and `__HAVE_FUNCTION_MULTI_VERSIONING`. The list empties when both are on one LLVM, at the first gate or by a pin;
  - the link line: the patched driver's (`-###`) against the response files';
  - the frame-pointer and DWARF attributes in the objects.

  A change to patch 0002 or 0003 then fails here until the configuration and response files follow.
- **Shared libraries:** static only, until the loader (6f). Whether the C library then becomes shared beside `libvx` is decided in 6f. *Decided 2026-10-08 (M6 step 6f1c):* the C library and the C++ libraries both become shared, `/lib/libc.so` (6f1c1) and libc++'s and libc++abi's (6f1c2). Their exported symbols join the release's binary interface beside `libvx`'s: a fix reaches every program with the release, and a changed behaviour is a release note (09 §4.8). `libc.so` is llvm-libc's archives linked whole by `./build`, compiled `-fPIC` with initial-exec TLS (`build_libc.sh`; LLVM patches 0018–0020: `-fPIC` in place of `-fpie`, and default visibility for the entrypoints, the `__cxa_*` exit functions, `__llvm_libc_thread_main` and the baremetal stdio hooks).
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
