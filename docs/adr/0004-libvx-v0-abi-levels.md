# ADR-0004: libvx v0 and the ABI levels

Status: accepted, 2026-10-08 (the user ordered the freeze, item 8: level 1 frozen at M6's close). Proposed 2026-10-08. Listed since M2 as "the ring layout; freezes `vx-abi` v0", to be written when the code existed; written at M6 step 6e4a, when `libvx` v0 was unparked. Decided the same day: v0 is the core 09 needs, by header (below); first-party programs stay unity-built through the same public headers; level 1 freezes as a gate at M6's close (6e4f).

## Context

09 §4.8 makes `libvx` (and later `vxui`) the system's stable binary interface: shared objects the release provides, programs linked to them dynamically, ABI levels that only add, and the syscalls behind them private between `libvx` and the kernel, as `ntdll`'s are on Windows. The loader exists (ADR-0047), and so does `libvx.so` (6f1b1), but it exports only the hooks the toolchain's C, C++ and Swift libraries call (`__llvm_libc_*`, `__llvm_libcxx_*`, `__llvm_libunwind_*`, `__swift_vectraos_*`) and `vx_start`.

Everything else `libvx` has is `static`, compiled into each first-party program by including `lib/vx-rt/rt.c`, with no public header. An inventory against 09 §5 (2026-10-08) found:

- **There today, under 09's names or near them:** the heap (`vx_heap_*`), threads and mutexes (`vx_thread_spawn`, `vx_mutex_*`; since 6e4b `vx_lock`, and since 6e4c3 `vx_thread_spawn` takes 09's signature, with an intent and an exit string), time (`vx_now`, `vx_sleep_until`, `vx_clock_utc`), the syscall wrappers (VMOs, address space, ports, channels, counters, futexes), notes (`vx_notify`), runes (`<vx/utf.h>`-to-be), ndb, and files through `vx_ns_*` and `p9c_*`.
- **Missing:** arenas and pools, strings and formatting, the event loop, most of the file API, processes as 09 has them, the network and services.

The Swift runtime, now shared too (ADR-0048), binds to `libvx.so`'s hooks, so its freeze and `libvx`'s are one decision.

Prior art: Fuchsia annotates every SDK declaration with the API level that added it (`ZX_AVAILABLE_SINCE(n)`, `zircon/system/public/zircon/availability.h:75`), a clang availability attribute checked against `__Fuchsia_API_level__`, and keeps its syscalls private behind the vDSO. Windows keeps `ntdll`'s syscalls private behind the documented DLLs. 9front's libc is one library with one header, `<libc.h>`, over the system calls and 9P.

## Decision

