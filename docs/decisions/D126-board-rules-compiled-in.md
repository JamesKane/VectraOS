# D126. Board rules are compiled into the kernel and chosen by the firmware's identity (the FADT's OEM ID and table ID); a part's errata are keyed on its own ID register (2026-10-24, the owner's choice the same day; replaces the kernel roadmap's "handoff v4 from an ESP file")

A board can need what its firmware's tables don't say: the CIX Sky1's
SBSA watchdog refreshes only through a write of WOR, and its two SMMUv3
are left enabled for the OS to take over with the IORT's RMRs. croi is
ACPI-only, so the kernel roadmap sketched these as "board rules" in a
handoff v4, read by the loader from a file on the ESP keyed on SMBIOS
or the SoC.

## The decision

- **Compiled in.** `BoardRules` (kernel/Kernel/BoardRules.swift) names
  the boards croi knows and what each needs, as Linux's ACPI quirk
  tables do. No file format, no loader parsing, no handoff version: a
  rule changes with a rebuild, which is cheap here.
- **Keyed on the firmware's identity**: the FADT's OEM ID and OEM table
  ID, which the kernel reads anyway. The Sky1's firmware says `CIXTEK`
  / `SKY1EDK2`; QEMU's says `BOCHS `. The boot line names the board and
  the rules it takes (`board:`).
- **A part's errata are keyed on the part**, not the board: the GIC's on
  its IIDR (as Linux's GIC quirks are), where the GIC is handled.

## Rules today

- The Sky1: the watchdog is refreshed by writing WOR
  (`SbsaWatchdog.RefreshMethod.offsetRegister`). Checked on the Orange
  Pi 6 Plus: 100 s without the reset that came at 30 s before.
- QEMU: none; the interrupts suite's RTC check runs only on its
  machines.
- The Sky1: its PCIe SMMUv3 (0x0B010000), left enabled by firmware and
  needing no RMR, is taken over (GBPA abort, CR0 off, then bypass
  entries). Its display unit needs no rule: firmware leaves it disabled,
  and its framebuffer RMR is honored as every IORT's is (iommu.md).
