# Phase 9 — The native API

_Blueprint v0, 2026-10-02. A sketch: it fixes the shape, the conventions and the list of calls, and each part is rewritten against the code that first calls it (00, "How firm these documents are"). Signatures here are drafts._

## 1. The position

**A native program talks to the kernel and to file servers, and to nothing in between.** Plan 9's libc was a thin library over the system calls and 9P, with no Unix underneath, and that is the model. POSIX is a personality that sits *beside* the native API and is built *on* it (01 §9, ADR-0007), never under it. No native call reaches the kernel through musl, a file descriptor table it does not need, `errno`, or a signal.

The code already works this way. Every command, server and driver links against `vx-rt` and the other `lib/vx-*` libraries, freestanding, with no libc. What is missing is the middle of a usable API: there is no allocator, no formatted output, no thread library, no environment, no sleep, and the file API lacks `stat`, `remove` and `seek`. Programs work around the gaps with static buffers and raw syscalls (§9). This document fills the middle without adding a layer.

**What the study says, in one paragraph.** The platform API study ([study/](study/README.md)) found that wrapper libraries exist mostly to hide three platform accidents: the main thread, the system's modal loops and the swapchain. What applications actually want is the set of things the wrappers add: a frame that always arrives, a wake from any thread, one wait for everything with an absolute deadline, a latency number, id handles, an input queue that loses nothing, and exact budgets (Q2 §4). The heritage systems with the smallest APIs (Exec, GEM, Horizon) had one way to do each thing and one wait for all of it (heritage §2, §4). Consoles reach a window, a frame, input and sound in 7 to 13 calls with no portability layer at all (heritage §3). The native API offers those additions directly, and has no platform accidents to hide.

## 2. The layers

```
 ┌ app ───────────────────────────────────────────────────────────────┐
 │  <vxui.h>   windows, frames, input, UI, voices        (03 §6)       │
 │  <vx/wsys.h> <vx/audio.h> <vulkan>   the engine tier  (03 §6)       │
 │  <vx.h>     libvx: memory, text, files, loop, time, threads,        │
 │             processes, namespace, network, services     (this doc)  │
 │  <vx/sys.h> the syscall wrappers, public, [[nodiscard]]             │
 └──────┬──────────────────────────────┬──────────────────────────────┘
        │ syscalls (and the vDSO page)  │ 9Px over rings, to file servers
        ▼                               ▼
     kernel                        fsd · netd · procfs · winsrv · audiod · …

 beside it, never under it:  musl + the vx back end (POSIX ports), built on libvx
```

- **`libvx` is one library,** assembled from what exists: `vx-rt`, `vx-mem`, `vx-utf`, `vx-ndb`, `vx-note`, the file half of `vx-ns`, and the client half of `vx-9p`. Its headers live under `<vx/…>`, and `<vx.h>` includes them all, as Plan 9's `<libc.h>` did.
- **`<vx/sys.h>` is public.** Every syscall wrapper an app may need (VMOs, ports, channels, rings, counters, futexes, threads) is documented and callable. A program that wants the kernel object uses it, and nothing in `libvx` stands in its way.
- **`vxui` is built on `libvx`, not beside it.** `vx_wait` is `libvx`'s loop with window sources added (§5.4), and its events are `libvx`'s event record with more kinds.
- **The engine tier** reaches `/wsys`, `audiod` and Vulkan directly, as 03 §6 says. Its headers declare the ring layouts and record types those servers use, and little else.

## 3. The one-hop rule

**Every `libvx` call does its work itself, or makes one request: one syscall, or one 9Px message (or one batch of either).** A call that would need a second hop is two calls, so the program can see, and choose, the cost. The few unavoidable exceptions, such as spawning a process, list every syscall and request they make.

Each call's reference entry states its **cost class**:

