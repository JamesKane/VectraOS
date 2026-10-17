# Plug-ins and hot reload

A vision and high-level design (2026-10-17, proposed; D92). Principle 23
says debugging and hot reload are OS services. This document carries
todhchai's and NeoVectra's goals for them into VectraOS: a program's own
code swapped while it runs, and other people's code extending a program,
both written in Swift or any language that compiles to our formats, and
neither needing an embedded scripting language such as Lua.

The sources are todhchai's principles 17 and 27, `architecture.md` §16
and `sdk.md` §11 (`CodeModule`), and NeoVectra's `03-desktop-agentic.md`
§6.1, `01-kernel-ipc.md` §6.6 and §7.4, ADR-0043 (seals and leases),
ADR-0047 and ADR-0056 (the loader and code images). §10 says what is
taken from each.

## 1. Two jobs, one loader, one rule

There are two different jobs, and both earlier projects kept them
apart:

| | Hot reload | A plug-in |
|---|---|---|
| Whose code | the program's own | someone else's, extending a host |
| Where it runs | in the program's process | in its own process |
| Why there | it shares the program's state and loop, and its author trusts it | a crash or a bug takes nothing of the host with it |
| How it is swapped | a fresh code image mapped beside the old one | a new process started, the old one quiesced |
| How it shares data | a state block at a fixed address | VMOs: lent read-only in, sealed out |

The rule that separates them is todhchai's principle 27: **no foreign
code runs in another program's process.** A program may reload its own
code in itself; anything else that extends it runs beside it, confined
by its own namespace.

