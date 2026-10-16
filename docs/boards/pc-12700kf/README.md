# PC: MSI PRO Z690-A DDR4 (MS-7D25), Core i7-12700KF, Radeon RX 6750 XT

An ordinary desktop PC, available as a bring-up target (owner,
2026-10-16). It is AbyssBSD's desktop bring-up machine, where FreeBSD
runs a desktop on the RX 6750 XT. It is a research row in
`docs/hardware/support.tsv`; no milestone names it yet. On the local
network it was at 192.168.0.31 on 2026-10-16 (its hostname is `freebsd`;
the address may change).

Facts are marked with their source. **(machine)** facts were read over
SSH under FreeBSD 15.1-RELEASE on 2026-10-16, with root through `doas`,
from `sysctl`, `kenv` (SMBIOS), `pciconf`, `geom`, `zpool`, `acpidump`,
`/var/run/dmesg.boot`, and the DBGP and DBG2 tables read from
`/dev/mem`. Facts marked **(memory)** are not yet checked against a
document or the machine.

| Source | Commit or date | Paths |
|---|---|---|
| AbyssBSD (`../AbyssBSD`) | `bfc0b05` (2026-10-09) | `desktop/docs/PHASE4.md` §1.1, §5 |
| The machine, over SSH | 2026-10-16 | FreeBSD 15.1-RELEASE (`releng/15.1-n283562`) |

## The machine

| | |
|---|---|
| Board | MSI PRO Z690-A DDR4 (MS-7D25, LGA 1700), AMI UEFI 1.00 (2021-09-14) (machine) |
| CPU | Core i7-12700KF: 8 P-cores with hyperthreading (CPUs 0–15) and 4 E-cores sharing one L2 (CPUs 16–19), 20 threads; KF, so no integrated graphics (machine) |
| GPU | Radeon RX 6750 XT: Navi 22 (`1002:73df`, rev c0), a Gigabyte card (`1458:2408`), PCIe 4.0 x16 behind Navi's own switch (machine) |
| Memory | 128 GiB DDR4 (machine: `hw.physmem`, the board's DDR4 variant) |
| Network | Intel I225-V 2.5 GbE (`8086:15f3`, rev 03), FreeBSD's `igc0`, MSI-X (machine) |
| Storage | Samsung 990 PRO 1 TB NVMe (the ZFS root, `zroot` on `nda1p4`); WD_BLACK SN850X 1 TB NVMe; Intel 240 GB SATA SSD; a SATA DVD writer (machine) |
| Display | AOC AG271QG4, 2560×1440 at 60 Hz (AbyssBSD) |

## Against what we have

- **Firmware:** UEFI with ACPI (machine): APIC, DSDT, 10 SSDTs, FACP,
  FIDT, HPET, MCFG, DMAR, DBGP, DBG2, VFCT, TPM2, BGRT (two), FPDT, LPIT,
  NHLT, PHAT, UEFI, WSMT. **No SPCR.** The BIOS is the board's first
  release (1.00, 2021); newer ones exist (memory). It has the resizable
  BAR option (owner enabled it, 2026-10-16).
- **CPU baseline:** Alder Lake is a superset of D52's `-march=ivybridge`:
  AVX2, FMA, BMI1/2, SHA, VAES, VPCLMULQDQ, GFNI, IBT, PKU (machine).
  **No AVX-512** (machine), as D52 allows. Hybrid cores, so per-CPU
  capacity (K3) matters here from the first boot.
- **Timers:** TSC-deadline mode is present (`TSCDLT`) (machine), so croi's
  usual Intel path applies.
- **x2APIC:** CPUID offers it, but the MADT lists only xAPIC entries (56
  Local APIC, no Local x2APIC), so firmware hands over in xAPIC mode
  (machine). croi switches to x2APIC when CPUID offers it (cpu.md).
- **IOMMU:** VT-d. The DMAR has one DRHD at `0xfed91000` with
  INCLUDE_ALL (no integrated GPU, so no second unit), interrupt remapping
  (`INTR_REMAP`), a 39-bit host address width, and the IOAPIC and HPET in
  its device scope (machine). croi drives VT-d in QEMU (K12a, K12f);
  this would be its first hardware. FreeBSD attached no DMAR unit
  (nothing in `dmesg.boot`).
- **GPU:** RDNA 2 is todhchai's stated floor, so the RX 6750 XT is the
  first device behind D62's desktop AMD row. **Resizable BAR is on**
  (owner, 2026-10-16): BAR0 is 16 GiB at `0x40_0000_0000`, BAR2 256 MiB
  at `0x44_0000_0000`, and `amdgpu` reports `VRAM RAM=12272M,
  BAR=16384M`, so all of VRAM is CPU-visible (machine). It was 256 MiB
  before. So this is D56's "discrete, with BAR" case, beside the Mac
  Pro's "without BAR"; turning the option off gives the other case on
  the same card. The card also offers PASID (machine).
- **FreeBSD's write-combining fails on the large BAR:** since the
  change, every boot logs `amdgpu_bo_init: Unable to set WC memtype for
  the aperture base`, absent from the 256 MiB boots before it (machine,
  `/var/log/messages`). That is FreeBSD's DRM port, not the hardware:
  croi maps write-combining per page through the PAT (boot.md), so the
  aperture's size doesn't limit it. Worth checking when our driver maps
  VRAM, all the same.
- **Network:** the V3 link here needs an `igc` driver (I225-V) in the net
  class.
- **Thermals:** an ordinary desktop with the board's own fan control, so
  none of the Mac Pro's rules apply.

## The console

Better than the AMD machines'. Both DBGP and DBG2 describe a full 16550
at I/O port `0x3f8`, COM1 (machine: DBGP interface type 0; DBG2 port
type `0x8000`, subtype 0, with namepath `.`). croi's loader falls back
to COM1 on PCs, which is the same port. But FreeBSD attached no `uart`,
so whether a COM header is wired on the board is unconfirmed (memory:
the PRO Z690-A has a JCOM1 header). Whether the DSDT describes a
`PNP0501` device is unknown until it can be disassembled.
If it is, a header cable gives a console from the first boot.

## Ground rules

- The machine is shared with AbyssBSD: it boots VectraOS from a USB
  stick and leaves the internal disks (both NVMe drives and the SATA
  SSD) alone until a decision says otherwise.

## On the machine

- Whether a COM header is wired (a cable on JCOM1, then a byte to
  `0x3f8`).
- The firmware's VT-d option (resizable BAR is on, above).
- The DSDT, which FreeBSD's `iasl` failed to disassemble here (exit
  status 255).