| Class | Meaning | Examples |
|---|---|---|
| **P** | Pure: no kernel entry, no message | `vx_push`, `vx_fmt`, `vx_utf_*`, `vx_ndb_*`, `vx_now` (vDSO) |
| **S** | One syscall | `vx_post`, `vx_lock` when contended, `vx_loop_wait` |
| **R** | One 9Px request on a ring, or one pipelined group sent together (walk, open, write, clunk), answered asynchronously or awaited | `vx_open`, `vx_read`, `vx_stat`, `vx_ctl` |
| **B** | One batch: an array of S or R operations in one submission | `vx_io_submit`, `vx_close_all` |
| **L** | A listed sequence | `vx_proc_spawn`, `vx_dial` |

Hidden costs the rule forbids: an allocation the caller did not ask for, a lock the caller cannot see, a thread the library starts for itself, a second clock, and a conversion from one representation to another and back (S7's shim spent a conversion on every timer arm because macOS has two clocks; 00 §1's one clock removes it).

## 4. Conventions

### 4.1 Names, headers and types

- **Names:** `vx_` for functions and types, `VX_` for constants, lower snake case, noun first: `vx_file_map`, `vx_proc_spawn`, `vx_loop_wait`. One verb per job; no `_ex` or `2` suffixes, because a new version is a new ABI level (§4.8), not a new name.
- **Slices, never NUL-terminated strings.** `vx_str {const char *ptr; size_t len}` for text, which is UTF-8 (ADR-0013); `vx_bytes {uint8_t *ptr; size_t len}` for data. `vx_bytes` moves from `vx-9p` into `<vx/abi.h>` beside `vx_str`. `VX_STR("lit")` makes a slice from a literal.
- **Time** is `vx_instant` (nanoseconds on the one monotonic clock) and `vx_duration`. Every call that can wait takes an absolute `deadline` and a `leeway`; there is no relative timeout and no resolution setting (rules 4 and 5).
- **Records crossing a boundary** have fixed sizes and fixed-type enums, checked with `static_assert`, and a version or size field where they can grow (Q2 §6.2).

### 4.2 Errors

- **Calls return `vx_status`** (zero or a negative code from `status.def`) or a count that is negative on failure, as the syscalls already do.
- **The detail is text:** `vx_errstr()` returns the calling thread's last error message as a `vx_str`, up to `VX_ERRMAX` bytes, as Plan 9's `errstr` did. A file server's `Rerror` string arrives here unchanged, so "`/n/tower: hungup`" reaches the program instead of a bare code. This is the study's "status plus thread-local detail" (Q2 C13).
- **Objects carry sticky errors** (04 §1.1): a function that makes an object returns a pointer to it, or to a read-only nil object on failure, never `NULL`. Calls on a nil object do nothing and return `VX_ERR_NIL`. A program checks once, where it matters, with `vx_app_error(app)`, `vx_arena_error(a)` and the like. The study reached the same rule independently: an invalid handle is a diagnosed no-op (Q2 R8).
- **Asynchronous failures are events:** a lost connection, a device removed, an audio contract changed, a GPU lost. Nothing is reported by a callback, and nothing panics on a recoverable condition (Q2 R12).

### 4.3 Memory

**`libvx` never allocates behind the caller's back.** Every call that needs memory takes an arena, or writes into a buffer the caller passes. This is the study's "C layers take a user allocator" (Q2 C12) taken to its end: the allocator is always an argument.

- **Arenas** are the first memory: a reserved range of address space whose pages are committed as it grows (`as_reserve`, `vmo_op commit`). Pushing is pure; growing is one syscall.
- **Pools** are the second: fixed-size slots with index-plus-generation ids, for objects that are freed one at a time, such as a server's fids or a UI's nodes (Q2 C9, R9).
- **`vx_heap`** is the third, for programs whose objects have unrelated lifetimes, such as an editor's buffers: a general allocator *object*, made explicitly and passed explicitly. There is no global `malloc`; a program that wants one makes one heap and keeps it in a global itself.
- **Scratch:** each thread has two scratch arenas, given out so that a callee's scratch never overlaps its caller's (`vx_scratch(conflicts…)`), as in Ryan Fleury's arena design and the RAD Debugger.

### 4.4 Handles and objects

