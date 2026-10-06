# 14 — Writing programs for VectraOS: languages and style

_Draft, 2026-10-05, for developers who start writing programs once M6 lands. **Non-binding until M6 is done:** it is written against M6's plan (milestones.md), and is resynced against the code M6 produces before anyone is pointed at it. The house rules for the OS tree are 04 §1.1; this document is advice for programs outside it, which build "with whatever flags and style their authors choose" (04 §1.1). Where a point is a system rule rather than advice, it says which rule._

## 1. What exists when M6 lands

| Ready | Not yet |
|---|---|
| `libvx` v0 (09 §5.1–5.12), static, and shared once the loader exists (6f) | Windows, input, audio and the GPU for apps: `vxui` and the engine tier (03 §6) arrive with M7 |
| The native target `<arch>-unknown-vectraos`: `libvx`, the toolchain's ISO C library (llvm-libc), and libc++ and libc++abi (ADR-0033, 6e2) | Packages, catalogues and `vxpkg` (06 §3.3, §14): M7 onwards. Until then a program is copied into a namespace by hand |
| Swift 6.4 in both forms, on `libvx` through the `VX` bindings (ADR-0034, 6e3) | The swarm, the LAN and the public network as sources (06 §6.1): M10 to M12 |
| Threads with intents, static TLS, futexes, robust futexes (6d) | Time zones: UTC only until M7 vendors tzdata |
| 01 §6.6's shared structures: sealed VMOs, leases, lent leases, `<vx/shared.h>` (6e) | The portable code form (13): design notes only |
| `dbg` for C and Swift, crash directories, the profiler (05, 6e3) | |
| The POSIX personality, for ports (01 §9) | |

So the first programs are command-line tools, file servers, background services and engines' non-graphical parts. The same habits (§3) carry over unchanged when `vxui` arrives.

## 2. Choosing a language

**Write against `libvx`, in C23 or Swift. Use the POSIX personality only to port existing Unix software.**

| Language | Use it for | Reaches the system through | Build with |
|---|---|---|---|
| **C23** | The default. Tools, servers, engines, anything with arena-shaped lifetimes or tight budgets | `<vx.h>` (`libvx`), `<vx/sys.h>` for kernel objects | `clang --target=<arch>-unknown-vectraos` |
| **Swift, full** | Programs with object graphs that have shared owners, protocol-shaped plug-points, enums with payloads, or a lot of `async` work: editors, document tools, agent services, anything that will grow a UI at M7 | `import VX` (never `CVX`), FoundationEssentials | `swiftc` with the `vectraos` SDK |
| **Swift, Embedded** | Small tools and services that want Swift's types without its runtime: tens of KB, no reflection | `import VX`, the Embedded standard library | The same, in Embedded mode |
| **Lua** | Scripts, `wm` layout policies (D12, 03 §5.2), glue over files | Files: `/proc`, `/env`, a service's `ctl` | The system's Lua |
| **rc** | Shell scripts, namespace set-up | Files and programs | — |
| **Odin, Zig, Rust and others** | Whatever their authors like | `libvx`'s C ABI, through the native target's sysroot | Their own compilers, linking against the sysroot |
| **C or C++ through POSIX** | Porting an existing Unix program or library: a compiler, an interpreter, a game whose source assumes Unix | musl and the POSIX personality (01 §9) | `--target=<arch>-vectra-unknown-musl` |

How to choose:

- **New native program, simple ownership:** C23.
- **New native program whose data is a graph, or whose logic is a set of cooperating tasks:** full Swift. ADR-0034's four reasons (OO or protocol structure, functional patterns, namespacing, ARC) are a good test for applications too.
- **A library written to ISO C** (a codec, a parser, a maths library): build it unchanged for the native target. The toolchain's C library, llvm-libc, supplies clause 7, with files and without POSIX.
- **A library or program written to POSIX:** port it to the POSIX personality, or replace its platform layer with `libvx` calls if it is small. A program that needs `fork`, signals or sockets is a POSIX program.
- **Don't** put a portability layer (an SDL-like wrapper, an event-loop library, a cross-platform runtime) between your program and `libvx` to keep it "portable". `libvx` is small and has one way to do each thing (rule 13, 09 §1). Put your program's own platform layer at the top, where it names your program's needs, not the OS's.

## 3. Habits for every language

These follow from the design rules (00 §2), and they hold whatever the language.

