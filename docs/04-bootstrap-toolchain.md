# Phase 4 — Bootstrapping, toolchain and the first three milestones

_Blueprint v0, 2026-09-30._

## 1. Language policy

| Language | Where | Rule |
|---|---|---|
| **C23** | Everything first-party: kernel, `abi`, libraries, servers, drivers, commands, the `build` tool, host tools | clang, `-std=c23`, the house subset in §1.1 |
| **Assembly** | Entry points, context switch, exception vectors | `kernel/arch/` and `vx-rt` only, assembled by clang's integrated assembler |
| **C (vendored)** | Limine, musl, Lua, Monocypher, ACPICA, kb_text_shape, stb_truetype; later Zydis and one TLS 1.3 library (00 D16) | Built by clang + lld from `ports/`, driven by `build`; never linked into the kernel |
| **C++ (vendored)** | Later, and only where there is no C alternative: Mesa's C++ parts (such as RADV's ACO compiler) and llama.cpp | The same rules as C imports. Each C++ import says in its ADR why no C alternative exists |
| **Odin and others** | Applications, through `vxui.h` and the POSIX layer | Community tier; never in the base system |
| **Lua** | `wm` layout policies, scripts and scripted UIs. Settings are ndb data, not Lua (D14) | Vendored Lua 5.4 |

`gsh`, the system shell, is first-party C with `rc`-style syntax: lists, `{}` blocks and no word-splitting surprises. Namespace built-ins (`bind`, `mount`, `ns`) are part of it.

### 1.1 The house subset

The rules below govern the OS tree: the kernel, libraries, servers, drivers, commands and `build`. They are enforced by warnings-as-errors, the clang static analyzer, `clang-tidy` and review, all run by `./build check`. `.clang-tidy` turns on the check families that apply to C (bugprone, CERT, concurrency, misc, performance, portability, readability), makes every finding an error, and gives the reason for each check it leaves out. Applications, including those written against `vxui.h`, build with whatever flags and style their authors choose.

- **Flags everywhere:** `-std=c23 -Wall -Wextra -Werror -Wshadow -Wvla -Wimplicit-fallthrough -fno-strict-aliasing -ftrivial-auto-var-init=zero -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer`, and `--build-id` at link time. Debug information and frame pointers are always on (05 §4), in leaf functions too, so a backtrace from a fault in a leaf does not skip its caller.
- **C23 features we use:**
  - `constexpr`, `typeof`, `nullptr`, `bool` and `static_assert` as keywords;
  - enums with a fixed underlying type, for every ABI field;
  - `[[nodiscard]]` on syscall wrappers and on every status-returning function in the kernel and on authorization paths. Elsewhere, nil objects and sticky errors let a caller check once (below), and `[[nodiscard]]` would demand a check after every call;
  - checked arithmetic from `<stdckdint.h>`;
  - `#embed` for boot assets.
- **Memory:**
  - The kernel has no general-purpose allocator. Objects come from per-type pools, and every pool is charged to a budget (01 §5).
  - User space uses arenas (per request, per frame, per session). `malloc` exists for POSIX ports, not for first-party code.
- **Data across a boundary:**
  - Handles with generation counters, never pointers.
  - Length-carrying slices (`vx_str`, `vx_bytes`) instead of NUL-terminated strings. NUL-terminated strings appear only at the POSIX boundary.
  - Every size, offset or count that arrives from another task goes through `ckd_add` or `ckd_mul` before use.
- **No VLAs, and no recursion in the kernel,** so stack depth is bounded and can be checked.
- **Zero is initialisation.** Every struct is designed so that all zeroes is a valid, ready-to-use value: an empty arena, an empty slice, a closed handle. `-ftrivial-auto-var-init=zero` then makes a forgotten initialiser harmless, not just defined.
- **Nil objects, not `NULL`.** A function that returns an object returns a pointer to a static, read-only *nil* object on failure, never `NULL`. Calls on a nil object do nothing and return nil, zero or `VX_ERR_NIL`, and the error is kept in a sticky field (03 §6). Callers check once, where it matters, instead of after every call.
  - A nil object's status is **never zero.** `VX_OK` is zero, so a nil that returned zero would report success, and a rights check or a seal on a failed handle would silently pass.
  - The kernel and every authorization path do not use nil objects at all. They check each status explicitly, and `[[nodiscard]]` makes the compiler insist.