- **Kernel handles** are index plus generation already (01 §3). A stale handle fails with `BAD_HANDLE`.
- **`libvx` objects** are pointers inside the process, and nil objects on failure (§4.2).
- **Anything that crosses a process,** such as a window id in an event or a fid in a server, is an index-plus-generation id, never a pointer (Q2 C9).

### 4.5 Threads

- **No main thread.** Every call works from any thread (rule 9). `libvx` keeps no hidden global state: per-thread state (the error string, the scratch arenas) lives in thread-local storage, and everything else lives in objects the program passes.
- **Calls that share an object** (two threads reading the same `vx_file`) are safe if the reference says so, and the reference says so for each call. Calls on different objects never contend.

### 4.6 Batching

Hot calls take arrays and counts (rule 11): `vx_loop_wait` returns many events, `vx_io_submit` takes many requests, `vx_close_all` closes many handles.

### 4.7 One event record

There is one event record for the whole native API, `vx_event`: 64 bytes, a kind, flags, a source id, the time on the one clock, a 64-bit key the program chose, and a payload. Variable-length data (text, a path, an exit string) is a slice into the loop's arena, valid until the next wait (Q2 R1). `libvx` defines the system kinds (§5.4); `vxui` and the engine headers add theirs to the same enum. A program has one loop, one wait and one record, whatever it uses.

### 4.8 Versions and the ABI

- **`libvx` and `vxui` are linked statically,** as everything in the system is today (§10, question 1). The stable binary interface is therefore the kernel's syscalls and the file servers' protocols, not library symbols. That is Plan 9's arrangement, and it needs no dynamic loader and no symbol versioning.
- **ABI levels.** ADR-0004 freezes `vx-abi` v0; each later level only adds. A program declares the level it targets, `VX_TARGET_ABI`, which its manifest repeats (`requires=vx-abi>=2`, 06 §3.4). The headers declare a newer call only when the target level includes it, so using one without raising the target is a compile error, which is the study's "error on an unguarded newer symbol" (F-219). A program that wants a newer feature when present checks `vx_abi_level()` at run time.
- **Optional services are files,** not libraries. A program that uses `aid` opens `/ai`; if `aid` is not installed the open fails with an ordinary error. There is no `dlopen` probing (F-219).

## 5. The surface

The tables give each area's header, its main calls, what backs them, and whether they exist today. Signatures are drafts.

### 5.1 Program entry, arguments and exit

```c
const char *vx_main(void);                  // the program's entry; returns its exit string ("" or nullptr: success)
vx_strs     vx_args(void);                  // P: the arguments, as slices
vx_str      vx_arg(size_t i);               // P
[[noreturn]] void vx_exits(const char *msg);  // flushes, then task_kill(self)
```

The arguments come from the spawn message (01 §3). The environment is files: `vx_env_get(name, arena)` reads `/env/NAME` (R), as Plan 9's `getenv` did, so a script and a program see the same values. The spawn message's `env=` records exist for the POSIX personality only.

### 5.2 Memory: `<vx/mem.h>`

```c
vx_arena *vx_arena_new(size_t reserve);                    // S: reserve address space
void     *vx_push(vx_arena *a, size_t size, size_t align); // P, or S to commit more; memory is zeroed
vx_mark   vx_arena_mark(vx_arena *a);  void vx_arena_pop(vx_arena *a, vx_mark m);   // P
vx_arena *vx_scratch(vx_arena *const *conflicts, size_t n);                        // P
vx_pool  *vx_pool_new(vx_arena *a, size_t slot_size, size_t max);                  // P
vx_id     vx_pool_take(vx_pool *p);  void *vx_pool_get(vx_pool *p, vx_id id);  void vx_pool_put(vx_pool *p, vx_id id);
vx_heap  *vx_heap_new(size_t reserve);  void *vx_heap_alloc(vx_heap *h, size_t n);  void vx_heap_free(vx_heap *h, void *p);
vx_budget vx_mem_budget(void);                             // P: from the shared page; exact, CPU and GPU together (F-109)
```

Raw memory is `<vx/sys.h>`: `vmo_create`, `vmo_op`, `as_reserve`, `as_map` with views (01 §5). A program with unusual needs, such as an emulator or a JIT, uses those directly.

