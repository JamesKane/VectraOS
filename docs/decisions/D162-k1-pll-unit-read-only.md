# D162. The K1's PLL unit is read, never changed: a third unit of k1-syscon, whose rates the APMU's driver takes for its clocks' parents (2026-11-02, the owner asked for the PLLs; extends D154 and D161)

The APMU's clocks have the PLL unit's outputs as parents: PLL1's for
nearly every peripheral, PLL2's for some of the SDHCIs' and the
clusters' 1 GHz, and PLL3's for the clusters' HI source. k1-syscon
didn't read the PLL unit, so it knew only PLL1, whose rate every
peripheral tree assumes, and D161 took the clusters' 1.6 GHz on trust:
PLL3 at the 3200 MHz the board's firmware leaves it, which board-test
checked only by timing.

On the Orange Pi RV2 the unit reads as follows:
- **PLL2:** at 3000 MHz with only its D8 output on (SWCR2 `0x80`).
- **PLL3:** at 3200 MHz with only D2 on (`0x2`).
- **PLL1:** its configuration is the table's, but its SWCR3 bit 31 (the
  spec's "running") reads 0 though it runs.

## The decision

1. **The PLL unit (`spacemit,k1-pll`) is a third unit of k1-syscon,**
   by the same driver record and program. It has no clocks or resets
   of its own here, and its `ctl` takes nothing. It reads each PLL's
   rate by matching its configuration against the spec's table
   (chinese-wall's spacemit-k1 01 §1.4.5), and whether each of PLL2's
   and PLL3's outputs D1 to D8 is gated on. It serves these as
   `rates`. PLL1 is taken at its one rate, 2457.6 MHz, whatever its
   registers say.
2. **Nothing changes a PLL.** PLL1 and PLL2 feed nearly every clock.
   Retuning PLL3 for 1.8 GHz would need the CPUs moved off it first,
   and a voltage the board's tree doesn't allow BUCK1.
3. **The APMU links to it by an implied link,** `clock pll`, since
   upstream's tree has the APMU name none (the bus's `implied`, as for
   the K1's PCIe PHYs' calibration). devmgr starts the PLL unit's
   driver first and mounts its tree at the APMU driver's
   `/dev/provider`. The APMU's driver reads `rates` once, at its
   start: the rates don't change. Without them it knows PLL1 alone, as
   before.
4. **A rated clock's parent is a PLL's output by name:** PLL1 divided,
   PLL2's or PLL3's D *n*, or a cluster's HI (PLL3's D2 or D1 by bit
   13). A rate is made only from a parent whose rate is known and
   whose output is on.

## Consequences

- The clusters' 1.6 GHz is PLL3's D2 as its registers give it.
  board-test's chain still checks it: 2.60 times as long at 614.4 MHz.
- The tree keeps four points: PLL2's D3 is off on the RV2, so 1 GHz
  can't be made, and turning an output on is changing the PLL unit.
- An SDHCI rate from PLL2's D8 (375 MHz, or a divisor of it) can now be
  set. Its D5 is off.
