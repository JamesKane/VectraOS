# D101. Warm boot: the kernel hands off to a new kernel and bootfs held in memory (2026-10-17, decided; extends D77, D79)

The bring-up link (D77) runs a new build of a program without a reboot
(push and run), but a new kernel or bootfs still needs the firmware:
a power cycle, the firmware's boot, the loader. On a board that is the
slowest part of the loop, and the one a bad build can strand. Warm boot
makes the running kernel do what the loader does, from images held in
memory, as Linux's kexec and Zircon's mexec do.

- **The images are staged in /dev.** devmgr, which holds the system
  resource (D79's power holder), serves `/dev/warm/kernel`,
  `/dev/warm/bootfs` and `/dev/warm/cmdline`: files of memory that grow
  to their highest write. The `warmboot KERNEL BOOTFS` script copies its
  two files there (from `/mnt/term` in a cpu session) and writes
  `warmboot` to `/dev/reboot`, as Plan 9 writes a kernel to its reboot
  device. An empty `cmdline` keeps the running kernel's.
- **DMA stops first.** devmgr, which owns PCI configuration space,
  clears Bus Master Enable on every function before it asks the kernel:
  a device that can't master can't write into memory the new kernel
  reuses. The kernel then turns its IOMMUs' translation and interrupt
  remapping off, as firmware leaves them.
- **One new system_powerctl command**, `CROI_SYSTEM_POWERCTL_WARMBOOT`,
  under the power resource; its argument names three VMOs (the kernel
  ELF, the bootfs, the command line). No new syscall: the ceiling holds.
- **The kernel does the loader's work with the loader's code.** It
  checks the ELF (`lib/elf`), copies the kernel and bootfs into
  physically contiguous runs, loads and relocates the kernel at a new
  KASLR base from its CPRNG, builds the boot page tables
  (`lib/pagetables`: all RAM identity mapped, the kernel's segments W^X,
  the UART), and a handoff (`lib/handoff`) from the boot handoff it
  kept: the firmware's memory map (saved at boot, the loader's and
  kernel's own ranges turned back into free RAM, the new ones typed
  KERNEL, BOOTFS and HANDOFF), the RSDP, SMBIOS, the framebuffer, the
  UART, fresh entropy. Everything that can fail fails before anything
  stops.
- **Then it stops and enters.** It drains the debuglog as reboot does,
  stops the other CPUs where the new kernel can start them (amd64: halted
  with interrupts off, for INIT-SIPI; arm64: PSCI CPU_OFF, for CPU_ON),
  masks every interrupt, and enters the new kernel as the loader does
  (`croi_arch_enter_kernel`'s contract), from a trampoline the new tables
  map too.
- **What it keeps and what it doesn't.** ACPI's tables (never the PMM's),
  the firmware's runtime memory, the framebuffer and the UART carry over;
  user space, devices' state and everything in RAM do not, as after a
  reset. The new kernel can't tell a warm boot from a cold one but by
  the console's line, and needs no change to boot either way.

**Arches.** amd64, then arm64 (the MMU and caches around the switch,
PSCI for the other CPUs). rv64 (SBI HSM) when its suite runs again.

**Checks.** A boot test warm-boots the kernel and bootfs of its own
build into themselves with a command line that says so, and finds the
second boot's banner and its end; boot-cpu warm-boots the node through
`vx cpu` and finds its cpu server again. A budget,
`power.warmboot_kernel`, times the kernel's part from the call to the
jump, reported from the start; its limit comes with V6's boards.

Rejected: reading the images in the kernel from paths (the kernel has
no namespace). Rejected: a second loader binary the kernel jumps to,
which would duplicate what `lib/elf` and `lib/pagetables` already share.
Rejected: leaving DMA to the IOMMU alone: not every machine has one, and
the new kernel would start with one already on, which it doesn't expect.