### 5.3 Text: `<vx/str.h>`, `<vx/utf.h>`, `<vx/fmt.h>`, `<vx/ndb.h>`

- **Slices:** `vx_str_eq`, `vx_str_cut`, `vx_str_find`, `vx_str_split`, `vx_str_cat(arena, …)`, `vx_str_u64`, `vx_str_i64`. All P.
- **Runes:** Plan 9's rune functions and ADR-0013's cutting rules, as `<vx/utf.h>` has them today.
- **Formatting:** `printf`'s verbs, so clang checks every format string (`[[gnu::format(printf, …)]]`). A slice prints as `"%.*s", VX_FMT(s)`.
  ```c
  vx_str vx_fmt(vx_arena *a, const char *fmt, ...);      // P
  size_t vx_bfmt(vx_bytes buf, const char *fmt, ...);    // P; truncates at a rune boundary
  int64_t vx_printf(const char *fmt, ...);               // R: one write to stdout
  int64_t vx_eprintf(const char *fmt, ...);              // R: one write to stderr
  ```
- **ndb:** the reader and writer `<vx/ndb.h>` has today, plus `vx_ndb_file(path, arena, &records)` (R), which reads a server's `info`, `status` or `.schema` in one call.

### 5.4 The loop and events: `<vx/loop.h>`

A loop is a port (01 §4.4) plus the bookkeeping to turn packets into events. One loop per thread that wants one; one per program is the default (S7 §4).

```c
vx_loop *vx_loop_new(void);                                                    // S: port_create
int64_t  vx_loop_wait(vx_loop *l, vx_instant deadline, vx_duration leeway,
                      vx_event *evs, size_t cap);                              // S: port_wait; deadline 0 polls
vx_status vx_post(vx_loop *l, uint64_t a, uint64_t b);                         // S: port_post, from any thread
vx_timer  vx_timer_at(vx_loop *l, vx_instant at, vx_duration leeway,
                      vx_duration every, uint64_t key);                        // S
void      vx_timer_stop(vx_loop *l, vx_timer t);                               // S
```

| Kind | Source | Payload |
|---|---|---|
| `VX_EV_POST` | `vx_post`, from any thread or a peer holding the port | two `uint64_t` |
| `VX_EV_TIMER` | `vx_timer_at` | the timer, how late it fired |
| `VX_EV_IO` | a request from `vx_io_submit` completed (§5.5) | the key, a count or a status, the bytes |
| `VX_EV_CHANGED` | a watched file changed (9Px `notify`, 02 §3.3) | what changed |
| `VX_EV_READY` | a file with a read held open has data: a pipe, the console, a `/net` connection, an `events` file | the file |
| `VX_EV_EXIT` | a watched process or thread ended | its id, the exit string |
| `VX_EV_NOTE` | a note, if the program asked for notes as events (§5.7) | the note text |
| `VX_EV_PRESSURE` | the memory budget changed or is under pressure | the new budget |
| `VX_EV_HUNGUP` | a connection to a server dropped and could not be redialled (02 §6.8) | the mount point |

`vxui`'s `vx_wait(app, &ev, deadline)` is this wait with the app's windows, frames, input and audio contract bound to the same port (03 §6, principle 1). An engine calls `vx_loop_wait` with a zero deadline from inside its own frame loop.

### 5.5 Files: `<vx/file.h>`

Plan 9's file calls, on `vx_fd`, a small index-plus-generation id into the process's table of open 9Px fids.

