# PC: Gigabyte X870E AORUS ELITE WIFI7, Ryzen 9 7900X

A research pass (2026-10-16). Since D69 it is amd64's first board,
V6c. This is the AMD tower on the local network (192.168.0.30). It has
no name of its own (its Linux hostname is `fedora`); it runs whatever
workloads are needed when it is powered up. Unlike brimstone
(`docs/boards/pc-9700x/`), it is not the development host, so booting it
into VectraOS stops nothing else.

Facts were read over SSH under Fedora 44 (Linux 7.2.7), without root,
from `/sys`, `/proc/cpuinfo`, `lspci` and the kernel log, on 2026-10-16.
Facts marked **(memory)** are not yet checked.

## The machine

| | |
|---|---|
| Board | Gigabyte X870E AORUS ELITE WIFI7, AMI UEFI F2 (2024-08-14) |
| CPU | AMD Ryzen 9 7900X (Zen 4, Raphael; family 0x19, model 0x61): 12 cores, 24 threads, one socket |
| Memory | about 93 GiB visible |
| GPUs | GeForce RTX 4070 (AD104, Ada, `10de:2786`), NVIDIA's open kernel module 615.71; Radeon 610M integrated (Raphael, `1002:164e`), `amdgpu` |
| Network | Realtek RTL8125 2.5 GbE (`10ec:8125`, rev 0c, Linux's `r8169`); MediaTek MT7925 Wi-Fi 7 |
| Storage | Samsung 980 PRO 2 TB NVMe; two WD 8 TB and one HGST 6 TB SATA disks |
| USB | AMD xHCI ×3 on the SoC, two on the chipset; ASMedia ASM4242 USB4 (host router and xHCI) |
| Other | TPM 2.0; Gigabyte WMI (`gigabyte_wmi`) |

## Against what we have

- **Firmware:** UEFI with ACPI: APIC, DSDT, 15 SSDTs, FACP, HPET, MCFG,
  IVRS, VFCT, TPM2, BGRT, FPDT, FIDT, HWIN, WDRT, WPBT, WSMT. **No SPCR
  and no DBG2**, as on brimstone. The BIOS is from 2024; a newer one may
  carry AGESA and IOMMU fixes, to check before bring-up.
- **CPU baseline:** far above D52's `-march=ivybridge`: AVX2, FMA,
  AVX-512 (F, VL, BF16, VNNI, VBMI2), VAES, VPCLMULQDQ, SHA, and user
  shadow stacks, all run-time options under D52. `cppc` is listed, so
  ACPI CPPC drives frequency.
- **Timers:** no TSC-deadline mode (the flag is absent, as on every AMD
  part), so croi uses the LAPIC one-shot timer (`boot-smoke-apic-oneshot`,
  cpu.md). ARAT is present.
- **x2APIC:** not listed in the CPU flags, so firmware leaves the machine
  in xAPIC mode, as on brimstone. croi uses x2APIC only when CPUID offers
  it, else xAPIC (cpu.md).
- **IOMMU:** AMD-Vi, one IVHD, with interrupt remapping and the virtual
  APIC enabled under Linux; extended features PPR, NX, GT, IA, GA, PC,
  GA_vAPIC (kernel log), the same set as brimstone's. croi's AMD-Vi (K12b)
  and its interrupt remapping are tested only in QEMU.
- **Network:** the RTL8125 is the same family as brimstone's Killer E3000
  and the Orange Pi 5 Plus's RTL8125B, so the one Realtek driver the V3
  link needs covers this machine too.
- **GPUs:** both meet D62's floor. The Radeon 610M is RDNA 2 (memory), a
  UMA GPU; the RTX 4070 is Ada, newer than Turing, a discrete GPU with
  12 GB of VRAM (memory) and resizable BAR enabled (BAR1 is 16 GiB). So
  this machine has both of D56's memory models, like brimstone. The 4070
  is a second NVIDIA generation for D62's NVIDIA row after brimstone's
  Blackwell: both run their firmware on a GSP.
- **Thermals:** an ordinary desktop. Only `k10temp` and `gigabyte_wmi`
  are loaded; the board's Super I/O (memory: an ITE part) runs the fans,
  and no driver for it is loaded. None of the Mac Pro's rules apply.

## Why it is worth booting

- **The same hardware paths as brimstone without stopping development.**
  AMD-Vi with interrupt remapping, the LAPIC one-shot timer, ACPI on a
  real AMI firmware and an RTL8125 can be brought up here on any day the
  machine is free, while brimstone keeps building and benching.
- **Zen 4 beside brimstone's Zen 5:** two AMD generations, and two NVIDIA
  ones (Ada and Blackwell), for the desktop GPU track when it starts.
- **It can drive brimstone's bring-up** when it is running Fedora: it is
  the "other AMD Fedora box" brimstone's notebook names, with the same
  toolchain needs. It can't do both at once.

## Ground rules

- **From a USB stick only.** The NVMe and the three SATA disks hold its
  Linux workloads and their data; nothing VectraOS runs writes to them.
- **Boots happen when the owner frees the machine,** since it runs other
  workloads when powered up. A boot is never started from a session on
  the machine itself.
- **A metal run is not a bench history entry:** this host has no
  `bench/history/` file, and a run here is a separate measurement.

## The console problem

The same as brimstone's: no SPCR, no DBG2, and Linux found no 16550 (the
kernel log has no `ttyS` line). croi's loader falls back to COM1, which
isn't there, so a boot is blind until there is a GOP text console
(roadmap V6, item 5), a PCIe serial card whose address the loader is
told, or V3's link over the RTL8125. The GOP framebuffer is the RTX
4070's while it is the boot display (memory).

## On the machine

- With root: `acpidump` (the DSDT and SSDTs, the IVRS, whether a COM port
  is described), `dmidecode` (the DIMMs), and the Super I/O's identity.
- The firmware's x2APIC and IOMMU options, whether a COM header is on the
  board, and which GPU the firmware uses for the boot display.
- A BIOS newer than F2, if Gigabyte has one.
