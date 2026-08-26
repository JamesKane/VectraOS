# Vectra — session handoff

Written 2026-08-26, revised the same day after Milestones 1 and 2. Read this first
when picking the project up in a new session; it records the things the code cannot tell you on its own — what was
decided and why, what cost time, and what is deliberately missing.

---

## 1. What Vectra is

A modular operating system in Odin. Two ideas define it:

- **Plan 9-inspired structure.** Per-process namespaces, private mount tables,
  and a synthetic file protocol (Vectra9 / 9P2000.L) through which *every*
  system service — drivers, network stack, graphics, IPC, thread state — is a
  file tree behind a message-passing endpoint. POSIX is a translation runtime on
  top of that, never a set of hardwired syscalls.
- **"Cyberpunk Workstation 1994" UX.** Heavy skeuomorphic bevels, brushed dark
  magnesium over deep slate, amber/cyan/phosphor accents, copper trim, a
  software dirty-rect compositor, and tracker-synthesised relay clicks.

Target layout — `kernel/` (arch, mem, sched, vfs, drivers), `sys/` (libodin,
libposix, Vectra9), `servers/` (devfs, netfs, intuition), `apps/` (terminal,
filemgr, tracker). Primary arch `x86_64` via Limine, with clean abstractions for
`aarch64` and `riscv64`.

## 2. Where things stand

**Milestone 2 is done and verified: the kernel can survive its own mistakes.**

Milestone 0 boots it; Milestone 1 gave it a PMM, its own page tables and a heap
behind `context.allocator`. Milestone 2 replaces Limine's descriptor tables with
a GDT and TSS of our own, installs an IDT covering all 256 vectors, and draws a
panic screen on the chassis the boot splash already established. About 5,450
lines of Odin; the linked image is ~201 KB debug, ~85 KB release.

```
[  --  ] Vectra 0.1.0-pre (amd64) entering kmain
[  ok  ] base revision 6 as requested
[  ok  ] traps: cs 0x8, tr 0x30, 256 vectors, #BP round-trip ok
[  ok  ] framebuffer 1280x800 @ 32bpp, pitch 5120 -> 0xffff800080000000
[  --  ] console 149 cols x 36 rows
[  --  ] booted by Limine 12.6.1 via UEFI (64-bit)
[  ok  ] paging 4-level
[  --  ] kernel phys 0x000000001fe3c000 virt 0xffffffff80000000
[  --  ] hhdm offset 0xffff800000000000
[  --  ] memory map: 27 entries spanning 12.7 GiB
[  ok  ] usable 467.4 MiB, reclaimable 39.2 MiB
[  --  ] largest usable region 421.4 MiB at 0x0000000001600000
[  ok  ] pmm 119678 frames free of 123400 tracked, bitmap 15.0 KiB at 0x0000000000001000
[  ok  ] vmm root 0x0000000000005000, mapped 515.1 MiB in 270 tables (1.0 MiB)
[  --  ] vmm nx on, global pages on, largest leaf 2.0 MiB
[  ok  ] heap online -- context.allocator is live
[  ok  ] memory self-test passed -- 1 slab pages, 0 large blocks live
[  ok  ] boot complete -- halting (no scheduler yet)
```

Screenshots: `docs/milestone1-memory.png` (a clean boot) and
`docs/panic-screen.png` (a deliberate write into `.text`).

The third line is the new one, and every field in it is a check rather than a
report. `cs 0x8` and `tr 0x30` say the segment reload and `ltr` took, read back
out of the CPU. `#BP round-trip ok` says a breakpoint was armed, raised, caught,
recognised and resumed from — which exercises the whole path end to end: the
stub pushing the right vector, the tail building a frame the dispatcher can
read, and `iretq` landing back on the instruction after the `int3`.

**The panic path has been exercised on the machine, not just written.** Three
deliberate faults, each removed again afterwards:

| Provoked | Reported |
|---|---|
| write into `.text` | `#PF`, `protection violation, write, supervisor`, CR2 = the text base, `mapped to 0x1fe3c000 r-x supervisor global` |
| null dereference | `#PF`, `page not present, write, supervisor`, CR2 = 0, `nothing is mapped there` |
| `rsp` moved to an unmapped page, then a push | `#DF double fault (vector 8)` — caught on IST1, and QEMU logged no third CPU reset, so it never triple-faulted |