```c
vx_fd   vx_open(vx_str path, vx_mode mode);                  // R (one Twalk+Topen, pipelined)
vx_fd   vx_create(vx_str path, vx_mode mode, uint32_t perm); // R
int64_t vx_read(vx_fd fd, vx_bytes buf);                     // R, at the file's offset
int64_t vx_pread(vx_fd fd, vx_bytes buf, uint64_t off);      // R
int64_t vx_write(vx_fd fd, vx_str data);  int64_t vx_pwrite(vx_fd fd, vx_str data, uint64_t off);
vx_status vx_stat(vx_str path, vx_arena *a, vx_dir *out);    // R
vx_status vx_wstat(vx_str path, const vx_dir *d);            // R
int64_t vx_dirread(vx_fd fd, vx_arena *a, vx_dir **out);     // R; all entries in one read where they fit
vx_status vx_remove(vx_str path);  vx_status vx_close(vx_fd fd);
vx_status vx_map(vx_fd fd, uint64_t off, size_t len, uint32_t prot, void **addr); // R + S: Tmap, then as_map (01 §5)
vx_status vx_watch(vx_loop *l, vx_fd fd, uint64_t key);      // R: VX_EV_CHANGED or VX_EV_READY on l
vx_status vx_ctl(vx_str path, const char *fmt, ...);         // R: one ctl verb, written once
```

**Asynchronous I/O is the same requests, not a second API** (F-217). A synchronous call is a request whose completion the call waits for; `vx_io_submit` sends many and lets the loop collect them:

```c
typedef struct {
  vx_fd fd; vx_io_op op;        // READ, WRITE, STAT, MAP, …
  uint32_t flags;               // VX_IO_UNCACHED, VX_IO_ONCE (read once, don't keep), VX_IO_PREFETCH
  uint64_t off; vx_bytes buf;   // any alignment: there is no O_DIRECT, so no alignment rule
  uint64_t key;
} vx_io;
vx_status vx_io_submit(vx_loop *l, const vx_io *ops, size_t n);    // B: one ring submission
```

The flags are the study's per-request cache policy (F-217), which the blueprint dropped. They become fields of the 9Px read and write requests (02 §3.3), so `fsd` and the page cache see them, rather than per-VMO settings only.

### 5.6 Time: `<vx/time.h>`

```c
vx_instant vx_now(void);                                   // P: the vDSO page (01 §3)
vx_status  vx_sleep_until(vx_instant at, vx_duration leeway);   // S: a port_wait with no sources
vx_wall    vx_wallclock(void);                             // P: now plus the offset /sys/clock publishes
```

There is no `sleep(duration)`. A loop that needs a period computes the next deadline from the last one, so error never accumulates (F-203).

### 5.7 Threads and synchronisation: `<vx/thread.h>`

```c
vx_thread *vx_thread_spawn(const char *(*fn)(void *), void *arg, vx_intent intent, size_t stack);  // L: VMO, map, thread_create, thread_start
vx_status  vx_thread_watch(vx_loop *l, vx_thread *t, uint64_t key);   // S: VX_EV_EXIT with its exit string
vx_status  vx_intent_set(vx_intent intent);                           // S: sched_ctx_configure
vx_status  vx_realtime(vx_duration period, vx_duration budget, vx_grant *out);  // S: admission; refused with a reason in vx_errstr()
vx_status  vx_realtime_join(const vx_grant *g);                       // S: a helper thread joins a stream's deadline (F-215)
void vx_lock(vx_lock_t *l);  void vx_unlock(vx_lock_t *l);            // P uncontended, S contended: futex
void vx_rendez_sleep(vx_rendez *r, vx_lock_t *l);  void vx_rendez_wake(vx_rendez *r);   // Plan 9's Rendez, over futexes
```

- **Intents, never priorities or affinity** (rule 6): `interactive-frame`, `interactive`, `throughput`, `background`, `realtime(period, budget)`.
- **Real-time is admitted, not requested blindly.** `vx_realtime` either grants the deadline or fails and says why; the grant and every deadline miss are readable as text in `/proc/N/threads/T/sched` (F-215).
- **Messages between threads** are `vx_post` to a loop: a fixed two-word payload, into a bounded queue. The study found that portable code never uses OS channel primitives (`THR.channel`: 0 uses in the corpus), so there is no channel type above the port.
- **Atomics** are C23's `<stdatomic.h>`, with nothing added.

### 5.8 Processes and notes: `<vx/proc.h>`

