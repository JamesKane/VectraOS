# D161. A devicetree's CPUs move through their operating points by power(8)'s steps: devmgr names their clocks' and supplies' drivers, and power writes each move to them (2026-11-02, the owner asked for the next driver; extends D130, D154 and D160)

D130 gave the CPUs' performance one keeper. power(8) reads devmgr's
`cpus`, writes each CPU's CPPC desired-performance register, and moves
every CPU in 8 steps, down while a zone is past its passive trip and
back up once every zone is clear. D160 gave the Orange Pi RV2's zones
to power(8), and so their passive trips at 85 °C. But a devicetree
machine has no `_CPC`, so a passive trip there throttled nothing.

On the SpacemiT K1 nothing stands between the OS and the clocks
(chinese-wall's spacemit-k1 14). Each cluster's core clock is an APMU
mux with a frequency-change handshake, and both clusters run from the
P1's BUCK1. Firmware leaves both at 1.6 GHz, the clusters' HI source
with PLL3 at 3200 MHz. PLL1 gives 614.4, 819.2 and 1228.8 MHz with no
PLL work, each at 0.95 V; 1.6 GHz needs 1.05 V.

## The decision

1. **The tree says what a CPU can run at:** a CPU node's `clocks`,
   its `cpu-supply`, and the `operating-points-v2` table it names,
   each point's `opp-hz` and its `opp-microvolt`'s target, as Linux's
   binding gives them. `DeviceTreeBus.cpus` reads them, the links'
   providers found as a device's are. Upstream's K1 tree, at our pin,
   has no table or `cpu-supply`. Our board file adds them from the
   spec's facts: four points and BUCK1. It leaves out the 1 GHz point,
   which is PLL2's: nothing reads PLL2's rate.
2. **devmgr's `cpus` gives them, a line a CPU, after ACPI's:**
   `<hart> <path> opp clock <service> <id> supply <service>
   <regulator> points <hz>/<uV> ...`, each service the driver that
   provides the link (`-` until it runs).
3. **power(8) moves them by its steps.** A step's point is the fastest
   at or below the rate as far from the slowest point toward the
   fastest as the step is toward 8, as a CPPC level is. CPUs on one
   clock are one domain. Each move is a list of writes to the
   providers' `ctl` files: every supply raised to the most its domains
   then need, then the clocks (`clock <id> rate <hz>`), then every
   supply lowered (`voltage <regulator> <uV>`). The first move, from
   firmware's unknown point, raises each supply to the most any point
   needs, unless the supply's driver already reads it there or above.
   A refused write stops the move, and the next one starts as from
   firmware's. power(8) takes these lines once devmgr has bound, when
   the providers run.
4. **The providers do only what each already does:** k1-syscon(3)
   sets a clock's rate, now the clusters' core clocks too. Their mux
   takes PLL1's three rates and HI, which it takes as 1.6 GHz while
   bit 13 picks PLL3 halved. p1(3) sets a regulator's voltage within
   its node's range. Neither knows about operating points. PLL3 isn't
   retuned, and the 1.8 GHz point isn't used.

No second governor is made: a devicetree's CPUs and CPPC's follow the
same 8 steps and the same zones. There is no cpufreq framework or OPP
library either; the tree's table is read where it is used.

## Consequences

- On the RV2 a zone at 85 °C now slows both clusters to 1228.8 MHz at
  0.95 V, and further each second it stays there, down to 614.4 MHz.
- The top point's rate is taken from the firmware's PLL3, which the
  APMU's driver can't read (it is the PLL unit's). board-test(8)
  checks it on the board: the chain of multiplies takes as many times
  longer at 614.4 MHz as 1.6 GHz is faster.
- Every CPU still moves together, as under CPPC.