1. **One loop, one wait** (rule 4). Everything your program waits for (file replies, timers, child exits, notes, ring completions, later windows and frames) arrives on one `vx_loop` as one event record (09 §4.7). Don't start a thread to block on something; register it with the loop. In Swift, `@MainActor` code runs on that loop.
2. **Deadlines, not sleeps** (rule 5). Every wait takes an absolute deadline on the one clock and a leeway. Never sleep in a loop, never set a timer resolution. A periodic job is a deadline with leeway, and the system coalesces it with other work.
3. **Intents, not priorities** (rule 6). Give each thread an intent: `interactive-frame`, `interactive`, `throughput`, `background` or `realtime(period, budget)`. A job system that needs whole cores reserves them, and is told yes or no. There is no affinity mask to set.
4. **Files for control, shared memory for bulk** (rule 2). A small request is a file read or a `ctl` write. Large data crosses as a VMO or on a ring.
5. **Share structures; don't serialise them** (01 §6.6). To hand another process a tree, a table or a scene, build it in a VMO with offset links, seal it if the receiver must trust it, and send the handle. Lend it for one call when it should come back. Don't encode it as JSON or any other text to send to a process on the same machine.
6. **Ask for what you need, and only that** (rule 3). Your manifest's `needs=` line is your program's whole view of the system (06 §3.3), and the user sees it before installing. Broad grants, such as the whole home, are never given at install; the user gives them later from the grant settings, if at all (ADR-0029). Design so your program works without them.
7. **No main thread** (rule 9). Every `libvx` call works from any thread. Don't design around a "UI thread" that must make certain calls.
8. **Batch** (rule 11). Submit many requests in one `vx_io_submit`, read many events per wait, close many handles at once.
9. **Errors are a status and a string** (09 §4.2). Check `vx_status` where it matters and show `vx_errstr()`: a file server's message, such as `/n/tower: hungup`, reaches you unchanged. Asynchronous failures (a connection lost, a device gone) arrive as events.
10. **Text is UTF-8, without locales** (ADR-0013). Cut strings at rune boundaries. Format numbers and dates one way. Don't look for a locale to parse with.
11. **State is data** (rule 10). Settings are ndb records, not code (D14). A program with state worth seeing can serve it as a file tree, with `.help` and `.schema`, as every system service does (09 §5.11). `ls` and `cat` then explain your program, to people, scripts and agents alike.
12. **Exit with a reason** (ADR-0010). Success is the empty exit string. Failure says what failed, in words, or a number in decimal when the language only has numbers (`exit(3)` is `3`).

## 4. C23

The house subset (04 §1.1) is written for the OS tree, but most of it pays off in programs too.

- **Memory:** arenas first, pools for objects freed one at a time, a `vx_heap` only for lifetimes that are truly unrelated (09 §4.3). `libvx` never allocates behind your back; keep the same rule in your own libraries, so the caller always passes the allocator.
- **Scratch:** use `vx_scratch` for temporary work, never a `malloc` and `free` pair inside a loop.
- **Slices, not NUL-terminated strings:** `vx_str` and `vx_bytes` throughout. C strings exist only to call code that needs them.
- **Nil objects and sticky errors:** check once, at the point where it matters, not after every call.
- **Zero is a valid value:** design structs so that all zeroes is empty and ready. `-ftrivial-auto-var-init=zero` then makes a forgotten initialiser harmless.
- **Checked arithmetic** (`<stdckdint.h>`) on every size, offset or count that came from outside your process.
- **Hosted headers:** `<stdio.h>` and the rest of the C library are there for code you import. Your own code is simpler against `libvx`: `vx_fd` and your own buffering, not `FILE`. Defining `_POSIX_C_SOURCE` or `_GNU_SOURCE` is refused when you compile (ADR-0033).
- **Flags worth keeping:** `-std=c23 -Wall -Wextra -Werror`, frame pointers in every function (`-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer`), and DWARF 5 (`-g`), so `dbg` and the profiler see every frame (D15).
- **Format:** any consistent style is fine. The house format (K&R, two-space indents) has a `.clang-format` you can copy.

## 5. Swift

- **Import `VX`, never `CVX`.** `VX` gives namespaced types (`VX.File`, `VX.Loop`, `VX.Process`), handles as noncopyable types closed when they go out of scope, and typed errors (`throws(VX.Error)`) carrying the server's message.
- **Swift 6 language mode with complete strict concurrency.** Data races are compile errors. Keep it that way, rather than marking types `@unchecked Sendable`.
- **Ownership:** classes and ARC where an object really has several owners; structs, enums and noncopyable types where it does not. ARC costs an atomic operation per retain, so keep reference counting out of per-element inner loops.
- **Concurrency:** `async`/`await`, task groups and actors run on a pool of native threads with the `throughput` intent, and `@MainActor` runs on the program's `vx_loop`. Sleep with `Task.sleep(until:)` and a tolerance, which become a deadline and a leeway. There is no Dispatch.
- **Foundation:** FoundationEssentials is there (`Data`, `Date`, `URL`, JSON coding, `FileManager`). FoundationInternationalization and ICU are not, and neither is the old CoreFoundation-based Foundation. `FileManager` sees a namespace: no POSIX permissions beyond what 9Px carries, symbolic links but no hard links.
- **Errors:** typed `throws` at module boundaries, so callers can switch on cases. Untyped `throws` is fine inside a module.
- **Budgets:** code on a frame or audio path must not allocate. Use noncopyable types, preallocated buffers and `Span`, and check with Swift's performance annotations where the toolchain supports them.
- **Embedded Swift** for small programs: existentials and untyped `throws` work since 6.4. `-no-allocations` gives code that cannot touch the heap.
- **Exporting to C:** `@c` (with `@implementation` for an existing header) when other languages call your library. Keep the C interface in plain C types.
- **Packages:** use SwiftPM for your own program if you like. The system ships no registry and trusts none (D13); your dependencies are your own to audit, and they ship inside your package (06 §3.4).

