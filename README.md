# Vectra

A modular operating system written in Odin. Plan 9-inspired namespaces and a
synthetic file protocol underneath; a skeuomorphic 1994-cyberpunk workstation
on top.

## Status

Milestone 3 — **the protocol layer exists.** The kernel comes up under
Limine on `x86_64`, installs a GDT, TSS and IDT of its own, brings up serial and
the framebuffer, then builds a bitmap physical page allocator, constructs a
complete set of page tables from scratch and switches onto them, and brings up a
slab heap installed as `context.allocator` — so ordinary Odin `new`, `make` and
`append` work in the kernel. A fault is drawn onto the chassis with its cause
decoded rather than resetting the machine. There is no scheduler and no VFS yet;
`kmain` halts after a self-test.

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
[  ok  ] vectra9 9P2000.L: 57 message kinds round-trip, both transports agree
[  ok  ] boot complete -- halting (no scheduler yet)
```

The self-tests check the things that fail silently. `#BP round-trip ok` means a
breakpoint was armed, raised, caught and resumed from, which exercises the whole
trap path end to end. The memory self-test checks that the page allocator does
not hand out the same frame twice, that walking the new tables for a kernel
global lands where the bootloader actually loaded it, that `.text` is mapped
executable-and-not-writable while `.rodata` is neither, and that memory returned
by `make` survives being written and read back. The protocol self-test encodes,
decodes and re-encodes every message kind and compares the two byte strings,
which catches a field written in the wrong order, read at the wrong width, or
forgotten by the decoder.

## Vectra9

Every system service — drivers, the network stack, graphics, IPC, thread state —
is a file tree behind a message-passing endpoint. The protocol is **9P2000.L,
unmodified**, and keeping it that way is a design constraint: when a service
needs an operation 9P does not have, the answer is a file, not a message.

Servers speak *decoded* messages. The transport is the only thing that knows
bytes exist, so an in-kernel read costs one indirect call and no copy of the
payload, while the same handler behind a pipe gets an identical message because
the transport parsed it first:

```
in-kernel:   caller -- Msg ------------------------> handler
to userland: caller -- Msg -> encode -[bytes]-> decode -> handler
```

The namespace is the full Plan 9 model — `bind`/`mount` with before/after/
replace, union directories, per-process mount tables copied or shared on fork.
That part is designed but not yet built.

**`docs/VECTRA9.md` is the design**, and the thing to read before touching
`sys/vectra9/` or writing anything that talks to it.

A fault reports itself on the chassis, with the error code decoded and — for a
page fault — what was actually mapped at the faulting address:

```
[ FAIL ] #PF page fault (vector 14)
[  !!  ] error code: protection violation, write, supervisor (raw 0x3)
[ FAIL ] faulting address 0xffffffff80000000
[  !!  ]   mapped to 0x000000001fe3c000 r-x supervisor global
```

Screenshot: `docs/panic-screen.png`.

## Building

Requires `odin`, `ld.lld`, `qemu-system-x86_64`, and `python3` with Pillow (only
to regenerate the console font). No `xorriso`, no loop devices, no `sudo` — the
bootable volume is a directory that QEMU's vvfat backend presents to the
firmware as FAT, so the same commands work on macOS and Linux.

```sh
just run          # build, stage, boot headless with serial on stdio
just gui          # same, but open a QEMU window
just debug        # boot halted; `just gdb` in another shell
just release      # optimised, bounds checks off
make run          # if you don't have `just`
```

`build.odin` is the real build system; `justfile` and `Makefile` are wrappers
over it, and its options are documented in the comment at the top of the file.
Invoke it directly as:

```sh
odin run build.odin -file -out:.vectra-build -- run --gfx
```

The explicit `-out:` matters: without it `odin run` names the driver binary
after the script and drops `./build` right on top of the `build/` output
directory.

## Layout