That last one is the whole reason the TSS exists, and it is the only one of the
three that could not have been checked by reading the code.

**What still does not exist.** No LAPIC, no I/O APIC, no timer, so nothing has
ever called `sti` and no interrupt has ever arrived — only exceptions. No
scheduler, no VFS, no 9P, no userland, no compositor. `kmain` halts on purpose.

## 3. Build and run

```sh
just run          # build, stage ESP, boot headless, serial on stdio
just gui          # same, with a QEMU window
just debug        # boot halted; `just gdb` in another shell
just release      # -o:speed, bounds checks off
just check        # type-check everything, emit nothing
just font         # regenerate the baked console font
make run          # identical targets, if `just` is absent (it is, here)
```

`build.odin` is the real build system — compile, link, stage, run — and holds
the per-architecture table. `justfile`/`Makefile` are thin wrappers. Invoke the
driver directly as:

```sh
odin run build.odin -file -out:.vectra-build -- run --gfx
```

**The explicit `-out:` is mandatory.** Without it `odin run` names the driver
binary after the script and drops `./build` directly on top of the `build/`
output directory. This bit once already.

Verified toolchain on this machine: Odin `dev-2026-08:8412dc37a`, LLD 21.0.0
(from `~/.swiftly/bin`), QEMU 11.1.0, Python 3 with Pillow (font generation
only). No `just` installed — use `make`. No `xorriso`, no loop devices, no
`sudo` required.

## 4. Toolchain constraints — the expensive ones

These were each found the hard way. Changing any of them will break the build in
ways whose error messages do not point back here.

| Constraint | Why |
|---|---|
| `-no-thread-local` | Odin otherwise emits `STT_TLS` symbols with no `PT_TLS` segment; `ld.lld` refuses the image. Per-CPU state must go through `GS` explicitly. |
| `ld.lld`, not `ld` | Apple's linker cannot produce ELF. |
| `-out:.vectra-build` | See above — `./build` collides with `build/`. |
| ESP is a **directory**, not an image | QEMU's vvfat (`-drive format=raw,file=fat:rw:build/esp`) presents it as FAT. This is what makes the build work on macOS, where `losetup`/`mkfs.vfat` do not exist. Same commands work on Linux. |
| `arch.early_init()` runs first | Limine base revision 5+ clears every `cr0`/`cr4`/`EFER` bit the protocol does not require — `CR4.OSFXSR` included. Odin's codegen uses XMM for ordinary struct moves, so the *first* Odin statement after entry faults without SSE re-enabled. |
| `@(link_section = ".limine_requests")` on every request | Since base revision 2 the request delimiters are **binding, not hints**. A request outside the section compiles, links, boots — and its `response` stays nil forever. Silent. |
| EFER.NXE before the first NX mapping | Bit 63 of a page table entry is *reserved*, not ignored, until `EFER.NXE` is set. Install a mapping with it first and the fault comes on first touch, as a reserved-bit #PF, nowhere near the cause. `amd64.enable_paging_features` is what turns it on, and `leaf_encode` drops the bit if it did not take. |
| Segment bounds come from `link_amd64.ld`, not from Odin | `__text_start` … `__data_end` are declared in a bare `foreign { }` block in `kernel/mem/vmm.odin`. They are defined *inside* their output sections in the linker script on purpose: written between sections they become orphans, and ld is free to attach an orphan to whichever segment it likes. |
| `intrinsics` has `mem_zero` and `mem_copy`, but no `mem_set` | There is no fill-with-a-byte intrinsic. The PMM's bitmap fill is a plain loop. `memset`/`memcpy`/`memmove` *are* provided by stock `base:runtime`, which is why the link has no undefined symbols. |
| `proc "naked"`, not `@(naked)` | Odin has no `naked` attribute — it is a *calling convention*. `@(naked)` fails with "Unknown attribute element name", and the suggested `-ignore-unknown-attributes` would silence the error while still emitting a prologue, which corrupts the interrupt frame. |
| `$$` in an inline-asm template | Odin substitutes `$0`, `$1` … for operands, so a literal immediate needs `$$0x10`. Operands passed under the `i` constraint supply their own `$` — `movw $2, %ax` with `u64(0x10)` assembles as `movw $0x10, %ax`. |
| The error-code vector list is written twice | Once as an assembler `.if` inside the stub blob and once as `vector_has_error_code` in Odin. They cannot share a definition — one is consumed at build time, the other at run time — and if they disagree every field in `Trap_Frame` reads as the one next door. They live in the same file for that reason. |
| `int $8` is not a double fault | A software interrupt to an error-code vector does **not** push an error code, so it lands on a stub that assumes one was pushed. Never test `#DF` that way; provoke a real one by faulting on a bad stack. |