- **Macros stay small,** and hide no control flow. The one exception is the X-macro table.
- **One table, one truth.** A list that several places must agree on is one X-macro table in a `.def` header. That covers syscall numbers, rights, ring opcodes, 9Px messages, and each server's `ctl` verbs and file keys. The enum, the dispatch switch, the argument parser and the `.schema` text a server serves (which is also what `dbg` decodes with) all expand from the same table. Nothing is kept in sync by hand.
- **Unity builds.** Each component is one translation unit; `kernel/kernel.c` includes every other kernel `.c` file. There are no header dependency graphs to track.
- **Internal linkage by default.** File-scope constants are `static constexpr`: unlike C++, C gives a file-scope `constexpr` object external linkage. Functions and objects are `static` unless something outside C reaches them by name (the bootloader, assembly, the linker script or the compiler, as with `memset` and `__stack_chk_fail`), and those few are declared in a header that says why (`kernel/entry.h`, `lib/vx-rt/rt.h`, `lib/vx-mem/mem.h`).
- **One format:** K&R, two-space indents, and every opening brace on the same line as its statement or declaration, function bodies included. `.clang-format` at the root encodes it, and `./build check` fails on any first-party C file it would change. Vendored code keeps its upstream format.

### 1.2 The safety net is tooling

Rust's guarantees stop at `unsafe`. The core of a kernel is unsafe by definition: page tables, context switches, MMIO, DMA and the ring memory ordering (D1). So VectraOS gets its safety from a small kernel and from tooling that covers all of the code:

- **Sanitizers:** host builds of every library run their tests under ASan and UBSan. The debug kernel is built with `-fsanitize=undefined -fsanitize-trap=undefined`, which needs no runtime. A kernel address sanitizer with a first-party shadow-memory runtime comes later.
- **Control-flow integrity:** `-fsanitize=kcfi` in the kernel. `-fcf-protection=full` on x86_64 and `-mbranch-protection=standard` on aarch64 everywhere.
- **Static analysis:** the clang static analyzer and `clang-tidy` run on every change.
- **Fuzzing and model checking:** see §7.

## 2. Repository layout

```
NeoVectra/
├── build.c                     the build tool: `cc -o build build.c` once, then `./build …` (§3.2)
├── abi/                        vx/abi.h: syscall numbers, rights, packets, ring layout; shared by kernel and user space
├── kernel/
│   ├── kernel.c                the unity-build root
│   ├── arch/x86_64/            gdt, idt, apic, tsc, paging, syscall entry, smp (.c and .S)
│   ├── arch/aarch64/           vectors, gicv3, generic timer, paging, svc entry, psci (.c and .S)
│   ├── mm/                     phys (buddy), vmo, aspace, pager
│   ├── sched/                  sched contexts, run queues, intents
│   ├── obj/                    task thread port counter channel ring irq dma resource
│   ├── syscall/                dispatch table, argument validation
│   └── linker/{x86_64,aarch64}.ld
├── lib/
│   ├── vx-rt/                  user runtime: _start, syscall stubs, arenas, panic, ELF loader
│   ├── vx-ring/                SPSC queue pair; host-testable
│   ├── vx-9p/                  9Px codec, client and server framework; builds for the target AND the Linux host
│   ├── vx-ns/                  libns: mount table, resolution, templates
│   ├── vx-buffer/              vx_buffer, vx_buffer_desc, timeline helpers
│   ├── vx-driver/              MMIO register accessors, DMA pools, IRQ glue, class-protocol skeletons
│   ├── vx-ndb/                 ndb record parser and writer (02 §4.1); host and target
│   ├── vx-tar/                 the boot image's ustar reader and deterministic writer; host and target
│   ├── vx-net/                 first-party TCP/IP (used by netd)
│   ├── vx-debug/               DWARF index, unwinder, expression evaluator, aarch64 disassembler (05 §11)
│   ├── vx-prof/                profiling zones and sample decoding (05 §9)
│   └── vx-check/               exhaustive interleaving model checker (host only, §7)
├── servers/                    svcd bootfs devmgr netd posixd ptyd procfs fsd winsrv wm displayd audiod aid swarmd keyd tlsd exportfs auditfs
├── drivers/                    bus-pci bus-dt bus-acpi drv-uart-16550 drv-uart-pl011 drv-virtio-{net,blk,console,input,gpu}
├── cmd/                        gsh ls cat echo ps mount bind ns cpu import ...
├── apps/                       first-party vxui apps: dbg (05)
├── host/                       vx9pserve (serves a host directory over 9P/9Px)
├── ports/                      one directory per C import: port.ndb (sources, flags) plus patches
├── third_party/                vendored sources, one directory each, plus VENDOR.ndb
├── boot/                       limine.conf, svc manifests (boot/svc/*.ndb), namespace templates (boot/lib/ns/)
├── tests/                      host/ (library tests), fuzz/ (libFuzzer targets and corpora), kernel/ (ktest),
│                               user/ (test services), qemu/ (scenario files for `./build test`)
└── docs/                       00–05 (this blueprint), adr/, proto/ (versioned protocol specs)
```

