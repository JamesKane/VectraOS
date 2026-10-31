# D51. The rv64 board: Orange Pi RV2 (Ky X1), and RVA22 as rv64's baseline (2026-10-16, decided; firmware 2026-10-30)

rv64 has run only in QEMU, and no board was named for it. The owner has
an Orange Pi RV2 on hand. Its SoC, sold as the Ky X1, is the SpacemiT K1:
8 X60 harts that implement RVA22 with V (`docs/boards/orangepi-rv2/`,
from Linux's `k1.dtsi` and FreeBSD's SpacemiT support).
- **The RV2 is the rv64 board** (owner's call). It comes after the Q8B,
  which stays the first board (D5): roadmap V4b, on V3's link.
- **RVA22 is rv64's baseline** (owner's call): RVA22S64 for the kernel
  and the loader, RVA22U64 for user code. Code may assume what the
  profile makes mandatory (Zba, Zbb, Zbs, Zicbom, Zicbop, Zicboz,
  Zihintpause, Zfhmin, Svpbmt, Svinval among them) and probes for what it
  leaves optional (V, Sstc, Sscofpmf, Svnapot, Sv48, Ssaia, an IOMMU).
  RVA23 would exclude the K1 (no Zcb, Zfa, Zawrs, Zvbb). A board below
  RVA22, such as the VisionFive 2's U74, would reopen this floor; D128
  says what that would take.
- **What follows in code,** each its own change, not this entry:
  `cmake/arch/rv64.cmake`'s `-march` (today `rv64imac_zicsr_zifencei`,
  "RVA20-ish") and the user flags take the profile's extensions; QEMU's
  rv64 runs use `-cpu rva22s64` as the floor beside `-cpu max`; the
  Svpbmt fallback and `boot-smoke-no-svpbmt` (`-cpu rv64`) go, since no
  baseline hart lacks Svpbmt; the loader refuses a hart whose ISA string
  is below the profile and says which extension is missing.
- **The K1 lands on paths the kernel already has:** Sv39, the PLIC (no
  AIA) and the SBI timer. What it lacks needs board work: no IOMMU (DMA
  through BTIs without one, with per-bus windows and an offset above the
  2 GiB hole), and PCIe MSIs through DesignWare's MSI block instead of
  IMSICs.
- **Open: the firmware path.** The shipped chain (FSBL, OpenSBI, U-Boot)
  gives a devicetree, and no ACPI tables are known for the K1. The kernel
  is ACPI-only (architecture §2), which says a DT-only board needs its own
  decision. The candidates are firmware that provides ACPI (EDK2 or
  U-Boot's EFI, with K1 tables we write and ship as a firmware artifact)
  and a loader that reads the DTB and fills the handoff, so the kernel
  never sees DT. A kernel DT path is not a candidate. The owner decides
  before V4b starts; until then, nothing assumes either answer.
- **Research for that decision (2026-10-16):** the ACPI candidate has
  parts to build on (`docs/boards/orangepi-rv2/`, "Toward ACPI
  firmware"). SpacemiT ships EDK2 for a K1 board (the MUSE Pi Pro;
  DT only, no ACPI yet) and full static ACPI tables for its K3, and
  upstream EDK2's `DynamicTablesPkg` makes a RISC-V MADT and RHCT from a
  DT, once its PLIC parser accepts the K1's compatible string. That
  candidate is an RV2 port of the K1 EDK2, with tables generated or
  written from the K3's, built on the host and flashed to SPI NOR as a
  firmware artifact. U-Boot makes no RISC-V tables of its own. The
  loader candidate stays the fallback if the port stalls on the board's
  FSBL or SPI NOR layout.
- **Decided: the loader reads the DTB first** (the owner, 2026-10-30).
  The shipped chain stays on SPI NOR, and a card holds the ESP. The
  loader takes the DTB that U-Boot's EFI passes as a configuration
  table and fills the handoff from it, so the kernel stays ACPI-only and
  never sees DT. Firmware with K1 ACPI tables can follow without
  changing the kernel. The shipped chain, as found on the board, is in
  the RV2 notebook.