**No vendored runtime shim.** The neighbouring `odin-os` project hand-maintains
a copy of `base:runtime` that must track the compiler. Current Odin ships
`runtime-os_specific_freestanding`, so Vectra builds against **stock
`base:runtime`**. Do not reintroduce a shim.

## 5. Decisions made, and what would reverse them

- **Limine 12.6.1, base revision 6.** Vendored UEFI binaries only (x64, aa64,
  riscv64, ia32) in `boot/limine/`; no BIOS stage, no `limine` deploy tool,
  because Vectra boots UEFI everywhere. `kmain` reports the granted revision.
- **Paging pinned to 4-level** (`min_mode = max_mode = 4LVL` in
  `paging_mode_request`). Limine would otherwise hand us 5-level on capable
  hardware, moving the canonical hole and changing every table walk. Adding
  5-level support should be a deliberate edit to that request.
- **Base revision 6's HHDM is restrictive** — only usable,
  bootloader-reclaimable, executable, framebuffer, reserved-mapped, ACPI
  reclaimable and ACPI NVS regions are mapped. **The VMM must respect this.**
  `check_base_revision()` currently only *warns* on a mismatch; make it a hard
  stop as soon as anything dereferences an HHDM address.
- **`arch` is the only CPU-facing import** the portable kernel may use.
  Per-architecture bindings are selected by `#+build` tag
  (`arch_amd64.odin`, `arch_arm64.odin`, `arch_riscv64.odin`); the latter two
  are stubs that exist so a port is filling in blanks, not editing call sites.
- **Inline asm, no nasm.** Odin's `asm(...)` with LLVM AT&T templates and
  register constraints covers port I/O, control registers and MSRs. Verified by
  disassembly.
- **The framebuffer `Surface` is the shared drawing type.** The boot splash, the
  future panic screen, and `intuition`'s off-screen window buffers are all
  Surfaces, so a bevel drawn at boot and one on a titlebar are the same code.
  `kernel/drivers/fb/palette.odin` is the single source of colour truth.
- **Console font is host-rasterised.** `tools/genfont.py` bakes PTMono at 13px
  (exactly 8×16) into `kernel/drivers/console/font_data.odin`. Serviceable, but
  a hand-drawn bitmap face is the right long-term answer for the amber terminal.
- **The logger replays.** Lines emitted before the framebuffer exists are
  buffered (16 × 128 bytes, static) and drawn by `attach_screen()` when the
  console attaches, so screen and serial agree line-for-line.

Memory, added in Milestone 1:

- **`arch` owns the page table *encoding*; `kernel/mem` owns the *walk*.** This
  is where the "only CPU-facing import" rule landed for paging. `arch` supplies
  `table_index`, `level_size`, `leaf_encode`, `branch_encode`, `entry_flags` and
  friends; `vmm.odin` implements the descend-and-allocate loop once against
  them. The walk genuinely is not amd64-specific — aarch64's stage-1 tables and
  riscv64's Sv39/Sv48 are the same radix tree, nine bits at a stride — so a port
  supplies an encoding rather than a second walker.
- **Bitmap PMM, not a free list.** A free list has to live in the pages it
  tracks, so one stray write corrupts the allocator itself; and contiguous
  multi-page allocation, which page tables and large heap blocks both need, is a
  run search over a bitmap versus a linear walk over a list. The cost is a scan,
  bounded by a rotating hint and by skipping fully-taken bytes eight frames at a
  time.
- **The bitmap indexes from physical zero**, holes included, so `phys /
  PAGE_SIZE` is the index with nothing to subtract. Hole frames are born taken
  and never freed. It is 15 KiB on this machine.