## 3. Build system

### 3.1 Supply-chain enforcement (D13)

There is no package manager to configure, so the rules are simple:

1. `build` reads only files inside the repository and never fetches anything. CI builds with no network, which proves it.
2. Every directory under `third_party/` has a `VENDOR.ndb` record, and the vendored tree matches it:
   ```
   name=lua
       upstream=https://www.lua.org/ftp/lua-5.4.7.tar.gz
       sha256=…
       license=MIT
       adr=docs/adr/0007-vendor-lua.md
       reviewed.by=jkane reviewed.date=2026-10-12 reviewed.scope=full
       patches=ports/lua/0001-vx-os.patch
   ```
3. Nothing generates code during the build except `build` itself. When an import's upstream build runs code generators (Mesa's Python scripts, for example), we run them once, when the import is vendored. The generated files are committed and reviewed with the port. The build never needs Meson, CMake or Python.

`./build vendor-check` checks all three, in CI and as a pre-commit hook.

**Toolchain trust:** clang, lld and compiler-rt come from signed Fedora packages. `build.c` pins their exact version and refuses to run with any other (ADR-0001). CI uses the same packages. Bootstrapping clang from source, and later rebuilding it on VectraOS (M10), are hardening steps.

### 3.2 `build`

`build` is one C23 file that includes `lib/vx-ndb`, with argument parsing written by hand. The host compiler builds it the first time, and after that it rebuilds itself whenever `build.c` changes.

```
./build all     --arch x86_64|aarch64 [--release]    # kernel + user space + bootfs
./build image   --arch …  [--iso]                     # GPT disk image (ESP FAT32); ISO if xorriso is present
./build qemu    --arch …  [--gdb] [--kvm] [--net user|tap] [--9p-host DIR]
./build test    --arch …  [scenario...]               # boot headless, drive the serial console, assert
./build check                                         # host tests under ASan/UBSan, vx-check models, vendor-check, analyzer
./build loc                                           # lines of code per component and per import
./build bench   --arch …  [budget...]                # the end-to-end budgets in 00 §8
```

**Build-time budget:** components compile in parallel, each as one translation unit. There is no incremental dependency tracking, because it is not needed:
- a clean build of the kernel takes under 1 s;
- a clean build of all first-party code takes under 10 s.

CI fails a change that breaks either budget. Vendored ports are built once and cached by source hash.

**Line-count ledger:** `./build loc` reports lines of code for each first-party component and each vendored import, plus assembly lines per architecture. It ends with three totals: first-party code, vendored code, and everything that goes into the image. CI publishes it with every build, so growth is visible, and the kernel's 15–25 kLOC budget (01 §1) is checked.

The vendored total is not hidden in a footnote. Once Mesa arrives at M7 it will be larger than all first-party code together. That is the price of rule 13's decision not to rewrite GPU drivers and compilers, and the ledger makes the price visible. An import that grows by more than 10% on an upgrade needs its ADR revisited.

**Image assembly:**
1. Build the kernel ELF.
2. Build the user-space ELFs.
3. `build` packs the boot image, `bootfs.tar`, a Limine module, with `vx-tar`'s writer: the namespace's mount points (`bin dev proc srv tmp`), the programs that live in it under `boot/bin`, and the service manifests under `boot/svc`. The archive is deterministic (fixed order, no times or owners). A test scenario's `with=` adds test services and their manifests from `tests/user/`.
4. Build `limine.conf`.
5. Create a FAT32 ESP with `mformat` and `mcopy` (mtools), then wrap it in a GPT disk image with `build`'s own GPT writer.

xorriso is needed only for the optional hybrid ISO.

### 3.3 Targets and cross-compilation