```c
typedef struct {
  vx_str path;  vx_strs args;
  vx_str ns;                    // a namespace(6) template name or text; empty shares the caller's group (ADR-0009)
  const vx_handle *handles; size_t nhandles;
  vx_intent intent; uint32_t flags;   // VX_PROC_NEWGROUP, VX_PROC_NOWAIT, …
} vx_spawn_req;
vx_status vx_proc_spawn(const vx_spawn_req *r, vx_proc *out);  // L: read the image (R), task_create, map, spawn message, thread_start, register with procfs
vx_status vx_proc_exec(const vx_spawn_req *r);                 // L: as above, then task_exec; returns only on failure
vx_status vx_proc_watch(vx_loop *l, vx_proc p, uint64_t key);  // S: port_bind on the task's EXIT; VX_EV_EXIT with the exit string
vx_status vx_postnote(vx_proc p, vx_str note);                 // R: write /proc/N/note
vx_status vx_notify(vx_note_handler *h);                       // as today (ADR-0010)
vx_status vx_notes_to_loop(vx_loop *l);                        // notes arrive as VX_EV_NOTE instead of interrupting
```

A program that handles notes in its loop never sees an asynchronous interruption, which is the one-wait rule applied to notes.

### 5.9 Namespace: `<vx/ns.h>`

`vx_bind(old, new, flags)`, `vx_mount(srv, spec, at, flags)`, `vx_unmount(at)` and `vx_newns(template)`, each one request to `libns` or `nsd` (ADR-0009). They exist today as `vx_ns_*`; the public names drop the `ns` handle, which the process holds once.

### 5.10 Network: `<vx/net.h>`

Plan 9's `dial` over `/net` (02 §5.4), not sockets:

```c
vx_status vx_dial(vx_str addr, vx_conn *out);        // L: /net/cs lookup, clone, ctl connect; "tcp!tower!564", "udp!…", "tls!example.org!443"
vx_status vx_announce(vx_str addr, vx_conn *out);    // L
vx_status vx_listen(vx_conn *c, vx_conn *call);      // R: blocks, or use vx_watch on the listen file
vx_status vx_accept(vx_conn *call);                  // R
```

`vx_conn` holds the data `vx_fd`, the control `vx_fd` and the connection directory. `tls!` dials through `tlsd` (00 D16), so a program never links TLS and never holds a credential.

### 5.11 Services and servers: `<vx/srv.h>`

- **Using a service** is files: `vx_open`, `vx_ctl`, `vx_ndb_file` on its `info` and `.schema`, `vx_watch` on its `events`.
- **Writing one** is the `vx-9p` server that every system server uses today: a table of operations on opaque node ids, served on a ring, with `.help` and `.schema` generated from the server's `ctl` X-macro table (04 §1.1). It becomes public, so an app can serve its own tree, as `hx` serves `/mnt/hx` (08 §12).

### 5.12 Raw IPC: `<vx/sys.h>`, `<vx/ring.h>`

Channels, rings, counters and sessions, as `vx-ring` and the wrappers have them. Most programs never use them, because files cover control and the toolkit covers bulk; servers, drivers and engines do.

### 5.13 Windows, input, audio and the GPU

These are `vxui` (03 §6) and the engine tier, and 03 owns them. §7 lists what the study proposed for them that 03 does not yet say.

### 5.14 Diagnostics: `<vx/prof.h>`, `<vx/debug.h>`

`vx_prof_begin(&zone)` and `vx_prof_end(&zone)` (05 §9), `vx_debug_write` while a debug capability is held, and nothing else: debugging is `dbg` reading `/proc` (05).

## 6. What the native API does not have

| Absent | Instead |
|---|---|
| `errno` | `vx_status` and `vx_errstr()` (§4.2) |
| `FILE *`, stdio buffering | `vx_fd`; a program buffers in its own arena when it wants to |
| A global `malloc` | Arenas, pools and explicit heaps (§4.3) |
| Signals | Notes, as a handler or as loop events (§5.8) |
| `fork` | `vx_proc_spawn`; `fork` exists in the POSIX personality only |
| `select`, `poll`, `epoll`, `kqueue` | The loop (§5.4) |
| Sockets | `vx_dial` over `/net` (§5.10) |
| Locales | Text is UTF-8 (ADR-0013); formatting is not localised |
| `dlopen` | Static linking and services as files (§4.8) |
| A main thread, a run loop the system owns, a callback driver | The program owns its loop (03 §6) |
| `sleep(seconds)`, timer resolution | Absolute deadlines with leeway (§5.6) |