1. **A level is a promise about four things:** the functions `libvx.so` exports, the declarations its public headers make, the layouts of the records those declarations pass (each with a fixed size checked by `static_assert`, and a version or size field where it may grow, 09 §4.1), and the documented behaviour of each call. Level n is level n−1 with additions; nothing is removed or changed. A call may be deprecated (a warning attribute and a release note) but stays.
2. **v0 is the core 09 needs**, by header (decided 2026-10-08):
   - `<vx/sys.h>`: the syscall wrappers a program may use (VMOs, address space, ports, channels, counters, futexes, threads, notes), with absolute deadlines;
   - `<vx/mem.h>`: arenas, scratch, pools and heaps (`vx_mem_budget` waits for the kernel to keep memory budgets, which it does not yet: a later level; found in 6e4c1);
   - `<vx/str.h>`, `<vx/utf.h>`, `<vx/fmt.h>`, `<vx/ndb.h>`: slices, runes, formatting with clang-checked format strings, ndb records;
   - `<vx/time.h>`: `vx_now`, `vx_sleep_until`, `vx_wallclock`;
   - `<vx/thread.h>`: threads, intents, `vx_lock`, rendezvous;
   - `<vx/proc.h>`: spawning, exec, watching, notes;
   - `<vx/loop.h>`: the loop, `vx_post`, timers, and the one event record, `vx_event` (level 0 delivers posts, timers, exits and notes; every kind's number is fixed now, the rest arriving with the calls that make them);
   - `<vx/file.h>`: files in full (open, create, read and write at an offset, stat and wstat, directories, remove, rename, symbolic links, flush, map, watch, ctl, `vx_io_submit`);
   - `<vx/ns.h>`: bind, mount, unmount, a new namespace (not built before the freeze, found 2026-10-08 in 14's resync: level 2's first addition);
   - `<vx/err.h>`: `vx_errstr`, the calling thread's last error in words;
   - `<vx/random.h>`: `vx_random_bytes`, the process's generator (R15; not in 09, added in 6e4e);
   - and `<vx.h>`, which includes them all.

   `<vx/net.h>`, `<vx/srv.h>` (the 9Px server), `<vx/ring.h>` and the diagnostics headers are later levels. Until then the ring layout stays private between `libvx`, the servers and the drivers, and the 9Px protocol is frozen separately, by 02 §3.3's extension rules.
3. **09's names win.** Where today's code differs (`vx_mutex_lock` against `vx_lock`, `vx_clock_utc` against `vx_wallclock`, `vx_ns_open` against `vx_open`, `vx_spawn_elf` against `vx_proc_spawn`), the code is renamed, as 09 §9 planned. Signatures follow 09's conventions: slices, never NUL-terminated strings; absolute deadlines; `vx_status` and `vx_errstr`; nil objects, never `NULL`; no allocation the caller did not ask for.
4. **`VX_TARGET_ABI`.** A program compiles for a level: `VX_TARGET_ABI`, defaulting to the SDK's `VX_ABI_LEVEL`. Every declaration after level 1 sits inside `#if VX_TARGET_ABI >= n`, so a newer call is a compile error for an older target, the error 09 §4.8 asks for. Clang's availability attributes, Fuchsia's way, would need a VectraOS platform for C (Swift has one, ADR-0048), so the plain `#if` is used. A program that uses a newer call when it is present checks `vx_abi_level()` at run time. A manifest repeats the level it needs (`requires=vx-abi>=n`, 06 §3.4).
5. **Exports.** `libvx.so` exports exactly what the public headers declare, through one macro (`VX_API`), at default visibility, and the toolchain hooks, which are part of the level too: the shared C, C++ and Swift libraries bind to them, so changing one breaks every program. Everything else is hidden. Each frozen level has its export list in the tree (`abi/levels/<n>.symbols`, sorted), and every build compares the `libvx.so` it makes with it (since 6e4e; `abi/levels/README`): a missing symbol is an error, and a new one belongs to the next level.
6. **First-party programs stay unity-built** (decided 2026-10-08), through the same public headers: `VX_API` is `static` in a unity build, so a first-party program compiles `libvx` in as today, against exactly the declarations apps see. The boot path and the servers before `fsd` could not load a library anyway.
7. **The kernel's numbers stay private** (09 §10 question 2). Syscall numbers and the spawn message's format may change with any release, since only `libvx.so` (and the release's own first-party programs, rebuilt with the kernel) uses them. A third-party program therefore links `libvx` dynamically; a static third-party program is not supported.
8. **Freezing a level** is a gate (level 1 at M6's close, 6e4f), with the behaviour suite green (6e4e). It sets `VX_ABI_LEVEL`, commits the export list and the Swift libraries' ABI baselines (ADR-0048 item 5), and versions the sonames. From then on, a changed expectation in the behaviour suite needs a release-notes entry, which `./build release` checks (since 6e4e: the suite, vxapitest and libvxtest with their manifests and scenarios, is hashed, the hash frozen as `abi/levels/<n>.behaviour`, and a different one refused unless `docs/release-notes.md` names it).

## Consequences

- Third-party programs depend on `libvx.so`'s exports and behaviour, not on the kernel, so the kernel's interface can keep changing as it has, release by release.
- The first-party code is renamed and given public headers before the freeze, a large but mechanical change, done in 6e4b. After it, a first-party program and an app see the same declarations.
- The missing core (6e4c, 6e4d) is written before the freeze, and the network and services come after it, as additions.
- A level is something the project keeps for as long as programs built for it exist. The behaviour suite is what holds behaviour to it, not only the symbols.