| Component | x86_64 | aarch64 | Toolchain |
|---|---|---|---|
| Kernel | `--target=x86_64-unknown-none-elf`, `-ffreestanding -mno-red-zone -mgeneral-regs-only` | `--target=aarch64-unknown-none-elf`, `-ffreestanding -mgeneral-regs-only` | clang + lld; custom linker script |
| User space, M1–M3 | Freestanding, static non-PIE ELF against `vx-rt` | The same | clang + lld |
| User space and C ports, M4 onward | `x86_64-vectra-musl` sysroot | `aarch64-vectra-musl` sysroot | clang + lld |
| Host tools | host triple | host triple | clang, host libc |

One compiler builds everything, for every architecture, with no per-target toolchain to install.

### 3.4 Bootloader and images

- **Limine** is built from a vendored, pinned source release (ADR-0002); the build needs clang and nasm.
- The kernel uses Limine's own `limine.h` protocol header, vendored with Limine.
- **x86_64:** a GPT image with an ESP holding `BOOTX64.EFI`, plus a BIOS hybrid when built as an ISO. It boots in QEMU with OVMF (`/usr/share/edk2/ovmf/OVMF_CODE.fd` on this host) and on real PCs from USB.
- **aarch64:** a GPT image with `BOOTAA64.EFI`. It boots in QEMU `virt` (GICv3, `-cpu max`) with edk2 (`/usr/share/edk2/aarch64`), and later on RK3588 and RPi5 through their UEFI firmware ports. Apple Silicon needs an m1n1 chain-load path, planned at T2.

### 3.5 Host setup (Fedora 44, this workstation)

Already present: QEMU 10.2 for both architectures, OVMF, edk2-aarch64, mtools, clang 22, lld 22, compiler-rt 22, clang-tools-extra 22 and git. `build` calls clang and lld by absolute path (`/usr/bin`), because a Swift toolchain's clang comes first on `PATH`.