- **Frame 0 is reserved forever.** Base revision 6 lets the firmware call the
  page at physical zero usable. Handing it out costs the one thing that makes a
  null dereference announce itself.
- **Bootloader-reclaimable memory is *not* reclaimed.** It is 39 MiB and worth
  having, but at the end of `mem.init` the kernel is still standing on three
  things inside it: the stack `kmain` is running on, every Limine response, and
  the memory map itself. `pmm_reclaim` is written and ready; it becomes callable
  once the scheduler is on a kernel stack of its own and anything wanted from
  the responses has been copied out.
- **All 256 higher-half top-level entries are pre-populated** at VMM init. A
  kernel mapping made after a user address space is created must appear in that
  address space too, and if the top-level entry did not exist at copy time it
  never will. Costs 1 MiB, paid once; buys never having to propagate a kernel
  mapping by hand. This is most of the "269 tables" in the boot log.
- **The kernel image is mapped a segment at a time**, with the permissions the
  linker script implies — text read-execute, rodata read-only, data read-write
  and no-execute — and `CR0.WP` is set, so they bind on supervisor writes too.
  Verified by reading the entries back out of the live tables, not by trusting
  the code that wrote them.
- **The direct map rounds outward; the PMM rounds inward.** Different jobs: the
  PMM must never hand out a frame that is partly somebody else's, and the direct
  map must never fail to map a page a structure straddles.
- **NX, global pages and 1 GiB leaves are all detected, not assumed.**
  `enable_paging_features` reads CPUID and records what took; `leaf_encode`
  silently drops a bit whose feature is off, so callers can ask unconditionally.
  On `-cpu qemu64` NX and PGE are present and 1 GiB pages are not, hence the
  2 MiB largest leaf in the boot log.
- **The framebuffer is added to the region list by hand if the map omitted it.**
  Base revision 6 guarantees the framebuffer is direct-mapped; it does not
  guarantee the firmware described it as a memory map entry. Getting that wrong
  kills the machine on the first character drawn after the CR3 switch — with the
  console being the thing that would have reported it.
- **Slab classes are 16 B … 2 KiB, powers of two**, one page per slab, free
  objects threaded through their own first eight bytes. Every allocation carries
  a 16-byte header immediately below the returned pointer holding a magic, the
  class (or "large"), the page count and the offset back to the block start.
  That header is what makes `free` a constant-time dispatch with no lookup
  structure, and what makes over-aligned allocation possible at all.
- **`free` checks the magic and clears it.** A pointer that did not come from
  `alloc` is ignored rather than acted on, and a double free fails the check
  instead of putting the same object on a free list twice. Leaking is the
  cheaper outcome.
- **`-default-to-nil-allocator` stays in the build.** `context.allocator` is
  installed at the very end of `kmain`, so an accidental allocation during early
  boot still returns nil and fails at its use, rather than quietly succeeding
  against a heap that does not exist yet.

Traps, added in Milestone 2:

- **Traps come up before the framebuffer**, immediately after the serial port
  and the base revision check. Everything after that point is code that faults
  while it is being written, and a fault before it is a triple fault with
  nothing to show for it. The consequence is that the fault stacks have to be
  static `.bss` arrays rather than PMM pages — which is the right trade, because
  it is memory bring-up above all that this needs to be able to debug.
- **The selector layout is fixed by SYSCALL/SYSRET**, not by taste. `SYSCALL`
  takes CS from `STAR[47:32]` and SS from that plus 8; `SYSRET` to 64-bit code
  takes CS from `STAR[63:48]` plus 16 and SS from plus 8. Hence kernel code then
  kernel data, and user code32 then user data then user code64 — with the
  code32 slot present purely as a placeholder. Renumbering these later does not
  break the build, it breaks the first system call.
- **Three vectors get interrupt stacks of their own**: the double fault (IST1),
  NMI (IST2) and the machine check (IST3). The double fault is the one that
  matters — a fault that happens *because* the stack is bad has nowhere to push
  its frame, and that is a triple fault. Verified by provoking one.
- **All 256 vectors are installed, not just the 32 exceptions.** A stray
  interrupt on a vector with no descriptor is a `#GP`, and a `#GP` with no
  handler is a double fault, so the cheapest way to make a stray interrupt say
  "vector 39 arrived and nobody was expecting it" is to give every vector a stub.
