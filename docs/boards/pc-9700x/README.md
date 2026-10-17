# PC: ASRock B650E Taichi Lite, Ryzen 7 9700X (brimstone)

A research pass (2026-10-16), not a board decision. This is `brimstone`,
the development host: the machine that builds VectraOS, runs its QEMU
tests, and holds the bench history (`bench/history/brimstone.tsv`). It
is a candidate bring-up target too, with one large catch: booting it
into VectraOS takes the development host down (Ground rules).

Facts were read on the machine under Fedora 44 (Linux 7.2.10), without
root, from `/sys`, `/proc/cpuinfo`, `lspci` and the kernel log, on
2026-10-16. Facts marked **(memory)** are not yet checked.

## The machine

| | |
|---|---|
| Board | ASRock B650E Taichi Lite, AMI UEFI 3.20 (2025-02-21) |
| CPU | AMD Ryzen 7 9700X (Zen 5, Granite Ridge): 8 cores, 16 threads, one socket |
| Memory | 2 DDR5 DIMMs (`spd5118` ×2), about 46 GiB visible |
| GPUs | GeForce RTX 5070 Ti (GB203, Blackwell, `10de:2c05`), the boot display; Radeon 610M integrated (Granite Ridge, `1002:13c0`) |
| Network | Realtek "Killer E3000" 2.5 GbE (`10ec:3000`, rev 06, Linux's `r8169`); Intel AX210 Wi-Fi 6E |
| Storage | Samsung NVMe (`144d:a80c`), SanDisk SN570 NVMe (`15b7:501a`), AMD and ASMedia SATA |
| USB | AMD xHCI ×3 on the SoC, one on the chipset; Intel Maple Ridge Thunderbolt 4 (NHI and xHCI) |
| Other | AMD PSP/CCP, TPM 2.0 |

## Against what we have

- **Firmware:** UEFI with ACPI: APIC, DSDT, 14 SSDTs, FACP, HPET, MCFG,
  IVRS, VFCT, TPM2, BGRT, FPDT, FIDT, WSMT. **No SPCR and no DBG2.**
- **CPU baseline:** far above D52's `-march=ivybridge`: AVX2, FMA,
  AVX-512 (F, VL, BF16, VNNI), VAES, VPCLMULQDQ, SHA, and user shadow
  stacks, all run-time options under D52. `cppc` is listed, so ACPI CPPC
  drives frequency (the power service's job, as on the Sky1).
- **Timers:** AMD has no TSC-deadline mode (the flag is absent), so croi
  uses the LAPIC one-shot timer, tested in QEMU (`boot-smoke-apic-oneshot`,
  cpu.md). ARAT is present, so the APIC timer keeps running in deep idle.
- **x2APIC:** the CPU flags don't list it, and the kernel log has no
  x2APIC line, so firmware seems to leave the machine in xAPIC mode
  (memory: Zen 5 has x2APIC; a firmware option may enable it). croi uses
  x2APIC only when CPUID offers it, else xAPIC (cpu.md).
- **IOMMU:** AMD-Vi, one IVHD, with interrupt remapping enabled under
  Linux; extended features PPR, NX, GT, IA, GA, PC, GA_vAPIC (kernel log).
  croi's AMD-Vi (K12b) and its interrupt remapping are tested only in
  QEMU; this would be their first hardware.
- **Network:** the Killer E3000 is Realtek's RTL8125 family (Linux drives
  it with `r8169`; the exact part is memory). The Orange Pi 5 Plus
  (RTL8125B) and the Orange Pi 6 Plus (RTL8126) use the same family, so
  one Realtek net-class driver would give the V3 link three machines.
- **GPUs:** both meet D62's floor: the Radeon 610M is RDNA 2 (memory) and
  the RTX 5070 Ti is Blackwell, newer than Turing. The 610M is a UMA GPU
  and the 5070 Ti a discrete one with its own VRAM, so this one machine
  has both of D56's memory models. The RTX 5070 Ti is the first device
  behind D62's NVIDIA row.
- **Thermals:** an ordinary desktop. The board's Super I/O runs the fans
  (no Linux driver is loaded for it here; memory: a Nuvoton part), and
  the CPU throttles itself. None of the Mac Pro's rules apply.

## Why it is worth booting

- **Real hardware for the budgets that are hardware targets.** V1 closed
  the `channel_call` < 1 µs item as a hardware target (about 1.3 µs under
  KVM, roadmap V1 item 6). The bench measures that under KVM on this very
  CPU, so booting croi on its metal measures the same budget with the
  hypervisor removed, on hardware the history already describes.
- **First hardware for croi's amd64 paths:** AMD-Vi with interrupt
  remapping, the LAPIC one-shot timer, ACPI on a real AMI firmware.

## Ground rules

- **It is the development host.** A VectraOS boot stops every build, QEMU
  test, bench run and agent session on it. Boots happen only when the
  owner schedules them, never from a session on the machine itself.
- **Its bring-up is driven from another machine** (owner, 2026-10-16): the
  Mac Studio, or another AMD Fedora box on the network, builds the images
  and, once V3's link exists, holds the SSH session and `vx remote boot`.
  - **The Fedora box works as it is:** the same toolchain (swiftly,
    `.swift-version`), CMake, Ninja, QEMU and edk2.
  - **The Mac Studio needs work first:** `vx` and `idlc` import Glibc in
    every file (`tools/vx/*.swift`, `tools/idlc/main.swift`), and
    `tools/qemu.sh` takes edk2 from a Linux path, so the host tools build
    only on Linux today. The choices are porting them to Darwin (the
    calls are POSIX: `posix_spawn`, `clock_gettime`, `waitpid`), or a
    Linux VM on the Mac.
  - The bench history is per host, so the driving machine gets its own
    `bench/history/<host>.tsv`; brimstone's stays its KVM record.
- **From a USB stick only.** Both NVMe drives and the SATA disks are
  Fedora's; nothing VectraOS runs writes to them.
- **No bench recording around a boot:** `vx bench --record` refuses a busy
  machine anyway; a metal run is a separate measurement, not a history
  entry.

## The console problem

The board has no serial port the firmware knows of (no SPCR, no DBG2,
and Linux finds no 16550). croi's loader falls back to COM1 on PCs, which
isn't there, and croi draws only a test pattern on the framebuffer. So a
boot here is blind until one of these exists:
- **A GOP text console:** already planned for the Q8B (roadmap V6, item
  5), and useful here first. The GOP framebuffer is the RTX 5070 Ti's.
- **A PCIe serial card** (a 16550-compatible one): the loader would need
  to be told its address, since no table describes it.
- **V3's link over the Killer E3000:** the long-term answer, which needs
  the Realtek driver.

## On the machine

- With root: `acpidump` (the DSDT and SSDTs, the IVRS, whether a COM port
  is described at all), `dmidecode`, and the Super I/O's identity.
- The firmware's x2APIC and IOMMU options, and whether a COM header is on
  the board (memory: this board has none).
- `lspci -vv` for the Killer E3000's exact part, and the GPUs' BARs
  (resizable BAR on the 5070 Ti).