## 7. Study findings not yet in the blueprint

A second reading of the study found details its condensed copy in [study/](study/README.md) dropped or softened. These are the ones that change an interface; each lands where shown.

**Below the toolkit:**

| Finding | Proposal | Lands in |
|---|---|---|
| F-217: per-request cache policy, prefetch hints, a pinned-memory budget | `vx_io` flags (§5.5); 9Px read and write fields; a pin budget in 01 §5 | 02 §3.3, 01 §5 |
| F-218: fixed reservations in release builds | Emulators and translation layers need `AS_FIXED` in release builds; 01 §5 allows it only under the `dev` policy. Allow it for any reservation in an unused range, keeping JIT under the existing W^X dual mapping | 01 §5 |
| F-215: helper threads joining a real-time deadline; misses as text | `vx_realtime_join`; `/proc/N/threads/T/sched` | 01 §8, 05 §3 |
| F-204: window visibility driving thread intent | `vxui` lowers a window's render thread to `background` when the window is hidden and raises it when shown | 03 §6 |
| F-107, F-108: device UUID; "is this GPU cache-coherent UMA" | Fields in `/dev/gpu/N/info`, read through `vx_ndb_file` | 02 §5.3 |
| F-109: GPU memory priority as eviction order | Vulkan memory priority maps onto VMO purge order | 01 §5 |

**In `/wsys` and `vxui`, before the `/wsys` v1 freeze (03 §5.1):**

| Finding | Proposal |
|---|---|
| F-209 | Visibility as four states (visible, partial, occluded, hidden) in the configure record, and the throttled frame rate stated in `info` |
| F-205 | One configure record carrying logical size, pixel size, scale and `config_seq`; stable output names; an output hot-plug event |
| F-202 | An `interactive` flag on configure events while the user is dragging or resizing |
| F-207 | `move` and `resize edge` verbs with no coordinates, which start a server-driven move from the current press |
| F-210 | A `keymap` file naming the active layout, and an event when it changes |
| F-211 | A flag on key events the IME passed through; a `purpose` verb on the `ime` file |
| F-213 | A flag on motion caused by a warp; pointer-lock state changes as events |
| S7 finding 3 | A buffer size independent of window size, scaled by the compositor (`wp_viewporter`) |
| ndtk | Buffer age on CPU surfaces, for damage-only redraw |

## 8. Examples

`cat`, in full:

```c
#include <vx.h>

const char *vx_main(void) {
  static uint8_t buf[64 << 10];
  vx_strs args = vx_args();
  for (size_t i = 1; i < args.len; i++) {
    vx_fd fd = vx_open(args.ptr[i], VX_OREAD);
    if (fd < 0) {
      vx_eprintf("cat: %.*s: %.*s\n", VX_FMT(args.ptr[i]), VX_FMT(vx_errstr()));
      return "open";
    }
    int64_t n;
    while ((n = vx_read(fd, (vx_bytes){buf, sizeof buf})) > 0)
      if (vx_write(VX_STDOUT, (vx_str){(char *)buf, (size_t)n}) != n) return "write error";
    vx_close(fd);
  }
  return nullptr;
}
```

A loop that loads two files, runs a child and ticks a timer, with one wait:

```c
vx_loop *l = vx_loop_new();
vx_io reads[] = {
  {.fd = a, .op = VX_IO_READ, .buf = bufa, .key = 1},
  {.fd = b, .op = VX_IO_READ, .buf = bufb, .key = 2, .flags = VX_IO_ONCE},
};
vx_io_submit(l, reads, 2);
vx_proc child;
vx_proc_spawn(&(vx_spawn_req){.path = VX_STR("/bin/build")}, &child);
vx_proc_watch(l, child, 3);
vx_timer_at(l, vx_now() + 16 * VX_MS, VX_MS, 16 * VX_MS, 4);

vx_event ev[16];
for (;;) {
  int64_t n = vx_loop_wait(l, VX_INFINITE, 0, ev, 16);
  for (int64_t i = 0; i < n; i++)
    switch (ev[i].kind) {
    case VX_EV_IO:    loaded(ev[i].key, ev[i].io.count); break;
    case VX_EV_EXIT:  finished(ev[i].exit.msg); break;
    case VX_EV_TIMER: tick(); break;
    default:          break;
    }
}
```