- **The stubs are generated by the assembler, not written out or code-generated
  into a file.** `.rept` emits 256 of them and `.balign 16` makes each exactly
  sixteen bytes whether or not it pushed a dummy error code, so `idt_init` finds
  the nth by multiplying. That alignment is load-bearing: it is what turns a
  table of 256 function pointers into one label and a shift.
- **The legacy PICs are remapped *and* masked** before anything could call
  `sti`. Masking alone is not enough — a spurious IRQ 7 can still get through,
  and unremapped it arrives as a **page fault** with a garbage error code and a
  stale CR2, which the panic screen would then report with total confidence.
- **A trap handler returns a bool: resume, or stop.** The only thing that ever
  resumes today is the breakpoint the boot self-test arms for itself, and that
  narrowness is deliberate — a stray `#BP` from anywhere else still panics.
- **The panic screen's body text is amber, not red.** The alarm is carried by
  the red band, the `[ FAIL ]` tags and the FAULT lamp; the report itself is
  mostly hex that has to be read carefully, and a wall of red is the worst way
  to present it.
- **The panic path reports what was *mapped* at CR2, not just the address.**
  "nothing is mapped there" and "mapped read-only and you wrote to it" are
  different bugs that produce the same CR2, and `mem.permissions` already knew
  how to tell them apart.

## 6. Known warts

- **The trap stub saves general-purpose registers only.** No `FXSAVE`, so a
  handler that *returns* into code with live SSE state would corrupt it. Panics
  never return, and the only resuming path today is a breakpoint the kernel
  raised on itself, so this is fine now and is the first thing that has to grow
  the day anything resumes arbitrary code — a debugger, or a page fault that
  fixes up and retries.
- **No `swapgs` in the entry path.** Correct today, because nothing runs at
  CPL 3. It becomes wrong the moment userland does, and the fix has to land in
  the same tail that the point above rewrites.
- **The panic screen has no backtrace.** It reports the faulting instruction and
  the register state but cannot walk the stack; that needs frame pointers kept
  deliberately or unwind tables retained. It is the largest single thing missing
  from an otherwise complete fault report.
- **No locking anywhere in `kernel/mem`.** Single CPU, single thread, and now —
  since the IDT exists — interrupts that are still never enabled. The PMM's
  bitmap and the heap's free lists both need a lock before the first AP comes up
  or the first interrupt handler allocates.
- **Slabs are never returned to the PMM.** Reclaiming one means proving every
  object in it is free, which means per-slab occupancy counts and a
  partial/full/empty chain per class. The fix belongs in `slab_grow`/`slab_free`,
  not in the callers.
- **`map_at` refuses to map over an existing mapping** rather than splitting a
  large page. Nothing yet needs to, and making it an error means that when
  something does, it says so instead of silently doing the wrong half of it.
- **The framebuffer is mapped write-back, not write-combining.** That needs PAT
  setup. It will matter to the compositor and does not matter yet.
- **1 MiB goes to higher-half page tables** at boot, most of it never touched.
  Deliberate — see section 5 — but it is the largest single line item in the
  kernel's own footprint.
- **OVMF is borrowed from `../odin-os/ovmf/ovmf_x64.fd`.** `build.odin` hard-codes
  that path and dies if it is missing. Vectra should vendor its own firmware, and
  will need `AAVMF`/`RISCV_VIRT` equivalents before the other arches can boot.
- **QEMU's vvfat is read-write, so OVMF writes `NvVars` into `build/esp/`.**
  Harmless, but it means the staged ESP is not byte-reproducible.
- **`arm64` and `riscv64` are stubs, and are falling further behind.**
  `build.odin` has their rows filled in and the vendored bootloaders are
  present, but there are no `link_arm64.ld` / `link_riscv64.ld` scripts, and
  `arch_amd64.odin` has now grown both the paging interface *and* the trap
  interface that the other two do not declare.
- **Memory-map entry count varies run to run** (27, 31, 33) with OVMF/vvfat. Not
  a bug; do not chase it.

## 7. Where to go next

The GDT/IDT blocker from the last handoff is gone. What is left is the fork that
has been waiting since Milestone 1, and it is genuinely open:

- **`kernel/sched/`** — threads, a kernel stack per thread, a timer. Needs the
  local APIC first, which is the natural next use of the IDT now that it exists:
  map the LAPIC, program its timer, install a handler on a vector above 32, and
  call `sti` for the first time. This is also what unblocks `pmm_reclaim` — the
  39 MiB of bootloader memory becomes free the moment the kernel is off Limine's
  stack, and the reason it is not called yet is written down in section 5.
- **`sys/vectra9/`** — design the 9P message layer and the namespace model
  before the kernel grows structures that assume otherwise. The VFS is the
  architectural heart and it now has both an allocator and a fault handler
  underneath it.

If the scheduler goes first, do these in the same pass rather than after it:

1. **`FXSAVE`/`FXRSTOR` in the trap tail.** A scheduler preempting on a timer
   interrupt is exactly the "resumes arbitrary code" case that section 6 says
   this breaks on, and it will break silently — as wrong floating-point results,
   not as a fault.
2. **A lock type in `kernel/mem`.** The first interrupt handler that allocates
   is racing the code it interrupted.
3. **`swapgs` and per-CPU state behind GS.** Cheaper to build into the entry
   path now than to retrofit around a working scheduler.

**Smaller things worth doing when convenient:**

- A stack backtrace on the panic screen. Everything else a fault report wants to
  say is already there.
- Make `check_base_revision()` a hard stop rather than a warning. The condition
  for that was "as soon as anything dereferences an HHDM address", and
  `mem.init` now does, on every page table write.
- Teach `arch_arm64.odin` / `arch_riscv64.odin` the paging and trap interfaces,
  so a port is still a matter of filling in blanks.

## 8. File map

```
build.odin              Build driver: compile, link, stage ESP, run QEMU
justfile / Makefile     Thin wrappers over build.odin
boot/
  limine.conf           Limine config (new-style), staged to /EFI/BOOT/
  limine/               Vendored Limine 12.6.1 UEFI binaries + VERSION + README
kernel/
  main.odin             kmain, Limine requests, boot survey, memory bring-up
  splash.odin           Boot chassis: plinth, copper bar, well, lamps
  log.odin              Kernel log; serial + screen, with early-line replay
  panic.odin            The panic screen, and the trap handler behind it
  link_amd64.ld         Static-PIE layout; orders .limine_requests, exports
                        the __text/__rodata/__data segment bounds
  arch/
    arch_amd64.odin     The architecture interface, bound to amd64
    arch_arm64.odin     Stub
    arch_riscv64.odin   Stub
    amd64/cpu.odin      Port I/O, control regs, MSRs, CPUID, EFER, SSE
    amd64/paging.odin   Page table format: entry bits, encode/decode, TLB
    amd64/gdt.odin      GDT, TSS, and the interrupt stack table
    amd64/idt.odin      IDT, the 256 entry stubs, dispatch, fault reporting
    amd64/pic.odin      Legacy 8259s: remapped clear of the exceptions, masked
  boot/limine/
    limine.odin         Protocol bindings (v12.6.1)
    markers.odin        Base revision tag + request delimiters
  drivers/
    uart/uart.odin      16550 serial, polled
    fb/fb.odin          Surface, clipping, bevels, gradients, brushed fill
    fb/palette.odin     The system palette — single source of colour truth
    console/console.odin  Framebuffer text console
    console/font_data.odin GENERATED — do not hand-edit
  mem/
    mem.odin            Region/Boot_Memory types, HHDM, alignment, mem.init
    pmm.odin            Bitmap physical page allocator
    vmm.odin            Page table walk, kernel address space, translate
    heap.odin           Slab allocator + Odin's context.allocator
  sched/ vfs/           Empty
sys/
  libodin/format.odin   Allocation-free formatting (Sink)
  libposix/ vectra9/    Empty
servers/ apps/          Empty
tools/genfont.py        TTF -> font_data.odin
docs/
  HANDOFF.md            This file
  milestone0-boot.png   Milestone 0 screenshot -- it boots
  milestone1-memory.png Milestone 1 screenshot -- PMM, VMM, heap
  panic-screen.png      Milestone 2 screenshot -- a deliberate #PF, reported
```
