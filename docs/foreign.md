# Foreign applications: Windows games first, macOS later

A high-level design (2026-11-21, draft). It reviews how other systems
run Windows software, says what VectraOS should take from each and what
it should leave, and proposes a shape for a Windows personality aimed at
games. macOS applications come later, in the same shape (§9).

Nothing here is decided. §10 lists the decisions it needs, and §11 the
open questions.

## 1. Goal and scope

**Goal:** a person can install and play Windows games on VectraOS at
close to the frame rate the same machine gets on Windows. That excludes
games whose anti-cheat runs in the Windows kernel.

- **In scope:**
  - x86-64 Windows games, natively on amd64 (the AMD tower, V6c) and
    translated on arm64 (the Orange Pi 6 Plus).
  - Direct3D 9 to 12, DXGI, XInput, XAudio2 and WASAPI, and the
    launchers and runtimes those games need.
  - Games with no anti-cheat, and games whose anti-cheat runs in user
    mode and tolerates the layer (§6.8).
- **Later:**
  - 32-bit x86 games (§6.6).
  - macOS applications (§9).
- **Out of scope:**
  - Kernel-mode anti-cheat: Vanguard, Ricochet, FACEIT and the like.
    None of these run under any layer, Proton included.
  - Windows drivers.
  - Hosting a VM. That is already a non-goal (roadmap, "Out of scope"),
    and the kernel has no hypervisor (kernel rules, "Scope").
- **Not a native application:** a foreign program is a guest. The
  native rules in `docs/apps.md` govern VectraOS's own applications.
  This design governs how guests are hosted, and nothing native takes a
  Windows shape. That is D80's rule for POSIX, applied to Windows (§10).

## 2. The field

Each pattern below is assessed on three things: what it fixes, what it
costs, and what VectraOS should take from it.

### 2.1 Wine's original shape, and how it has been rebuilt

Wine began as a Win32 reimplementation on top of POSIX and X11. Most of
its work over the last five years has been undoing that start.