Both use one loader, `system/ld` (V2's dlopen), and both take code
built by any compiler that produces our ELF for the `*-vectraos` triple
(§4). There is no plug-in runtime, no bytecode VM inside hosts, and no
Lua (NeoVectra's Lua is dropped, D4 and provenance): rc is the scripting
language, over files, and compiled code is the extension language.

## 2. Hot reload: a program's own code

After Handmade Hero's live code editing (day 21), as todhchai's
`CodeModule` and NeoVectra's `app.so` host both did it.

### 2.1 The split

- During development a program builds as a **small host** and a **code
  image**, a shared object exporting one entry point (`update(state,
  events)`, a frame's or a request's worth of work). The host is the
  program's own code too, a short template it owns, so the program still
  owns its loop (principle 20).
- **All of the program's mutable state lives in one state block**, a VMO
  mapped at the same address on every run in a VMAR reservation
  (`vmar_allocate` with `CROI_VM_SPECIFIC`). Pointers inside it stay
  valid across reloads, and across runs when the block is kept.
- **Release builds** link the image into the host and don't reload. The
  fixed address costs nothing either way.

### 2.2 Reloading

- The build writes the new image to a temporary name and renames it into
  place, so the host never sees half a file. The host watches the file
  (Node's `watch`; on Taisce, a live query), finishes its current frame or
  request, maps the new image and calls into it.
- **Each load maps a fresh copy at a new address,** copied into new
  memory rather than mapped from the file's pages, so a rename over the
  path leaves the running image as it was (NeoVectra ADR-0056 item 4).
- **Old images are never unmapped.** A string, a function pointer or a
  constant table that the state still points at stays valid, which
  removes Handmade Hero's classic reload crash. It is also what
  `system/ld` already requires: a Swift library mustn't be unloaded
  (`system/ld/native/Linker.swift`). A long session costs a few
  megabytes, reported in `/proc/N`.
- **The state block declares its layout.** The image exports its state
  type's size and a layout hash; when they differ from the block's, the
  host calls the image's `migrate` if it has one, and otherwise refuses
  the reload and says why, rather than running new code over old
  bytes.
- **In Swift, the state is data.** Its type is `BitwiseCopyable`: no
  class references, closures or existentials, whose metadata would point
  into an old image and run old code. Tier 0's style already is this. A
  macro (`@HotState`) checks it at compile time and emits the layout
  hash.

### 2.3 What it brings with it

- **Record and replay:** a thread waits on one port for everything
  (principle 9), so snapshotting the state block and recording what the
  port delivered replays a session exactly while the code changes under
  it. Time comes from the events, never from the clock directly.
  GPU memory, windows and open files are not in the snapshot; a program
  that keeps state in them rebuilds it from the block.
- **The debugger and the trace:** each image is a map event in
  `/proc/N` and the trace, and breakpoints are kept by source line
  across images.
- **Remote:** a program on a board reloads from the developer's host
  exactly as locally: `vx` builds, and the image lands through the cpu
  session's `/mnt/term` (D77) or a 9gate mount, then is renamed into
  place.

## 3. Plug-ins: extending a host

### 3.1 A plug-in is a process

- **A host offers plug-in points,** each a typed interface declared in
  the IDL (`@IPCLibrary`, idlc) and documented in the host's manual page
  and `.schema`. Examples in §6.
- **A plug-in is a program** that serves or calls that interface. The
  host starts it (or the launcher does, from the plug-in's manifest),
  with a **sealed namespace** (architecture §4): what the manifest names
  and the host lends, and nothing else. A plug-in that crashes takes
  nothing of the host with it, and the host carries on with its default.
- **Control goes over the interface's channel; bulk goes on rings**
  (principle 5), so an audio effect or an image filter costs no syscall
  per block while both sides are busy (the ring's `ring.kicks = 0`).
- **Shared structures cost no serialisation** (NeoVectra 01 §6.6): the
  host builds its input in a VMO and lends it without WRITE; the plug-in
  builds its result in a VMO and seals it before sending, and the host
  checks each offset against the bounds once. A view lent for one call
  ends with the call, however the plug-in fails.
- **Deadlines carry across:** a plug-in on a realtime path runs on a
  scheduling context the host's deadline is donated to (K3), so an audio
  host's effect chain is admitted as one budget.

### 3.2 Replacing a plug-in while it runs

NeoVectra's live update (01 §7.4), for every plug-in point:
- the host starts the new version beside the old one;
- the old one quiesces: finishes what's in flight, refuses new work, and
  optionally writes its state to a handoff VMO;
- the host moves to the new one, which reads the handoff, and the old one
  exits.

During development, the plug-in's own code can also hot reload inside its
process (§2), so a plug-in author edits and sees the change without the
host noticing anything at all.

### 3.3 Why not in-process plug-ins

A shared library loaded into a host is the faster call, and the wrong
default: it shares the host's address space, its crashes, its
allocator, its ABI, and its toolchain version. A process costs one
channel round trip on a control path (`ipc.channel_call`, a budget
already) and nothing per item on a ring. Where that is too much, the
answer is a ring, not a library. §11 asks whether any host is the
exception.

## 4. Any language

The contract of a plug-in is an IDL interface over the wire format and
rings, so it doesn't care what the plug-in is written in. The contract
of a hot-reloaded image is the C ABI of its entry point and its state
block. What builds either:

| Language | How | Notes |
|---|---|---|
| Embedded Swift (tier 0) | the stock 6.4 toolchain | for plug-ins on real-time paths |
| Swift (tier 1) | the `*-vectraos` toolchain (D47) | the expected case; `@IPCLibrary` stubs |
| C, C++ | the same toolchain's clang | idlc's C headers |
| Other LLVM languages (Rust, Zig, ...) | their front end for `*-unknown-vectraos` | needs each language's target definition; not ours to ship |
| Anything with a Wasm target | `wasmd` (D7, V9): a Wasm plug-in is a process like any other | portable across arches, one artifact for amd64, arm64 and rv64 |

- **Wasm isn't a second plug-in mechanism.** A Wasm plug-in is a `wasmd`
  process speaking the same interface over WASI's mapping onto nodes and
  rings (D80's rule); the host can't tell it from a native one.
- **Plug-ins never need Swift's ABI to be stable.** The interface is the
  wire format. Hot reload doesn't either: the host and its image are
  built by the same toolchain from the same tree.
- **Scripting is rc,** over the host's files and verbs, as Plan 9's is.
  A host doesn't embed an interpreter; a user who wants logic writes a
  script against its node tree, or a plug-in.

## 5. Where code is compiled

D4 keeps compilers off the device: LLVM and the Swift toolchain run on
the developer's host and produce our formats (D47). So:

- **The edit-build-reload loop runs from a host.** `vx` builds the image
  or the plug-in, and the result reaches the device over the cpu session
  or a 9gate mount (§2.3). In QEMU this is the same path.
- **A swarm node can be the build host** for a machine that has none:
  any machine running `vx` (Linux, macOS, later the AMD tower) serves it
  over 9gate (V7).
- **Building on the device itself** would mean a compiler on the device:
  either a toolchain the user installs as their own program (which D4,
  written for what VectraOS ships, doesn't yet address) or a first-party
  compiler. It is §11's first question, not part of this design.

## 6. Plug-in points in VectraOS

Each host offers its points as interfaces in its manual page. Proposed:

| Host | Point | Today |
|---|---|---|
| Radharc | layout policies for `tile` (D9) | plug-in processes from V5 (architecture §7), since a layout runs on events, not per frame |
| Tracker | actions on a file type, column providers | none |
| Taisce's indexer | translators: extract attributes and text from a type (Spotlight's importers, Be's translators) | none |
| The audio service | effects and instruments on its rings | none |
| The plumber | handlers (D85) | already processes: `plumb client` |
| devmgr | drivers | already processes, restarted and live-updated |
| The Ghost (D90) | tools and runners | already processes |
| The editor (later) | language services | processes over files, as NeoVectra's `hx` planned |

The rows marked "already processes" show the rule isn't new: plug-ins
are how VectraOS already extends itself; this design names it and gives
every host the same shape.

## 7. Authority

- **A plug-in is installed by copying a file** (principle 24): an ELF
  or a Wasm module with a manifest naming its host, its point, and what
  its namespace needs. The user grants that as they grant an app's.
- **The host lends; it never gives.** What a plug-in sees of the host's
  data is what the host lent for the call, and leases end with it.
- **A plug-in's identity** is in `/proc/N` and the trace as its own
  program, so the Ghost's insights and the debugger name the plug-in,
  not the host, when it misbehaves.
- **Hot reload loads only the program's own images,** from paths in its
  own namespace; a program can't be made to load an image by anyone who
  can't already write its files.

## 8. Budgets

todhchai's budget is the starting point (`performance.md`: hot reload
of a 10K-line module under 1 s):

| Budget | Target | Check |
|---|---|---|
| `reload.module_10k` | save to the new code running under 1 s for a 10K-line Swift module, building on the host, in QEMU and over the LAN | reference program, `vx bench` |
| `reload.map` | mapping and binding a reloaded image, on the device | self-test |
| `reload.frames_missed` | 0 frames missed by a reload at the frame boundary | reference game |
| `plugin.replace` | 0 dropped blocks or frames while a plug-in is replaced | audio and layout self-tests |
| `plugin.call` | a control call to a plug-in, which is `ipc.channel_call` | existing |
| `reload.retained` | memory held by old images, reported per process | `/proc/N` |

## 9. What to build, and when

- **`system/ld`, before V5 builds on it:** opening a fresh copy at a
  new address, copied, never unmapped, binding against what's loaded
  (NeoVectra ADR-0056 item 4); and TLS in
  loaded objects, which `Dynamic.swift` refuses today and a full Swift
  image may need.
- **V3:** nothing new; its cpu session is the remote reload path.
- **V5, with the SDK:** the host template, the state block and
  `@HotState`, and the SDK's reference app hot reloading; Radharc's
  layout policies as the first plug-in point.
- **V9, with games:** record and replay, and the exit todhchai set for
  M7: a game on Loinnir runs with hot reload, within `reload.module_10k`.
  Wasm plug-ins come with `wasmd`.

## 10. What we take, and how it changes

| Source | Here | Why |
|---|---|---|
| todhchai principle 17, `CodeModule` | §2 | the goal, unchanged |
| todhchai principle 27 (intents, not plug-ins) | the rule of §1, and the plumber for intents (D85) | no foreign code in a host |
| NeoVectra `app.so` host, fresh images, old ones kept (03 §6.1, ADR-0056) | §2.2 | the details that make reload safe |
| NeoVectra plug-ins as processes, seals and leases (01 §6.6, ADR-0043) | §3.1 | crash isolation without serialising |
| NeoVectra live update (01 §7.4) | §3.2 | one way to replace any running server |
| NeoVectra Lua (ADR-0015) | dropped | D4; rc is the scripting language, compiled code the extension language |
| architecture §7's in-process layout libraries | plug-in processes | §6; changed in architecture §7 with this decision |

## 11. Open questions

1. **Compiling on the device.** Does D4 allow a user to install the
   `*-vectraos` toolchain as their own program, on a machine large
   enough, so the whole loop runs on VectraOS? Or is the build host
   always another machine, or a first-party compiler someday?
2. **Is any host the exception to §1?** Realtime audio at very small
   buffers, where even a ring handoff per block might miss; measured in
   V9 before anything in-process is allowed.
3. **Migrating state.** Is a `migrate` entry point enough, or does
   `@HotState` generate field-by-field migrations from two layouts?
4. **TLS in code images:** needed for full Swift images, or is a hot
   image restricted to code without thread-locals, as NeoVectra's was?
5. **Other languages' targets.** Do we upstream a `*-vectraos` target
   for Rust and Zig, or document what a front end needs and leave it to
   their communities?
