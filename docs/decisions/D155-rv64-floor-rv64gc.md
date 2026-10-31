# D155. rv64's floor drops to RV64GC with Zba and Zbb, so the VisionFive 2 runs; RVA22 becomes a tier, chosen once at startup (2026-10-31, decided by the owner; amends D51's baseline and D128's rv64 row)

D51 made RVA22 rv64's baseline, and D128 said what a board below it
would reopen, naming the StarFive VisionFive 2. The owner wants it, to
show VectraOS runs on a small, old board through fallbacks
(2026-10-31). Its JH7110 has four SiFive U74 harts and an S7 monitor
hart. Linux's `jh7110.dtsi` (`../linux` at `65ba8f34ec88`) lists each
U74 as `rv64imafdc_zba_zbb` with Zicntr, Zicsr, Zifencei and Zihpm,
Sv39, 64-byte cache blocks, and the S7 as `rv64imac_zba_zbb`, disabled,
with no `mmu-type`. So it has none of Zbs, Zicbom, Zicbop, Zicboz,
Zihintpause, Zfhmin, Svpbmt or Svinval, no Sstc and no V.

## The decision

- **The floor is RV64GC with Zba and Zbb** (RVA20 plus the two the U74
  has): `rv64gc_zba_zbb` for user code, and RVA20S64 with Zba and Zbb,
  Sv39, for the kernel and the loader. The loader refuses a hart below
  it and says which extension is missing, as it does now
  (`boot/Loader/Baseline.swift`, whose list shrinks to Zba and Zbb).
- **D128's rv64 row becomes:** floor `rv64gc_zba_zbb`; tier 2 RVA22U64;
  tier 3 RVA22U64 with V, at any VLEN. A routine names its tier, never a
  feature, as D128 says; the K1 is at tier 3.
- **The choice is made once, never per call** (the owner: "after boot we
  aren't testing for RVV or not"). User libraries take D128's tables:
  filled from the topology page's record before any constructor runs,
  then read only, so a U74 runs the floor's routines and never reaches
  a vector one, and no call asks. The kernel picks its paths the same
  way, once at boot before the other harts start: each a global set
  then and not written again (as `PageTableFormat.svpbmt` is now).
  Neither patches code: no mapping is writable and executable outside a
  JIT reservation.
- **The kernel's fallbacks, each chosen at boot:**

  | Missing | Fallback |
  |---|---|
  | Svpbmt | The PMAs decide memory types, as the kernel does now without it; `boot-smoke-no-svpbmt` stays, which D51 planned to remove |
  | Zicbom | Cache maintenance through the SoC's cache controller, from the tree (`sifive,ccache0`'s flush, a board rule under D126) |
  | Zicboz | Zeroing by stores |
  | Svinval | `sfence.vma` |
  | Zihintpause | No pause in spin loops |
  | Sstc | SBI TIME, else the legacy `set_timer` (ae66e82) |

- **What the K1 loses** is what the compiler would have done with Zbs,
  Zicbop, Zfhmin and Zihintpause in code outside the tables. It is
  measured on the RV2 against the RVA22 build before the floor changes
  in code; a budget that regresses is accepted in the open or answered
  with a tier routine (performance.md).
- **QEMU's floor run** (`boot-baseline`) takes an rv64 CPU with the
  RVA22 additions turned off; the run below it (`-cpu rv64,zba=false`)
  stays. Its exact spelling is the change's.

## Follow-ups, each its own change

1. The K1's cost, measured on the RV2 (`vx bench` profiles the change
   risks, no new ones).
2. `cmake/arch/rv64.cmake`'s user flags, the loader's list, and
   `boot-baseline`'s rv64 CPU.
3. D128's tables for rv64 at three tiers, with the suite checking each
   entry against the floor's.
4. The kernel's boot-time choices above, and the JH7110's cache
   controller as a board rule.
5. Whether the U74 takes misaligned loads in hardware, which the libc's
   rv64 copies assume they may not (D128's open question), on the board.