| Original pattern | Its cost | What replaced it |
|---|---|---|
| **wineserver:** one process holds every NT object, and each wait or signal is a round trip over a socket | Synchronisation-heavy games made thousands of round trips a second | esync (eventfds) and fsync (futexes, from out-of-tree kernel patches). Both broke NT semantics such as `PulseEvent` and wait-all, and some games misbehaved. Then **NTSync**, a Linux driver (6.14) that implements NT's objects in the kernel, used by Wine 11 (January 2026). It helps multi-threaded games most. |
| **Builtin DLLs as ELF libraries** that look like PE to the application | Copy protection, anti-cheat and debuggers that read PE images or walk modules saw something that wasn't Windows | **PE conversion:** every builtin DLL is now a real PE image. Host-specific code sits in a separate "unixlib", reached through one ioctl-shaped call (`__wine_unix_call`). A unixlib can't call back into PE code. |
| **Old WoW64:** 32-bit Windows programs need a full set of 32-bit host libraries | 32-bit Linux libraries are disappearing, and two library sets have to be maintained | **New WoW64**, complete in Wine 11: 32-bit code runs in a 64-bit process and is thunked to 64-bit `ntdll` at the syscall layer, as Windows does it |
| **X11 only** | Composition, scaling and frame pacing go through a second display server | A Wayland driver, on by default since Wine 10 |
| **Win32 file semantics over a case-sensitive file system** | Every lookup that misses needs a directory scan | Case-folded directories (ext4's casefold), which Proton relies on |

**Lesson:** each of these fixes pushed Wine's boundary down to the NT
system-call layer. That means real PE images above it, NT object
semantics in the host kernel, and a narrow call into host code. A
design that starts at that boundary skips ten years of rework.

### 2.2 Proton: Wine plus a graphics stack plus per-game data

- **DXVK** (Direct3D 8 to 11 → Vulkan) and **VKD3D-Proton** (Direct3D 12
  → Vulkan) do most of the work in modern games.
  - DXVK needs Vulkan 1.3, robustness2 with null descriptors,
    transform feedback (for D3D10 and 11's stream output) and the
    geometry shader feature.
  - Its wiki gives no support for mobile drivers.
- **The impedance cost of going through Vulkan:**
  - D3D12's descriptor heaps had no clean Vulkan equivalent for years.
    `VK_EXT_descriptor_buffer` was a partial answer.
  - `VK_EXT_descriptor_heap` (Vulkan 1.4.340, January 2026) was
    designed for this case. DXVK used it from February and VKD3D-Proton
    merged it in May, but it stays behind a flag while NVIDIA driver
    bugs are open.
  - Shader-compile stutter needed `VK_EXT_graphics_pipeline_library`
    and per-game shader caches.
  - The translation layer keeps waiting on API extensions and driver
    fixes it doesn't control.
- **Per-game configuration:** Proton carries quirks, environment
  overrides and media workarounds per game. Those are data, and a
  personality needs the same table.
- **Anti-cheat:** Easy Anti-Cheat and BattlEye run under Proton only
  through runtimes their vendors ship for it, enabled title by title.
  Valve does not support kernel-mode anti-cheat. EA's own anti-cheat
  blocks Linux.

**Lesson:** translate Direct3D to the GPU interface we own, not to a
general API that was designed for something else (§6.4). Per-game
quirks belong in data, not in code.

### 2.3 CPU translation

| System | Pattern | Notes |
|---|---|---|
| QEMU user mode | Whole-process emulation | Hangover 11 (January 2026) dropped it for FEX and Box64, which are faster |
| Box64 | Dynamic recompiler; calls to known host libraries are wrapped and run natively | The main engine in Android's Winlator and GameHub |
| **FEX** | Dynamic recompiler, built as **ARM64EC** for Wine | Valve funds it, and the Steam Frame (Snapdragon 8 Gen 3) runs Windows games through Proton plus FEX. In this mode only the application's code is translated; Wine runs natively. |
| **ARM64EC** (Windows 11, and Wine since 10.0) | An ARM64 ABI that is call-compatible with x64, so native and emulated code share a process without thunks | Wine requires 4 KiB pages for it, because the Windows ABI does |
| Rosetta 2 | Translation ahead of time, with a hardware TSO mode | The TSO mode is Apple silicon only |

**Memory ordering is the hard part.** x86 is TSO, and ARM is weakly
ordered.

- FEX's release notes say TSO emulation can cost close to 10x even with
  LSE, LSE2 and LRCPC. FEX recommends LRCPC-based TSO with the vector
  and memcpy TSO options off. In FEX 2404, memcpy rose from 2-3 GB/s to
  88 GB/s with TSO disabled.
- Unaligned atomics fault on ARM and have to be emulated. FEX reports
  16-byte split locks raising SIGBUS. One cited measurement puts a
  split-lock atomic at about 700 ns, against 1-2 ns within a cache
  line.

**Lesson:** translate only the game's own code. The personality's DLLs
are native code with an x64-compatible calling boundary (the ARM64EC
idea). Our arm64 baseline already includes RCpc (D53).

### 2.4 Library operating systems

- **Drawbridge** (Microsoft Research) ran Windows as a library OS
  inside a *picoprocess*: an address space with the OS's services
  removed and a closed set of 45 stateless downcalls to the host.
- **WSL1** turned the picoprocess into a *pico provider*: a kernel
  driver that receives every system call and exception from the
  process and emulates Linux inside the NT kernel. Microsoft replaced
  it with a VM (WSL2), largely over file-system performance. Linux's
  file semantics fit NT's I/O stack poorly.
- **Gramine** (formerly Graphene) keeps the library-OS shape over a
  narrow host ABI, and extends it to processes that cooperate.

**Lesson:** a personality lives in the guest's own address space as a
library, over a small and fixed host interface. WSL1 put the
personality in the kernel, which a microkernel rules out anyway. Its
experience also shows that the host's file semantics decide
file-system performance (§6.7).

### 2.5 Apple, and Android on ARM

- **Game Porting Toolkit** (CrossOver 26 bundles D3DMetal 3.0, and GPTK
  4 is in beta) translates Direct3D 12 straight to Metal, the platform's
  own API, with no Vulkan in between. That supports §6.4.
- **Winlator and GameHub** run Box64, Wine and DXVK on Android phones.
  - Mali GPUs need special handling: an OpenGL wrapper (Gladio),
    VirGL or WineD3D fallbacks, and forks such as WinlatorMali.
  - That points to driver gaps under DXVK's required feature set. The
    Orange Pi 6 Plus has a Mali G720, so this is a risk for us (§8).

### 2.6 What the review settles

1. **The boundary is NT's system-call layer.** Above it run real PE
   images: the game and our DLLs. Below it is the host. Wine took a
   decade to move there (§2.1).
2. **NT's object model should be the host's own** wherever the host has
   one. Emulating it over POSIX cost Wine wineserver, then esync and
   fsync, then a kernel driver. Our kernel is a Zircon descendant, and
   most NT objects map onto it directly (§3).
3. **Only application code is translated** (§2.3).
4. **Direct3D goes to the GPU interface we own** (§2.2, §2.5).
5. **Anti-cheat is a relationship with its vendor, not a feature.** The
   EAC and BattlEye runtimes for Proton are vendor builds for Linux, and
   none exists for VectraOS (§6.8).

## 3. Why VectraOS is a better host than POSIX

NT and Zircon descend from similar ideas: handles with rights, jobs,
sections, completion ports and a narrow system-call layer. Most of what
Wine emulates we already have as kernel objects.

| NT | VectraOS | Fit |
|---|---|---|
| Handles with access masks | Handles with rights | Direct; an access mask maps to a rights subset |
| Job objects, processes, threads | Jobs, processes, threads | Direct |
| Sections (file mappings) | VMOs, file-backed through the pager | Direct |
| `NtAllocateVirtualMemory` reserve and commit, `NtProtectVirtualMemory` | VMAR allocate (reserve), map a VMO (commit), protect | Direct; placement at fixed addresses and in the low 4 GiB by VMAR |
| I/O completion ports | Ports | Direct |
| `WaitOnAddress`, SRW locks, condition variables, critical sections | Futexes | Direct |
| `KUSER_SHARED_DATA` at `0x7FFE0000`, `QueryPerformanceCounter` | The shared read-only pages and the vDSO clock (K6c) | Direct; one page mapped read-only at a fixed address |
| TEB through GS (x64) or x18 (ARM64) | `REGISTER_GS` (amd64); on arm64 x18, see §11 | Partial |
| Events, mutants, semaphores; `WaitForMultipleObjects` with wait-all; mutant abandonment | Events were cut (D23); waiting on one object is a futex or a port wait | **Gap.** NTSync is the specification to meet: esync's and fsync's shortcuts broke games (§2.1, §6.2) |
| APCs and alertable waits | None | **Gap** |
| SEH, vectored handlers, guard pages | Exception channels, which carry an exception to a handler in another thread | **Gap for speed:** games and copy protection raise exceptions on hot paths, so delivery must happen in the faulting thread (§6.2) |
| `PAGE_EXECUTE_READWRITE` | No mapping is writable and executable outside a JIT reservation (kernel rules) | **Gap:** game JITs, LuaJIT, Mono and copy protection all ask for it (§6.2) |
| Files, overlapped I/O | The Node protocol and rings; completions into ports | Good; NT paths map onto a namespace (§6.7) |
| Winsock | `/net` through `dial`; overlapped sockets on rings | Good |
| Named objects (`\BaseNamedObjects`), the registry, window messages | None | Personality services (§6.3) |

The gaps are where the kernel work is. Each one needs a decision under
principle 1 that names what it replaces or why nothing does (§10).

## 4. Shape

```
  ┌──────────── foreign process (a picoprocess in a foreign job) ────────────┐
  │  game.exe, its DLLs           (x86-64: native on amd64, translated on     │
  │                                arm64; real PE images)                     │
  │  ─────────────────── Win32 subset, as PE images ───────────────────────   │
  │  kernel32/kernelbase, user32, gdi32 (minimal), dxgi, d3d9-12, xinput,     │
  │  xaudio2, mmdevapi, ws2_32, bcrypt, ole32/combase, ucrt …                 │
  │  ─────────────────── ntdll: the NT system-call layer ──────────────────   │
  │  Nt* implemented over Sys; no server in the common path                   │
  │  [arm64: the translator, in a JIT reservation, for the game's code only]  │
  └───────────────────────────────────┬──────────────────────────────────────┘
                     Sys calls, channels, rings, VMOs
  ┌───────────────────────────────────┴──────────────────────────────────────┐
  │  personality services: /svc/nt (named objects, registry, window          │
  │  messages across processes), the prefix on Taisce                         │
  │  Radharc (windows), kbdfs and the gamepad class (input),                  │
  │  the audio class (V9), GPUCore (D174)                                     │
  └──────────────────────────────────────────────────────────────────────────┘
```

**Working name:** *Fuinneog* (Irish, "window"), following the tree's
other names. It is a placeholder until a names decision (D12).

## 5. Principles for the personality

1. **Guest shapes stay in the guest.** NT's types, status codes and
   paths stop at `ntdll` and the personality's services. Sys, the Node
   protocol and native services never take them (D80's rule).
2. **The common path has no server.** A wait, a signal, a mapping or a
   file read is one or more Sys calls from the game's own thread. A
   service is involved only for state shared across processes.
3. **The Win32 surface is chosen by a corpus, not by the API's size.**
   Each DLL implements what a named set of games calls, measured by
   tracing those games on Windows, and nothing more. Each component has
   a line ceiling (principle 2).
4. **Per-game differences are data:** a table keyed by executable
   hash, like Proton's, read by the personality. There is no code per
   game.
5. **Every promise has a budget and a running check** (§7).

## 6. Components

### 6.1 Foreign processes and the system-call boundary

- A foreign program runs as a VectraOS process in a **foreign job**.
  The job's policy marks its processes as foreign.
- **Fast path:** the game calls our `ntdll`, which calls Sys directly.
- **Slow path:** some games and protection schemes issue raw NT system
  calls by number, which change from one Windows build to the next.
  - Under the foreign job's policy, a raw `syscall` (amd64) or `svc`
    (arm64) instruction outside the vDSO becomes an exception.
  - The personality's in-thread handler decodes it against the Windows
    build the prefix claims to be, and dispatches it.
  - This is our counterpart to Linux's Syscall User Dispatch, which
    Wine needs for the same games.
- **Loader:** a first-party PE/COFF loader, alongside `lib/elf`'s
  ElfImage. It lays out sections, applies relocations, binds imports
  and handles TLS callbacks, and it places images in the address space
  as Windows does. Some games depend on the address they get.

### 6.2 What the kernel must add for foreign processes

Each item needs a decision (§10). The rules for native processes stay
unchanged.

- **NT synchronisation objects.**
  - Events, mutants and semaphores, with wait-any, wait-all,
    abandonment and `PulseEvent`. NTSync's semantics are the
    specification.
  - Where they live is open: kernel objects, or a library over futexes
    and ports that is exact for one process and goes through a service
    across processes. Measure the library first, and make kernel
    objects only if it misses its budget.
- **In-thread exception delivery.** A fault in a foreign thread is
  delivered to a handler in that thread: a saved frame and a jump to a
  registered user address, as Windows' `KiUserExceptionDispatcher`
  works. A round trip through an exception channel to another thread
  is too slow. This also carries APCs and the slow path's system
  calls.
- **Writable-and-executable memory.**
  - A foreign process runs inside a JIT reservation, so its `RWX`
    requests are honoured there and nowhere else.
  - The alternative is to fault and flip each page between W and X,
    which copy protection that rewrites its own code makes very slow.
- **Address-space layout:** the null page reserved, images at their
  preferred bases where possible, and `KUSER_SHARED_DATA` at its fixed
  address. Low-4-GiB placement comes later, for 32-bit code.
- **4 KiB pages on arm64:** the Windows ABI requires them, as does
  Wine's ARM64EC (§2.3).

### 6.3 Personality services

- **`/svc/nt`**: named objects, NT's object namespace, and the registry
  (hives kept in the prefix).
- **Window messages across processes:** most games use one process, so
  most messages stay in-process.
- **The prefix:** a Taisce subtree per installation (§6.7).

### 6.4 Graphics: Direct3D on GPUCore

- **Direct3D goes to GPUCore (D174), not to Vulkan.**
  - GPUCore already has D3D12's shape: one bindless heap, a root
    pointer, stage-only barriers and timeline submission.
  - D3D12 descriptor heaps map to the bindless heap, and root
    signatures to the root pointer plus a small table it points to.
  - That avoids the decade Proton spent waiting on Vulkan for
    descriptor heaps (§2.2).
  - Direct3D 9 to 11 are layered on the same core, as DXVK layers them
    on Vulkan.
- **Shaders:** DXBC and DXIL feed the same compiler as SPIR-V (D174).
  That means a DXIL front end, or DXIL → SPIR-V first, which is
  simpler and costs one pass. Pipelines are compiled at load time, with
  a persistent per-game cache in the prefix to avoid stutter.
- **Features Mali lacks in hardware:** geometry shaders, stream output
  and some tessellation must be emulated in compute on tilers. This is
  the main graphics risk on the Orange Pi 6 Plus (§8).
- **Presentation:**
  - A DXGI swapchain's buffers are VMOs, handed to Radharc by
    ownership with no pixel copies.
  - Flip models and present intervals map to the frame intent (V9) and
    variable refresh.
- **Comparison baseline:** DXVK and VKD3D-Proton built as tier 1 ports
  over our Vulkan layer (D55 allows this for ports), for measuring only.

### 6.5 CPU translation on arm64

- **amd64 runs games natively.**
  - Our Ivy Bridge baseline (D52) governs our code, not the game's.
  - A game that needs AVX2 runs on a CPU that has it. The Mac Pro
    (Ivy Bridge) can't run such games.
- **On arm64, a first-party x86-64 → arm64 translator**, in the
  ARM64EC shape:
  - The game's code is translated. Our DLLs are native arm64 code with
    an x64-compatible boundary.
  - The boundary is either the ARM64EC ABI itself, if our toolchain
    can emit it (LLVM has the triple; Embedded Swift's support is
    unknown), or generated thunks per export.
- **Translation:** a dynamic recompiler with a persistent code cache in
  the prefix, and ahead-of-time translation of hot images later (the
  Rosetta idea, without the hardware TSO bit).
  - This is the first on-device JIT. Architecture §2 requires a
    decision for that.
- **Memory ordering:**
  - LRCPC loads for TSO (the A720 has LRCPC2).
  - Per-game options in the quirk table to relax ordering where a game
    tolerates it.
  - Split-lock and unaligned-atomic emulation, reported as a budget,
    because those are where the 700 ns cases live (§2.3).
- **SIMD:**
  - SSE through AVX2 onto NEON and SVE2. The A720's SVE is 128 bits
    wide, so 256-bit AVX is split.
  - AVX-512 is out.

### 6.6 32-bit games (later)

32-bit games follow Wine 11's new WoW64 pattern.

- 32-bit code runs in the low 4 GiB of a 64-bit process.
- It is thunked to 64-bit `ntdll` at the system-call layer.
- There is no second set of DLLs below that layer.

Many older games are 32-bit, so this matters for the catalogue but not
for the first exit.

### 6.7 Files and the prefix

- **A prefix is a Taisce subtree** per installation.
  - Drive letters and NT paths are bindings in the foreign process's
    namespace.
  - Taisce's S2 snapshots (D153) give rollback before an update, and
    cheap copies for testing.
- **Case-insensitive lookup:** Win32 assumes it.
  - Taisce already case-folds its caseless keys (provenance.md, the
    Unicode tables), so a per-directory case-folded name index may be
    cheap.
  - It is a change to Taisce, so it needs a decision.
  - WSL1 is the warning: the host's file semantics decide performance
    (§2.4).
- **Overlapped I/O** goes on rings, with completions to the port the
  game bound.

### 6.8 Anti-cheat, DRM and storefronts

- **Anti-cheat:**
  - Games with none: the main target.
  - Games whose user-mode anti-cheat accepts the layer when it runs its
    Windows path: case by case, recorded in the quirk table.
  - EAC and BattlEye support under Proton comes from Linux runtimes
    that their vendors build. There is no VectraOS build of either, and
    there won't be without the vendors.
  - Kernel anti-cheat: never.
- **DRM:** Steam's DRM and Denuvo run under Proton. They need the
  in-thread exceptions and the `RWX` memory of §6.2.
- **Storefronts:**
  - GOG's offline installers are the first target: no client and no
    online check.
  - Steam games need the Steam client running, because
    `steam_api64.dll` talks to it, and the Windows client embeds
    Chromium (CEF).
  - That is foreign code inside a guest, not a web runtime of ours, so
    `docs/apps.md` doesn't forbid it. It is still the largest single
    compatibility target in this design (§11).

### 6.9 Input, audio and windows

- **Windows:** a top-level HWND becomes a Radharc window
  (`/svc/windows`). Exclusive fullscreen becomes a fullscreen surface
  at the output's mode (D147).
- **Input:** keyboard and mouse from kbdfs and Radharc. Raw input and
  pointer lock are needed. XInput and DirectInput go to V9's gamepad
  class.
- **Audio:** WASAPI and XAudio2 feed V9's audio class through a ring.

## 7. Budgets and checks

Each budget lands with its check and a milestone (`docs/performance.md`).
These are proposals, to be set from first measurements.

| Budget | Check |
|---|---|
| `nt.wait_signal`: an NT event signalled and woken across two threads | A suite in `user/test/swift/`, through `ntdll` |
| `nt.syscall_slow_path`: a raw system call through in-thread dispatch | The same suite |
| `nt.exception_dispatch`: a guarded-page fault to a vectored handler and back | The same suite |
| `game.frame_ratio`: frame time against Windows on the same machine | The AMD tower, dual-booted; a fixed corpus and fixed scenes |
| `x86.translate_ratio`: a CPU benchmark translated on arm64 against the same benchmark built for arm64 | The Orange Pi 6 Plus |
| `x86.split_lock_count`: split-lock and unaligned-atomic emulations per frame | Reported by the translator |
| `d3d.pipeline_stall`: frames over budget from pipeline compilation, cold and warm cache | The corpus |
| Line ceilings per DLL and per service | `vx loc` |

**Conformance** is a corpus of games, each rated on ProtonDB's scale. A
test suite of small Win32 programs, checked against Windows' own
results, runs as Embedded Swift suites driving foreign processes in
QEMU (D20, D88).

## 8. Risks

- **Size.** Even the game subset of Win32 is large. Wine is millions of
  lines, most of them Win32 surface that games never call. Corpus
  tracing (§5, rule 3) is what keeps the subset bounded, and it must
  come first.
- **Mali.** DXVK's feature set and Winlator's workarounds on Mali point
  to real gaps: geometry shaders, stream output, robustness. Emulating
  them in compute on a tiler may miss frame budgets on D3D11 games.
- **Memory ordering on arm64.** Without a hardware TSO mode, some games
  will be slower translated than the board's CPU suggests.
- **Media.** Cutscenes through Media Foundation are a long-running
  Proton problem. V14's decoders help, but Media Foundation's surface
  is large.
- **.NET Framework and XNA games.** These need a CLR. Out of scope at
  first; Unity games carry their own Mono and are fine.

## 9. Growing to macOS

The same shape carries over. Only the guest side changes.

| Piece | Windows | macOS |
|---|---|---|
| Image and loader | PE/COFF loader | Mach-O loader and dyld's binding |
| System-call layer | `ntdll` over Sys | libSystem and XNU's BSD and Mach traps over Sys |
| IPC | Named objects, completion ports | Mach ports map closely to channels and ports |
| Graphics | Direct3D → GPUCore | Metal → GPUCore; the closest fit of all, since Loinnir follows Metal's defaults (D55) |
| CPU | x86-64 translated on arm64 | arm64 native on our boards; x86-64 Mac software is out |
| Toolkit | user32 (small) | AppKit, which is large; games use little of it |

- **Shared:** foreign jobs and their policy, in-thread exceptions, the
  prefix on Taisce, presentation to Radharc, the input and audio
  bindings, and the quirk table.
- **The field:** Darling, the only open macOS layer, runs command-line
  programs and has very limited GUI support (2026).
- **Apple's frameworks can't be redistributed,** so everything above
  libSystem would be first-party.
- **Recommendation:** design the shared pieces so a second personality
  fits, and start no macOS work until the Windows layer passes its
  exit. Most Mac games also ship Windows builds.

## 10. Decisions this needs

Each would be a new entry in `docs/decisions/` before work starts.

1. **D4 and guests.** D4 says everything that executes on the device is
   first-party, and D55 lets ports such as DXVK run as tier 1 programs.
   A game is third-party code by definition. The decision should
   settle three things:
   - Guests are not "the system".
   - The personality itself is first-party, written clean-room.
   - Wine, DXVK, VKD3D-Proton and FEX may be built as tier 1 ports for
     comparison only, never shipped.
2. **Provenance.** The sources are:
   - Microsoft's public documentation, the PE/COFF specification, and
     the D3D functional specifications and DXIL documentation Microsoft
     publishes.
   - Behaviour measured on Windows.
   - Never Windows source.
   - Whether Wine's source may be read directly, or only through specs
     written by someone else (the chinese-wall pattern V6f uses), is
     the owner's call.
3. **Foreign processes as guests under D80's rule:** NT shapes in
   nothing native.
4. **The foreign job policy:** raw system calls become exceptions.
5. **In-thread exception delivery** for foreign processes.
6. **NT synchronisation objects:** library first, kernel objects only
   if the library misses its budget.
7. **`RWX` inside a JIT reservation** for foreign processes.
8. **The first on-device JIT:** the x86 translator (architecture §2).
9. **Case-insensitive directories in Taisce.**
10. **Direct3D → GPUCore** rather than → Vulkan.
11. **The milestone and its place:**
    - After V9, which brings audio, gamepads and the frame intent.
    - Steps:
      - W1: the PE loader, `ntdll` and console programs in QEMU.
      - W2: windows, input and D3D11 on the AMD tower.
      - W3: D3D12.
      - W4: x86-64 on the Orange Pi 6 Plus.
      - W5: 32-bit code.
    - The exit: a named corpus playable at `game.frame_ratio`.
12. **Names** (D12).

## 11. Open questions

- **x18 on arm64.** Windows ARM64 keeps the TEB in x18. Does our arm64
  user ABI reserve x18, or does anything we build use it (a shadow call
  stack, for example)?
- **The ARM64EC ABI from our toolchain.** Can Embedded Swift emit it,
  or do the DLLs' exports need generated thunks? Either way, the DLLs'
  exports use the Microsoft x64 calling convention, so the export layer
  may be C23 under D1's rule.
- **Steam.** Do we host the Windows Steam client (Chromium in a guest)
  in the first exit, or start from storefronts without a client?
- **The corpus.** Which twenty games define W2's exit? The choice
  should span D3D9, D3D11 and D3D12, Unity, Unreal and in-house
  engines, and include a few user-mode anti-cheat titles.
- **Windows as a test oracle.** Our Win32 conformance programs need a
  Windows machine to set expected results. The AMD tower dual-booted is
  the natural one.

## Sources

Retrieved 2026-11-21.

- Wine 11.0: [announcement](https://raw.githubusercontent.com/wine-mirror/wine/wine-11.0/ANNOUNCE.md), [Help Net Security](https://www.helpnetsecurity.com/2026/01/14/wine-11-released/), [heise](https://heise.de/-11140791), [Phoronix](https://phoronix.com/news/wine-11.0-tomorrow)
- Wine 10.0 and ARM64EC: [WineHQ announcement](https://list.winehq.org/mailman3/hyperkitty/list/wine-announce@winehq.org/2025/1), [The Register](https://www.theregister.com/2025/01/24/wine_turns_10), [Hangover 11.0 (Phoronix)](https://phoronix.com/news/hangover-11.0-released)
- Wine's PE and Unix split: [wine-devel, "PE Conversion", 2021](https://www.winehq.org/pipermail/wine-devel/2021-August/193183.html)
- wineserver, esync, fsync and NTSync: [wine-devel, "Optimizing synchronization primitives, again"](https://list.winehq.org/archives/list/wine-devel@list.winehq.org/thread/J5BVY7YV553VRXIQWP3AFROQAE52QC7U), [GamingOnLinux on NTSync in 6.14](https://www.gamingonlinux.com/2025/01/ntsync-driver-for-improving-windows-games-on-linux-with-wine-proton-should-finally-land-in-linux-kernel-614/page=1/)
- Descriptor heaps: [VK_EXT_descriptor_heap proposal](https://docs.vulkan.org/features/latest/features/proposals/VK_EXT_descriptor_heap.html), [VKD3D-Proton merge (Phoronix)](https://phoronix.com/news/vkd3d-proton-descriptor-heaps), [RADV (Phoronix)](https://phoronix.com/news/radv-merges-descriptor-heap), [Vulkan 1.4.340 (GamingOnLinux)](https://gamingonlinux.com/2026/01/vulkan-1-4-340-released-with-new-extension-to-improve-directx-performance-on-linux)
- DXVK's requirements: [DXVK wiki, Driver support](https://github.com/doitsujin/dxvk/wiki/Driver-support)
- Steam Frame, FEX and Lepton: [Steamworks, Steam Frame compatibility](https://partner.steamgames.com/doc/steamhardware/steamframe/compatibility), [GamingOnLinux](https://gamingonlinux.com/2026/01/valves-documentation-highlights-the-different-ways-standalone-games-run-on-steam-frame), [PC Gamer](https://www.pcgamer.com/hardware/vr-hardware/steamos-launching-for-arm-fex-translation-layer)
- FEX and memory ordering: [FEX 2404](https://fex-emu.com/FEX-2404/), [FEX 2604](https://fex-emu.com/FEX-2604/), [FEX 2605](https://fex-emu.com/FEX-2605), [Phoronix on FEX 2404](https://Phoronix.com/news/FEX-Emulator-2404), [LKML, unaligned atomics, January 2026](https://lkml.iu.edu/hypermail/linux/kernel/2601.2/05692.html)
- Anti-cheat: [Steamworks, Proton](https://partner.steamgames.com/doc/steamhardware/proton), [GamingOnLinux anti-cheat guide](https://www.gamingonlinux.com/guides/view/anticheat-check-which-competitive-games-actually-work-on-linux-steamos/)
- Library operating systems: [Drawbridge (Microsoft Research)](https://www.microsoft.com/research/project/drawbridge/), [Drawbridge paper](https://web.eecs.umich.edu/~ryanph/jhu/cs718/spring18/readings/drawbridge.pdf), [WSL pico processes](https://learn.microsoft.com/archive/blogs/wsl/pico-process-overview), [Graphene paper](https://www.cs.unc.edu/~porter/pubs/tsai14graphene.pdf)
- Apple: [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit), [CrossOver and GPTK 3](https://mybyways.com/blog/updating-crossover-to-gameporting-toolkit-3-0)
- Android on ARM: [Winlator 11 (Android Authority)](https://www.androidauthority.com/winlator-v11-stable-release-android-pc-emulator-3657643/), [winlator_mali](https://github.com/ar37-rs/winlator_mali)
- Darling: [project site](https://darlinghq.org/), [Phoronix, November 2026](https://phoronix.com/news/Darling-Using-AI-macOS-Linux), [Open Collective](https://opencollective.com/darlinghq)
