# PC: MSI MS-7D25, Core i7-12700KF, Radeon RX 6750 XT

An ordinary desktop PC, available as a bring-up target (owner,
2026-10-16). It is AbyssBSD's desktop bring-up machine, where FreeBSD
15.0 runs a desktop on the RX 6750 XT today. It is a research row in
`docs/hardware/support.tsv`; no milestone names it yet.

Facts are marked with their source. Facts marked **(memory)** are not yet
checked against a document or the machine; **On the machine** lists what
to read first.

| Source | Commit or date | Paths |
|---|---|---|
| AbyssBSD (`../AbyssBSD`) | `bfc0b05` (2026-10-09) | `desktop/docs/PHASE4.md` §1.1, §5 |

## The machine

| | |
|---|---|
| Board | MSI MS-7D25 (LGA 1700), AMI UEFI (AbyssBSD) |
| CPU | Core i7-12700KF, 20 threads, up to 5.0 GHz; KF, so no integrated graphics (AbyssBSD) |
| GPU | Radeon RX 6750 XT: Navi 22, RDNA 2 (AbyssBSD) |
| Memory | 128 GiB (AbyssBSD) |
| Network | Intel I225/I226 2.5 GbE, FreeBSD's `igc0` (AbyssBSD) |
| Storage | about 900 GB, FreeBSD's ZFS root (AbyssBSD) |
| Display | AOC AG271QG4, 2560×1440 at 60 Hz (AbyssBSD) |

## Against what we have

- **CPU baseline:** Alder Lake is a superset of D52's `-march=ivybridge`
  (D52: any x86 since Haswell is). Hybrid cores, 8 P-cores with
  hyperthreading and 4 E-cores (memory), so per-CPU capacity (K3) matters
  here from the first boot. AVX-512 is off on Alder Lake (memory), which
  D52 already treats as a run-time option.
- **Platform:** UEFI and ACPI, with VT-d (memory), which croi drives in
  QEMU (K12a, K12f). No Apple firmware quirks: AbyssBSD's FAT16 stick
  image boots here too (PHASE4 §5).
- **GPU:** RDNA 2 is todhchai's stated floor, so the RX 6750 XT is the
  first device behind D62's desktop AMD row. Resizable BAR would make it
  D56's "discrete, with BAR" case beside the Mac Pro's "without BAR"
  (memory; on the machine).
- **Network:** the V3 link here needs an `igc` driver (I225/I226) in the
  net class.
- **Thermals:** an ordinary desktop with the board's own fan control, so
  none of the Mac Pro's rules apply.

## Ground rules

- The machine is shared with AbyssBSD: it boots VectraOS from a USB stick
  and leaves the internal disk alone until a decision says otherwise.

## On the machine

- A console: whether the board has a COM header (croi's loader falls back
  to COM1 on PCs) or a PCIe serial card is needed; otherwise the GOP
  framebuffer and V3's link.
- The ACPI tables (`acpidump`): the DMAR, the MADT's core types, the
  SPCR if any.
- `pciconf -lv`: the I225/I226's revision, the GPU's BARs and whether
  resizable BAR is on.
