# 14 — Writing programs for VectraOS: languages and style

_Resynced 2026-10-08 against what M6 built (it was drafted 2026-10-05 against M6's plan). For developers writing programs outside the OS tree, which build "with whatever flags and style their authors choose" (04 §1.1); the house rules for the tree itself are 04 §1.1. Advice, except where a point names the system rule it follows. The reference on the system is the manual: native(7) for the target and its sysroot, section 2 for each call; this document is the why and the how-to-choose._

## 1. What exists now

| Ready (M6, 2026-10-08) | Not yet |
|---|---|
| `libvx` level 1, frozen (ADR-0004): `<vx.h>` and its headers (`sys`, `mem`, `err`, `random`, `str`, `fmt`, `utf`, `ndb`, `time`, `thread`, `proc`, `loop`, `file`, `ns`), as the shared library `libvx.so.1`; every later release runs a program built for it | Windows, input and drawing: `vxui` arrives with M7 (03 §6, 21); audio with M13; the GPU with M8 |
| The native target `<arch>-unknown-vectraos`: llvm-libc's ISO C library and libc++ and libc++abi (RTTI, threads, `std::filesystem`, iostreams in the C locale, exceptions), all shared (ADR-0033) | `<vx/srv.h>` (serving files): a later level, so a native program cannot yet serve a file tree through `libvx` |
| Swift 6.4, full, with its runtime and FoundationEssentials shared in `/lib` (ADR-0034, ADR-0048), `@available(VectraOS 1, *)` | Swift's `VX` module over `libvx`; Embedded Swift on VectraOS (spike S14); `dbg` reading Swift's mangled names (tabled until the Swift toolchain is vendored) |
| Threads with intents, TLS, futexes and robust futexes; `vx_lock` and rendezvous | Packages, catalogues and `vxpkg` (06 §3.3, §14): M7 onwards. Until then a program is copied into a namespace by hand |
| 01 §6.6's shared structures: sealed VMOs, leases, lent leases (`<vx/shared.h>` in the tree) | The swarm, the LAN and the public network as sources (06 §6.1): M10 to M12 |
| `dbg` for C and C++, crash directories, the profiler's zones in first-party code (05) | Time zones: UTC only until M7 vendors tzdata |
| The POSIX personality, for ports (01 §9) | The portable code form (13): design notes only |

So the first native programs are command-line tools, background services and the non-graphical parts of engines. The habits of §3 carry over unchanged when `vxui` arrives.

## 2. Choosing a language

**Write against `libvx`, in C23 or Swift. Use the POSIX personality only to port existing Unix software.**

| Language | Use it for | Reaches the system through | Build with |
|---|---|---|---|
| **C23** | The default. Tools, services, engines, anything with arena-shaped lifetimes or tight budgets | `<vx.h>` (`libvx`), `<vx/sys.h>` for kernel objects | `clang --target=<arch>-unknown-vectraos` (§8) |
| **Swift, full** | Programs with object graphs that have shared owners, protocol-shaped plug-points, enums with payloads, or a lot of `async` work: editors, document tools, agent services, anything that will grow a UI at M7 | The standard library, FoundationEssentials, and the C library through `VectraOSLibc`; `VX` over `libvx` is still to come | `swiftc` with the `vectraos` SDK (§8) |
| **Swift, Embedded** | Not yet: spike S14. ADR-0034 makes it first-party for servers, drivers and the boot path once it exists | — | — |
| **Lua** | Scripts, `wm` layout policies (D12, 03 §5.2), glue over files | Files: `/proc`, `/env`, a service's `ctl` | The system's Lua |
| **rc** | Shell scripts, namespace set-up | Files and programs | — |
| **C++, native** | A library or program written to standard C++ that you import or bring: an inference engine, a codec, a game engine's core. Not for first-party code, which is C23 or Swift | libc++ and the C library from the toolchain, `libvx` for the system | `clang++ --target=<arch>-unknown-vectraos` |
| **Odin, Zig, Rust and others** | Whatever their authors like | `libvx`'s C ABI, through the native target's sysroot | Their own compilers, linking against the sysroot |
| **C or C++ through POSIX** | Porting an existing Unix program or library: a compiler, an interpreter, a game whose source assumes Unix | musl and the POSIX personality (01 §9) | `--target=<arch>-vectra-unknown-musl` |

How to choose:

- **New native program, simple ownership:** C23.
- **New native program whose data is a graph, or whose logic is a set of cooperating tasks:** full Swift. ADR-0034's four reasons (OO or protocol structure, functional patterns, namespacing, ARC) are a good test for applications too.
- **A library written to ISO C** (a codec, a parser, a maths library): build it unchanged for the native target. llvm-libc supplies clause 7, with files and without POSIX.
- **A library written to standard C++** (an inference engine, a physics library): build it unchanged with `clang++` for the native target.
- **A library or program written to POSIX:** port it to the POSIX personality, or replace its platform layer with `libvx` calls if it is small. A program that needs `fork`, signals or sockets is a POSIX program.
- **Don't** put a portability layer (an SDL-like wrapper, an event-loop library, a cross-platform runtime) between your program and `libvx` to keep it "portable". `libvx` is small and has one way to do each thing (rule 13, 09 §1). Put your program's own platform layer at the top, where it names your program's needs, not the OS's.

## 3. Habits for every language

These follow from the design rules (00 §2), whatever the language.

1. **One loop, one wait** (rule 4). Everything a C program waits for (file requests, file changes, timers, child and thread exits, notes, posts from other threads) arrives on one `vx_loop` as one 64-byte `vx_event` (loop(2)). Don't start a thread to block on something; register it with the loop. In Swift, wait through Swift concurrency: the main actor runs on the main thread, and `async` work on a worker per CPU (Swift's main executor on `vx_loop` is still to come).
2. **Deadlines, not sleeps** (rule 5). Every wait takes an absolute deadline on the one clock and a leeway (`vx_sleep_until`, `vx_loop_wait`, `vx_timer_at`; Swift's `Task.sleep(until:)`). Never sleep in a loop; a periodic job is a timer with leeway.
3. **Intents, not priorities** (rule 6). Give each thread an intent when you start it (`vx_thread_spawn`'s, or `vx_intent_set`): `interactive-frame`, `interactive`, `throughput`, `background` or `realtime`. There is no affinity mask to set.
4. **Files for control, shared memory for bulk** (rule 2). A small request is a file read or a `vx_ctl` write; large data crosses as a VMO or a mapping (`vx_map`).
5. **Share structures; don't serialise them** (01 §6.6). To hand another process a tree or a table, build it in a VMO with offset links, seal it if the receiver must trust it, and send the handle; lend it for one call when it should come back. Don't encode it as JSON to send to a process on the same machine.
6. **Ask for what you need, and only that** (rule 3). From M7 a package's manifest `needs=` line is its whole view of the system (06 §3.3); broad grants, such as the whole home, are never given at install (ADR-0029). Design so your program works without them.
7. **No main thread** (rule 9). Every `libvx` call works from any thread (a loop's calls are its own thread's, but `vx_post` reaches it from any).
8. **Batch** (rule 11). Submit many requests in one `vx_io_submit`, read many events per `vx_loop_wait`.
9. **Errors are a status and a string** (09 §4.2). Check `vx_status` (or a negative return) where it matters and show `vx_errstr()`: a file server's message reaches you unchanged.
10. **Text is UTF-8, without locales** (ADR-0013). Cut strings at rune boundaries (`vx_bfmt` does); format numbers and dates one way.
11. **State is data** (rule 10). Settings are ndb records (`<vx/ndb.h>`), not code (D14).
12. **Exit with a reason** (ADR-0010). Success is the empty exit string. Failure says what failed, in words, or a number in decimal (`return 3` from C's `main` is `3`).

## 4. C23

The house subset (04 §1.1) is written for the OS tree, but most of it pays off in programs too.

- **Memory:** arenas first (`vx_arena_new`, `vx_push`, marks), pools for objects freed one at a time (`vx_pool_*`, ids that go stale), a `vx_heap` only where lifetimes are unrelated (arena(2), heap(2)). `libvx` never allocates behind your back; keep the same rule in your own libraries.
- **Scratch:** `vx_scratch` for temporary work, marked and popped, never a `malloc` and `free` pair inside a loop.
- **Slices, not NUL-terminated strings:** `vx_str` and `vx_bytes` throughout, printed with `"%.*s", VX_FMT(s)`; `vx_cstr` only at the edge, for C strings from elsewhere.
- **Nil objects and sticky errors:** a failed `vx_arena_new` is the nil arena, a full one says so once in `vx_arena_error`; check where it matters, not after every call.
- **Zero is a valid value:** design structs so that all zeroes is empty and ready.
- **Checked arithmetic** (`<stdckdint.h>`) on every size, offset or count that came from outside your process.
- **The C library is for code you import.** Your own code is simpler against `libvx`: `vx_fd` and `vx_printf`, not `FILE`. Defining `_POSIX_C_SOURCE` or `_GNU_SOURCE` is refused when you compile (native(7)).
- **Flags worth keeping:** `-std=c23 -Wall -Wextra -Werror`, frame pointers (the sysroot's configuration turns them on), DWARF 5 (`-g`), so `dbg` sees every frame (D15).
- **Format:** any consistent style. The house format (K&R, two-space indents) has a `.clang-format` you can copy.

## 5. Swift

- **What a program imports today:** the standard library, `FoundationEssentials` (`Data`, `Date`, `URL`, JSON coding, `FileManager`), and `VectraOSLibc` for the C library's functions (`exit`, the maths library). The `VX` module over `libvx` (namespaced types, noncopyable handles, typed errors with the server's message) is designed (ADR-0034) and not built; until then a Swift program reaches the system through Foundation.
- **Swift 6 language mode with complete strict concurrency.** Data races are compile errors; keep it that way rather than marking types `@unchecked Sendable`.
- **Ownership:** classes and ARC where an object really has several owners; structs, enums and noncopyable types where it does not. Keep reference counting out of per-element inner loops.
- **Concurrency:** `async`/`await`, task groups and actors run on Swift's own executor (a worker per usable CPU, the main thread for the main actor). Sleep with `Task.sleep(until:)` against `ContinuousClock`. There is no Dispatch.
- **Foundation:** FoundationEssentials only. FoundationInternationalization and ICU are not there, nor the old CoreFoundation-based Foundation. `FileManager` sees a namespace: symbolic links but no hard links, no owners or creation dates, and dates in UTC until M7's tz database.
- **Availability:** VectraOS's version is the `libvx` level. A program built for an unversioned triple deploys to level 0, and since nothing shipped is marked later than level 1, it uses all of level 1; an API of a later level is guarded with `if #available(VectraOS 2, *)`.
- **Errors:** typed `throws` at module boundaries, so callers can switch on cases.
- **Budgets:** code on a frame or audio path must not allocate: noncopyable types, preallocated buffers, `Span`.
- **Exporting to C:** `@c` (with `@implementation` for an existing header) when other languages call your library; keep the C interface in plain C types.
- **Packages:** SwiftPM for your own program if you like. The system ships no registry and trusts none (D13); your dependencies are yours to audit and ship inside your package (06 §3.4).

## 6. Lua and rc

- **Lua** is for scripts and policies, against files. A setting is ndb data, not a Lua table (D14). A Lua script that needs something the files don't offer is a sign that a service is missing a file, not that the script needs a binding.
- **rc** is Plan 9's shell, compatible with 9front's (M6 6a6). Scripts read `$status` as an exit string, and build namespaces with `bind` and `mount` themselves.

## 7. Ports through the POSIX personality

- **When:** existing software written to POSIX, whose rewrite would cost more than it gives: compilers, interpreters, version control, many games' engines.
- **What it costs:** every call goes through musl's back end, which turns Linux system calls into `libvx` and 9Px. File descriptors, `errno` and signals exist inside the program and nowhere else.
- **What it still gets:** the same namespace confinement, intents, `dbg` and crash directories as a native program. A port is confined by `/lib/ns/posix` or its own template; it never sees `/home` unless the user grants it (ADR-0029).
- **Moving a port to native** is usually a platform layer replaced, not a rewrite: the program's `#ifdef __linux__` file becomes a `libvx` file.

## 8. Building, debugging and shipping

- **C and C++:** the Swift toolchain's clang knows the target: `clang --target=<arch>-unknown-vectraos --sysroot=<sysroot> -std=c23 prog.c`, or `clang++` for C++. Fedora's clang builds the same with the sysroot's configuration file and response files (native(7), ADR-0033 §3). The sysroot is `./build`'s `out/<arch>/<mode>/vectraos`.
- **Swift:** `swiftc -target <arch>-unknown-vectraos -sdk <sdk> -resource-dir <sdk>/usr/lib/swift prog.swift`, with the SDK `swift-on-vectra`'s `toolchain/build_stdlib.sh` and `build_foundation.sh` make.
- **Levels:** a program builds for `VX_TARGET_ABI`, the SDK's level unless it sets one, so a newer call is a compile error rather than a surprise on an older release (ADR-0004); a manifest repeats it (`requires=vx-abi>=1`) from M7. A program checking for a newer call at run time asks `vx_abi_level()`.
- **Shared libraries:** a program needs `libvx.so.1` and `libc.so` (and the Swift runtime, for Swift); ld-vx(8) loads them from `/lib`. A fix in them reaches your program with the release; changed behaviour is announced in `docs/release-notes.md`, never silent. `-static` links `libvx.a` instead, and is not supported for programs from outside the release (ADR-0004 item 7).
- **Debug:** `dbg` reads `/proc` over 9Px, so remote debugging needs nothing extra. A crash leaves a crash directory with the backtrace, registers and the exit string. Keep frame pointers and DWARF 5.
- **Profile:** the profiler's zones (`/proc/N/prof`) are first-party until `<vx/prof.h>`, a later level; M7 adds sampling and tracing for every program (20).
- **Ship (M7 onwards):** a package is a tree per architecture, plus an `arch=any` tree for assets, a manifest with `needs=`, signed with your publisher key (06 §3.3). No install scripts: anything your program must set up, it does when it first runs, in its own data tree. Selling your program is up to you (06 §1).

## 9. Habits from elsewhere to leave behind

| Habit | Here |
|---|---|
| A main or UI thread that owns the system's calls | No main thread; any thread calls anything (rule 9) |
| `sleep(1)` in a loop, polling a file | A deadline with leeway; `vx_watch` on the file (rules 4, 5) |
| Thread priorities, `nice`, affinity masks | Intents, or reserved cores (rule 6) |
| A local socket speaking JSON to a helper process | Files for control; a sealed VMO for the data (01 §6.6) |
| A plugin as a shared library in your process, trusted blindly | A plugin is a process in its own namespace, given its input read-only and lent memory for one call (01 §6.6, §4.5) |
| `dlopen` to see whether a feature exists | ABI levels at compile time, `vx_abi_level()` at run time; optional services are files that may be absent |
| `getenv("HOME")` and wandering the disk | Your package's data tree is your `$HOME`; anything else is a grant (06 §3.3, ADR-0029) |
| A global `malloc` in every function | Arenas and scratch, with a heap only where lifetimes are unrelated |
| Locale-dependent parsing and formatting | UTF-8, one format |
| An install script | First-run set-up inside the program |

## 10. Worked examples

The same small tool, counting each named file's lines, in each language. The C and Swift versions were compiled against M6's sysroot and SDK on 2026-10-08.

**C23**, against `libvx` level 1:

```c
// lines: counts the lines of each file named, against libvx level 1.
#include <vx.h>

static uint64_t count_lines(vx_fd fd, vx_bytes buf, int64_t *err) {
  uint64_t lines = 0;
  int64_t n;
  while ((n = vx_read(fd, buf)) > 0)
    for (int64_t i = 0; i < n; i++) lines += buf.ptr[i] == '\n';
  *err = n;
  return lines;
}

int main(void) {
  vx_arena *a = vx_arena_new(1 << 20);
  vx_bytes buf = {vx_push(a, 64 << 10, 16), 64 << 10};
  if (!buf.ptr) {
    vx_eprintf("lines: %.*s\n", VX_FMT(vx_errstr()));
    return 1;
  }
  int failed = 0;
  vx_strs args = vx_args();
  for (size_t i = 1; i < args.len; i++) {
    vx_fd fd = vx_open(args.ptr[i], VX_OREAD);
    int64_t err = fd;
    uint64_t lines = fd >= 0 ? count_lines(fd, buf, &err) : 0;
    if (fd >= 0) vx_close(fd);
    if (err < 0) {
      vx_eprintf("lines: %.*s\n", VX_FMT(vx_errstr()));
      failed = 1;
      continue;
    }
    vx_printf("%8llu %.*s\n", (unsigned long long)lines, VX_FMT(args.ptr[i]));
  }
  vx_arena_free(a);
  return failed;
}
```

**Swift**, over FoundationEssentials:

```swift
// lines: counts the lines of each file named, in Swift over FoundationEssentials.
import FoundationEssentials
import VectraOSLibc // the C library: exit

var failed = false
for path in CommandLine.arguments.dropFirst() {
  do {
    let data = try Data(contentsOf: URL(filePath: path))
    let lines = data.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
    print("\(String(lines).leftPad(8)) \(path)")
  } catch {
    print("lines: \(path): \(error)")
    failed = true
  }
}
exit(failed ? 1 : 0)

extension String {
  func leftPad(_ width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
```

**rc**, driving it: files and programs are the interface, so a script needs nothing more.

```rc
for (f in /lib/ndb/*) lines $f
```

## 11. This document and the manual

It stays a design document. The manual is the reference a program is written against: native(7) for the target, the sysroot and the build, and section 2's pages for each call (arena(2), fmt(2), proc(2), thread(2), loop(2), file(2) and the rest). It is resynced at each milestone that changes what a program can use; next at M7, for `vxui`.
