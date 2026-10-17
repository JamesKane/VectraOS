# PCI over ECAM

`PCI` (`lib/`), lifted from todhchai (D74, V2 item 7b): configuration
space as a `ConfigSpace` (ECAM's window, or a test's model), every
function reachable from a root bus (multi-function devices, the buses
behind bridges, each followed once), each function's identity, its BARs
sized as the specification has it (all ones written with decoding off,
the mask read back, everything restored) and its capability list (at
most 48 entries, so a looped list ends). Tier 0, so devmgr (item 7c)
runs it on the device. ECAM only: q35 and both virt machines have it,
and there is no 0xCF8 port access (D74).

ECAM's registers are reached through the runtime's accessors
(`user/include/croi/mmio.h`, module CroiMMIO: volatile 8-64-bit loads
and stores), not Swift's experimental `_Volatile`, which todhchai's
used. The MCFG table itself is TDACPI's (`drivers/bus/acpi`). Its base
address is bus 0's, so a window starting at bus N begins N MiB in.

**Tests.** `PCITests` (hosted, `swift test`): enumeration, BAR sizing
and restoring, capability walks and loops over a model that answers as
hardware does; ECAM's addressing over a buffer; and q35's MCFG from the
ACPI corpus (`vx acpi fetch-qemu`, skipped without it). Natively,
`bin/pci-test` (the boot-pci test, every arch) maps the window the
boot's MCFG gives and enumerates what qemu.sh attaches: the host bridge,
edu at 00:10.0, virtio-blk and virtio-rng, and on rv64 the RISC-V IOMMU
at 00:08.0.
