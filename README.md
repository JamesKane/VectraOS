# Vectra

A modular operating system written in Odin. Plan 9-inspired namespaces and a
synthetic file protocol underneath; a skeuomorphic 1994-cyberpunk workstation
on top.

## Status

Milestone 1 — **it owns its own memory.** The kernel comes up under Limine on
`x86_64`, brings up serial and the framebuffer, draws its chassis and surveys
the boot; then it builds a bitmap physical page allocator over the memory map,
constructs a complete set of page tables from scratch and switches onto them,
and brings up a slab heap that is installed as `context.allocator` — so
ordinary Odin `new`, `make` and `append` work in the kernel. There is no
scheduler and no VFS yet; `kmain` halts after a self-test.

```
[  --  ] Vectra 0.1.0-pre (amd64) entering kmain
[  ok  ] base revision 6 as requested
[  ok  ] framebuffer 1280x800 @ 32bpp, pitch 5120 -> 0xffff800080000000
[  --  ] console 149 cols x 36 rows
[  --  ] booted by Limine 12.6.1 via UEFI (64-bit)
[  ok  ] paging 4-level
[  --  ] kernel phys 0x000000001fe56000 virt 0xffffffff80000000
[  --  ] hhdm offset 0xffff800000000000
[  --  ] memory map: 27 entries spanning 12.7 GiB
[  ok  ] usable 467.6 MiB, reclaimable 39.1 MiB
[  --  ] largest usable region 421.4 MiB at 0x0000000001600000
[  ok  ] pmm 119718 frames free of 123529 tracked, bitmap 15.0 KiB at 0x0000000000001000
[  ok  ] vmm root 0x0000000000005000, mapped 515.1 MiB in 269 tables (1.0 MiB)
[  --  ] vmm nx on, global pages on, largest leaf 2.0 MiB
[  ok  ] heap online -- context.allocator is live
[  ok  ] memory self-test passed -- 1 slab pages, 0 large blocks live
[  ok  ] boot complete -- halting (no scheduler yet)
```

The `vmm` line is printed *after* the address space switch, so the fact that it
reaches the screen is the proof that the new tables cover the framebuffer, the
kernel image and the stack the bootloader left us on. The self-test checks the
things that would otherwise fail silently: that the page allocator does not hand
out the same frame twice, that walking the new tables for a kernel global lands
where the bootloader actually loaded it, that `.text` is mapped
executable-and-not-writable while `.rodata` is neither, and that memory returned
by `make` survives being written and read back.

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
  link_amd64.ld         Static-PIE image layout for the Limine protocol
  arch/                 Architecture interface (arch_amd64.odin binds it)
    amd64/              Port I/O, control registers, MSRs, CPUID, SSE, and
                        the page table format
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
  libposix/ vectra9/    Not yet written
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