## 9. From today's code to this

| Today | Becomes |
|---|---|
| `vx-rt`, `vx-mem`, `vx-utf`, `vx-ndb`, `vx-note`, `vx-ns`, `vx-9p`'s client, each included as `.c` into one unit, with `static` functions | `libvx`, with public headers under `<vx/…>`, still unity-built inside the OS tree, and shipped as headers plus a static archive in the SDK |
| No allocator: static buffers, or `vmo_create` and `as_map` by hand (`servers/tmpfs/tmpfs.c`, `servers/nsd/nsd.c`) | Arenas and pools (§5.2); needs `as_reserve` and `vmo_op`, both unimplemented |
| No formatting: `cmd/ping.c` hand-rolls numbers | `<vx/fmt.h>` |
| `vx_ns_*` without stat, remove or seek; callers drop to `p9c_*` | `<vx/file.h>` in full |
| One 9Px request in flight per connection (`lib/vx-9p/ring.c`) | Many tags in flight, which `vx_io_submit` and pipelined `vx_open` need |
| No thread library; `vx-rt`'s globals are not thread-safe | `<vx/thread.h>`, per-thread state, `sched_ctx_*` implemented |
| Sleep by `futex_wait` on a word that never changes | `vx_sleep_until` |
| Environment parsed for musl only | `vx_env_get` over `/env` |
| `procfs` and `ptyd` speak POSIX signal numbers (`lib/vx-posix/posix.h`) | Native note names and `ctl` verbs (`stop`, `start`, `kill`) in `procfs`; signal numbers only in the POSIX back end |
| No `[[nodiscard]]`, no nil objects, no ABI version | As 04 §1.1 already requires; `VX_TARGET_ABI` with ADR-0004 |

The draft also found places where the documents and the code disagree, to settle when each call is written: `task_kill`'s argument order (ADR-0010 against `abi.h`), `port_bind`'s threshold and `port_wait`'s return type (01 §4.4), `channel_call`'s signature (01 §4.5), the syscall count (ADR-0010 says 61), pipes as rings in 01 §9 against channels in the code, badges in 01 §3 with no field to carry them, and `int main(void)` with `VX_FOREVER` in 03 §6's minimal program against `vx_main` and `VX_INFINITE` in the code. The minimal program should use `vx_main`.

## 10. Open questions

1. **Static or shared `libvx`.** Static linking keeps the ABI to syscalls and protocols and needs no loader; a shared `libvx` would let a fix reach every app without rebuilding, which 06's per-app packages make cheap anyway. 06 §16 question 8 asks the same of every library. Static is proposed.
2. **Syscall numbers or a vDSO entry table** as the stable boundary. Static programs that make syscalls directly freeze the numbers, as Linux does; calling through the vDSO page, as Windows calls through `ntdll`, lets numbers change but adds an indirect call. ADR-0004 decides.
3. **How much of the loop is in `libvx`.** Timers here are user-space bookkeeping over the port's deadline; a kernel timer object would be another syscall family. Start with bookkeeping.
4. **`vx_fd` or `vx_file *`.** Small integer ids match Plan 9 and the study's handle rule; pointers match the rest of `libvx`'s objects. Ids are proposed, because descriptors are passed between threads and stored in events.
5. **`vx_heap` at all.** Arenas and pools cover the system's own code; `hx`'s buffers and long-lived app data may not fit them. Measure with `hx` before adding it.
6. **Where the per-request cache flags live in 9Px:** new fields on `Tread` and `Twrite`, which every server must then parse, or a separate extension message.