Still needed (nasm, for Limine's x86_64 loader, is installed):

```sh
sudo dnf install xorriso            # optional ISO
```

## 4. CI

- **Matrix:** {x86_64, aarch64} × {debug, release}.
- **Jobs:**
  1. `./build check`: host tests under ASan and UBSan, `vx-check` models, vendor-check, the clang static analyzer, `clang-tidy`, `clang-format --dry-run`, and the build-time budget.
  2. `./build all`.
  3. `./build test` under QEMU TCG. KVM is used where the runner supports it.
  4. `./build bench` under KVM for the budgets in 00 §8 that are enforced by the current milestone. On T1 hardware, a self-hosted runner with the input-to-photon rig runs the rest.
- **Artifacts:** the disk images, the serial logs and the line-count ledger.
- **Hosting:** CI runs on self-hosted runners, or on hosted runners with **no network during the build step**, which also proves that D13 holds.

## 5. Milestones to "Hello World"

### M1 — First light: the kernel reaches user space on both architectures

**Scope:**
- `build.c` with `all`, `image`, `qemu`, `test`, `check`, `loc` and `vendor-check`, and the vendored Limine build.
- Kernel:
  - Limine protocol requests;
  - early serial (16550 and PL011);
  - x86_64 GDT and IDT, and aarch64 exception vectors;
  - physical allocator from the memory map;
  - page tables, HHDM, kernel object pools;
  - LAPIC and TSC-deadline timer, and GICv3 and the generic timer;
  - a panic handler with backtraces.
- Objects and syscalls: `Task`, `Thread`, anonymous `Vmo`, `as_map`, `Port` (`port_wait` with deadline and leeway, `port_post`), `handle_close` and `debug_write`.
- An ELF loader for the root task, and a `svcd` stub.
- **Stretch goal:** SMP bring-up on both architectures.

**Exit test** (`./build test --arch x86_64` and `--arch aarch64`, both in CI):

```
[    0.008] vx: kernel 0.1.0 x86_64, 461 MiB free, 4 cpus
[    0.009] svcd: hello from user space (task 1)
[    0.020] svcd: port deadline wait ok: requested 10.000 ms, woke after 10.150 ms
[    0.020] svcd: self-post ok
[    0.021] svcd: vmo map ok
```

The test (`tests/qemu/boot.ndb`) boots headless, matches these lines within 10 s, and fails on a kernel panic, a killed task or a failed check in `svcd`. Other scenarios in `tests/qemu/` cover the panic path and its backtrace, the kernel's page protections, the page allocator and the timer, each by a self-test the scenario names on the kernel command line.

**Size:** about 5–7 kLOC.

### M2 — A shell in a namespace

**Scope:**
- Kernel: `Channel` (with `channel_call` and the kernel-stamped `sender_intent`), `Ring`, `Counter`, futexes, bounded port packets, handle transfer, `Irq` objects, physical VMOs, and `task_create` from a spawn message.
- `vx-ring`, model-checked in `vx-check` (the wake-up protocol from 01 §4.3) and host-tested.
- `vx-9p`: 9P2000 codec and 9Px version negotiation, client and server framework. Host tests round-trip every message and run a fuzz corpus. The server framework enforces the attach root (02 §2), and the hostile-client conformance test runs from here on.
- `vx-ns` (`bind`, `mount`, `unmount`, union directories, `ns` output) and `bootfs`, which serves `bootfs.tar` over 9Px on a ring.
- `drv-uart-16550` and `drv-uart-pl011` as **user-space drivers** serving `/dev/cons`. The kernel console is then used only for panics.
- `vx-ndb`, which `svcd` and `devmgr` need to read their manifests, with the strict parser, `x"…"` hex values and the quoting writer (02 §4.1).
- `svcd` spawns services from `boot/svc/*.ndb` and restarts them on exit. `procfs` provides a minimal `/proc/N/status`.
- `gsh`, plus `ls`, `cat`, `echo`, `ps` and `ns`.

**Exit test:**

```
vx% ls /
boot  bin  dev  proc  srv  tmp
vx% cat /proc/1/status
name=svcd state=waiting threads=2 mem=412K
vx% bind -a /boot/bin /bin; ns | tail -1
bind -a /boot/bin /bin
vx% echo kill > /proc/$uartpid/ctl       # svcd restarts the console driver…
vx% echo still here                      # …and the shell carries on
still here
```

**Size:** about 8–10 kLOC more.

### M3 — Mount the network

**Scope:**
- `bus-pci`: ECAM, and MSI-X through `Irq` objects. On aarch64, `bus-dt` locates the PCIe host bridge.
- The virtio-pci modern transport in `vx-driver`, and `drv-virtio-net` with rings to `netd`. `DmaDomain` runs in IOMMU pass-through mode, under QEMU only; virtio-iommu enforcement comes in M5. On real hardware the IOMMU stays in deny-all mode (01 §10), so M3's network drivers run only in QEMU.
- `netd` on `vx-net`, first-party. It implements Ethernet, ARP, IPv4, ICMP echo, UDP, a DHCP client, TCP (NewReno, window scaling; no SACK yet) and a DNS stub, and serves `/net` in the Plan 9 layout (`clone`, `ctl`, `data`, `local`, `remote`, `status`) together with `/net/cs`.
- 9Px over TCP in the `vx-9p` client. The `mount` command accepts `tcp!host!port` and `9p://host:port`.
- `host/vx9pserve`: a Linux host binary built from the same `vx-9p` library that serves a directory. We also check interoperability against one stock 9P2000 server (for example 9front's `exportfs`, or `u9fs`), so the protocol is not tested only against itself.
- Images for both architectures produced by `./build image`.

**Exit test** (QEMU user networking; the host runs `vx9pserve --listen 127.0.0.1:5640 ./tests/fixtures/share`):

```
vx% cat /net/ipifc/0/status
dev=ether0 addr=10.0.2.15/24 gw=10.0.2.2 dhcp lease=86400s
vx% mount tcp!10.0.2.2!5640 /n/host
vx% ls /n/host
hello.txt
vx% cat /n/host/hello.txt
hello from the host
vx% echo hi > /n/host/out.txt            # appears on the host
```

**Deliverables:** `vectra-x86_64.img` (plus `.iso`) and `vectra-aarch64.img`. The same x86_64 image should boot a real UEFI PC from USB to the shell on its serial or framebuffer console, although that is not gated.

**Size:** about 12–15 kLOC more. The TCP/IP stack is the largest piece.

Rough effort for M1–M3 is 4–6 months for one experienced person working with agents. M1 is the steepest to learn; M3 has the most code.

## 6. After M3

| Milestone | Content | Proves |
|---|---|---|
| **M4 POSIX and debugging** | musl with the vx back end, the `vectra-musl` sysroot, `posixd`, `ptyd`, pipes, sockets, the `posix` 9Px extension, the in-task fault path; Lua and a BusyBox-class userland. The `DEBUG` right and debug syscalls, the `procfs` debug files, crash directories, `vx-debug`, `dbg -c`, `/sys/clock` and `vx-prof` zones (05 §12) | Pillar: the POSIX personality; a debugger from here on |
| **M5 Storage** | virtio-blk and NVMe, `fsd` with a pager and supply deadlines, IOMMU enforcement, driver hot restart under I/O load, a decision on a copy-on-write FS (native log-structured, or a port) | Zero-copy `mmap`; the undo that agents rely on |
| **M6 Pixels** | `displayd` on simplefb and virtio-gpu 2D; `winsrv` with a CPU compositor; `/wsys` with per-app views, the trusted prompt path and the full v1 frame protocol (VRR, tearing and HDR fields, 03 §4); virtio-input; `vxui` v0 with the minimal program in 10 calls and the CPU pixel-buffer program in 12 or fewer (03 §6), kb_text_shape, stb_truetype and the glyph atlas, with a glyph-quality check on a 1x display; hot reload (03 §6.1); `dbg` GUI v0 with the zone timeline as the first real `vxui` app | Pillars: the desktop and the app framework |
| **M7 GPU** | The GPU kernel-driver ADR (03 §3); Mesa Venus over virtio-gpu, the Vulkan profile, the `vxui` Vulkan 2D renderer, `winsrv` on Vulkan, frame feedback | Rendering pipeline, rule 8 |
| **M8 Swarm** | `keyd` (Monocypher), Noise over TCP, node-bound tokens, certificate renewal and revocation, NTP, `swarmd`, `exportfs` with narrow exports, `cpu`, `import`, pools | Pillar: swarms |
| **M9 AI** | `aid` with llama.cpp on Vulkan and on CPU, sessions, context pools, the policy with labels that follow the data, `tlsd` and the TLS import (00 D16), the palette, `auditfs` | Pillar: local-first AI |
| **M10 Self-hosting and T1 hardware** | clang, lld, flang and libomp, Git, Python and `build` running on VectraOS, which rebuilds itself; a real PC and an RK3588 with its NPU; measured boot and signed A/B image updates | Pillar: the hacker toolchain |
| **M11 Audio** | `audiod`, HDA and virtio-sound, the real-time admission path | Rule 6 in practice |
| **M12 Debugger parity** | `dbg` at RAD Debugger level: watch pins, view rules, visualisers, the VectraOS views, following requests across processes, PMU sampling, `gdbfs` for the kernel (05 §6, §9, §12) | Pillar: the hacker toolchain |

## 7. Engineering practice

- **Testing:**
  - Libraries also build for the host, and their tests run in CI under ASan and UBSan.
  - QEMU scenario tests cover everything else.
  - Every protocol under `docs/proto/` has a conformance test suite that runs against both our server and our client.
  - Every server's suite includes the hostile-client test: a client that speaks raw 9Px must not leave its attach root (02 §2).
- **`vx-check`:** a small first-party model checker (`lib/vx-check`) that explores every interleaving of a bounded concurrent program written as per-thread state machines. Its memory model is a store-buffer model: stores wait in a per-thread buffer until flushed, and a fence waits for the buffer to drain. That is the reordering behind lost wake-ups; ARM's further reorderings are excluded by the protocols' acquire and release orderings, which the models do not try to break. A full C11 relaxed-atomics model is a later extension. Every model ships with deliberately broken variants the checker must reject. It is used for the ring wake-up protocol now, and the port and counter semantics and the lease-break logic as they arrive.
- **Fuzzing:** the 9Px codec and server framework, the boot image's tar reader, the ring validators, the class protocols, `vx-ndb`, the font and model-file parsers, and the TLS library's record and certificate parsers are fuzzed by in-tree harnesses (`tests/fuzz/`) built with clang's `-fsanitize=fuzzer,address,undefined` (libFuzzer from compiler-rt). `./build check` replays each one's checked-in corpus and then fuzzes it for 10 s, keeping what it finds in `out/fuzz/`, so coverage grows from one check to the next.
- **Code rules:** the house subset (§1.1). Assembly outside `kernel/arch/` and `vx-rt` needs an ADR, and so does any exception to the subset.
- **Decisions:** `docs/adr/NNNN-title.md`. The first ones are:
  - 0001: toolchain trust;
  - 0002: Limine;
  - 0003: the no-registry policy (D13);
  - 0004: the ring layout, which freezes `vx-abi` v0;
  - 0005: C23 and the house subset (D1).
  - Before M7: the GPU kernel-driver strategy and vendor order (03 §3).
  - Before M9: the TLS 1.3 library (00 D16).
- **Reproducible builds:** `SOURCE_DATE_EPOCH`, `-ffile-prefix-map`, sorted archive members and deterministic GPT GUIDs derived from the build hash. Two builds of the same commit are byte-identical.