```
build.odin              Build driver: compile, link, stage ESP, run QEMU
boot/                   Bootloader assets staged into the EFI system partition
kernel/
  main.odin             kmain, the Limine requests, and memory bring-up
  splash.odin           The boot chassis: plinth, copper bar, well, lamps
  log.odin              Kernel log; serial and screen, with replay of
                        lines emitted before the framebuffer existed
  panic.odin            The panic screen and the trap handler behind it
  link_amd64.ld         Static-PIE image layout for the Limine protocol
  arch/                 Architecture interface (arch_amd64.odin binds it)
    amd64/              Port I/O, control registers, MSRs, CPUID, SSE, the
                        page table format, and the GDT/TSS/IDT
  boot/limine/          Limine protocol bindings; markers.odin owns the
                        base revision tag and the request delimiters
  drivers/
    uart/               16550 serial, polled
    fb/                 Linear framebuffer surface, bevels, gradients, palette
    console/            Framebuffer text console + baked 8x16 font
  mem/                  Bitmap PMM, page tables, slab heap
  sched/ vfs/           Not yet written
sys/
  libodin/              Freestanding core shared by kernel and userland
  vectra9/              9P2000.L message layer: types, codec, sessions
  libposix/             Not yet written
servers/                devfs, netfs, intuition — not yet written
apps/                   terminal, filemgr, tracker — not yet written
tools/genfont.py        Bakes a host TTF into kernel/drivers/console/font_data.odin
```

## Notes on the toolchain

- The kernel builds against **stock `base:runtime`**. Odin's freestanding
  target now carries its own `os_specific` stubs, so there is no vendored
  runtime shim to keep in sync with the compiler.
- `-no-thread-local` is required: Odin otherwise emits `STT_TLS` symbols with
  no `PT_TLS` segment to put them in. Per-CPU state will go through `GS`.
- `ld.lld` does the linking. Apple's `ld` cannot produce ELF.
- The bundled Limine is **v12.6.1** (UEFI applications only, in `boot/limine/`).
  Vectra requests **base revision 6**, and `kmain` reports whether it got it.
- Under base revision 2 and above the request delimiters are binding, not
  advisory. Every request must carry `@(link_section = ".limine_requests")` or
  the bootloader never sees it — it links and boots, and the response is just
  silently nil. `kernel/link_amd64.ld` orders the section start/body/end.
- Base revision 5 and above clear every `cr0`/`cr4`/`EFER` bit the protocol does
  not require, `CR4.OSFXSR` included, so `arch.early_init` enabling SSE is a
  hard requirement rather than belt-and-braces.
- Base revision 6's HHDM is restrictive: only usable, bootloader-reclaimable,
  executable, framebuffer, reserved-mapped, ACPI-reclaimable and ACPI-NVS
  regions are mapped. The VMM will have to respect that.
- The paging mode is pinned to 4-level. Limine would otherwise hand us 5-level
  on hardware that supports it, which moves the canonical hole.
- `EFER.NXE` has to be enabled before the first mapping that sets the no-execute
  bit. Until it is, bit 63 of a page table entry is *reserved* rather than
  ignored, and the mapping faults on first touch nowhere near the cause.
- The kernel image's segment bounds come from `kernel/link_amd64.ld`, which
  exports `__text_start` … `__data_end`, rather than being restated in Odin. The
  VMM maps a segment at a time using them, so the permissions it installs cannot
  drift out of step with the layout the linker actually produced.
- Interrupt entry stubs use `proc "naked"` — a calling convention, not the
  `@(naked)` attribute, which Odin does not have. All 256 are emitted by the
  assembler with `.rept`, padded to sixteen bytes each by `.balign 16` so the
  nth is found by multiplying rather than through a table of function pointers.
- The legacy 8259 PICs are remapped clear of the exception vectors *and* then
  masked. Masking alone leaves a spurious IRQ 7 able to arrive as a page fault
  with a stale CR2, which is a very convincing wrong answer.