## 6. Lua and rc

- **Lua** is for scripts and policies, against files. A setting is ndb data, not a Lua table (D14). A Lua script that needs to do something the files don't offer is a sign that a service is missing a file, not that the script needs a binding.
- **rc** is Plan 9's shell, compatible with 9front's (M6 6a6). Scripts read `$status` as an exit string, and namespaces are built with `bind` and `mount` in the script itself.

## 7. Ports through the POSIX personality

- **When:** existing software written to POSIX, whose rewrite would cost more than it gives. Compilers, interpreters, version control and many games' engines.
- **What it costs:** every call goes through musl's back end, which turns Linux system calls into `libvx` and 9Px. File descriptors, `errno` and signals exist inside the program and nowhere else.
- **What it still gets:** the same namespace confinement, intents, `dbg`, crash directories and packaging as a native program. A port is confined by `/lib/ns/posix` or its own template; it never sees `/home` unless the user grants it (ADR-0029).
- **Moving a port to native** is usually a platform layer replaced, not a rewrite: the program's `#ifdef __linux__` file becomes a `libvx` file.

## 8. Building, debugging and shipping

- **Build:** `clang --target=<arch>-unknown-vectraos prog.c` with the sysroot's configuration file, or `swiftc` with the `vectraos` SDK. Declare `VX_TARGET_ABI`, and repeat it in the manifest (`requires=vx-abi>=N`), so using a newer call is a compile error rather than a surprise on an older release (09 §4.8).
- **Static or shared:** static until the loader (6f), then `libvx` (and `vxui`, from M7) as the release's shared libraries. A fix in `libvx` then reaches your program with the release. Changed behaviour is announced in the release notes, never silent.
- **Debug:** `dbg` reads `/proc` over 9Px, so remote debugging needs nothing extra. A crash leaves a crash directory with the backtrace, registers and the exit string. Keep frame pointers and DWARF 5.
- **Profile:** `vx_prof_begin` and `vx_prof_end` zones around the work you care about (05 §9).
- **Ship (M7 onwards):** a package is a tree per architecture, plus an `arch=any` tree for assets, a manifest with `needs=`, signed with your publisher key (06 §3.3). There are no install scripts: anything your program must set up, it does when it first runs, in its own data tree. `vxpkg` builds, signs and publishes from Linux, macOS or Windows. Selling your program is up to you (06 §1).

## 9. Habits from elsewhere to leave behind

| Habit | Here |
|---|---|
| A main or UI thread that owns the system's calls | No main thread; any thread calls anything (rule 9) |
| `sleep(1)` in a loop, polling a file | A deadline with leeway; `vx_watch` on the file (rules 4, 5) |
| Thread priorities, `nice`, affinity masks | Intents, or reserved cores (rule 6) |
| A local socket speaking JSON to a helper process | Files for control; a sealed VMO for the data (01 §6.6) |
| A plugin as a shared library in your process, trusted blindly | A plugin is a process in its own namespace, given its input read-only and lent memory for one call (01 §6.6, §4.5) |
| `dlopen` to see whether a feature exists | ABI levels at compile time; optional services are files that may be absent (09 §4.8) |
| `getenv("HOME")` and wandering the disk | Your package's data tree is your `$HOME`; anything else is a grant (06 §3.3, ADR-0029) |
| A global `malloc` in every function | Arenas and scratch, with a heap only where lifetimes are unrelated |
| Locale-dependent parsing and formatting | UTF-8, one format |
| An install script | First-run set-up inside the program |

## 10. To resync when M6 is done

- Names in §4 and §5 against `libvx` v0's headers and the `VX` module as built.
- §1's table against what M6 actually delivered, including 6f's shared libraries.
- §2's build commands against the sysroot's configuration file and the Swift SDK.
- A worked example per language: a small file server in C23, the same in Swift, and a Lua script that drives it.
- Whether this document becomes a manual page in section 7 (12 §3), so `man 7 apps` serves it on the system.
