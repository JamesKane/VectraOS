# D130. The power service sets CPU performance through ACPI's CPPC and keeps the thermal zones' trips: every CPU at its highest level, stepped down at a passive trip, the machine off at a critical one; devmgr evaluates the AML (2026-10-24, the owner's choice of home, policy and protection; begins D68's power service)

On the Orange Pi 6 Plus nothing set the CPUs' clocks: VectraOS ran at
whatever level firmware left. m2's timings came out 3-5 times slower
than expected, and on the desktop Tracker took seconds to draw a menu
at 1920x1080 (a profile: UICore's shape filling); the board notes
guessed firmware left the CPUs at their lowest level, 800 MHz. It
didn't: a chain of 5M dependent multiplies took 5.5 ms at firmware's
level and 4.3 ms at the highest, 1.28 times faster, so firmware's
level is well above the lowest and those slowdowns have other causes.
The service is still needed: firmware's level isn't the highest, and
the thermal zones are the OS's to act on. The kernel roadmap's
"Cross-cutting: AML" and D68 put CPU performance and thermal policy in
a user-space power service, since `_CPC` and the thermal zones are AML
and the kernel runs none; the board notes add that this board's
thermal zones (13, passive at 85 °C, critical at 98 °C) are the OS's
to act on, and that until a service does, only firmware cools it.

**What the Sky1's firmware gives.**
- Each CPU's `_CPC` (revision 3): highest and nominal performance 8192
  on the A720s, lowest and lowest nonlinear 2520, lowest frequency 800
  MHz and nominal 2600; the desired-performance register in
  SystemMemory, 32 bits, one a CPU, all in mailbox 6's page
  (`0x06590000`), SCMI's fast channels; reference and delivered
  counters in FFixedHW (the AMU). No minimum, maximum, guaranteed or
  enable registers. `_PSD` pairs the CPUs, SW_ANY.
- Each zone's `_TMP` asks firmware for a sensor reading through the
  AML's own SCMI agent (`\_SB.PMMX`, its own mailbox at `0x065D0000`,
  not scmi(3)'s), and gives tenths of a kelvin; `_TZP` asks for 5 s.

**The decision (the owner's, 2026-10-24).**
- **A power service, `services/power`, not scmi(3).** CPPC is ACPI's
  interface on every machine that has it (the Sky1's fast channels,
  AMD's and others' MSRs or PCC); SCMI's performance protocol is one
  board's transport under it. The service is where D68's capacities and
  KP's frequency floor will come from.
- **devmgr evaluates the AML.** It alone holds the namespace (and its
  lock), so it serves two read-only files, `cpus` (each processor's
  `_CPC` and `_PSD`, decoded) and `thermal` (each zone's `_TMP`, `_PSV`,
  `_CRT` and `_TZP`, evaluated when read). No AML runs in the service,
  and no other process gets the namespace.
- **Registers by MMIO resource.** The service's manifest grants
  `resource mmio`; it carves each desired register's page from it and
  maps it uncached (DriverHost's `Registers.map`). A register in another
  space (PCC, FFixedHW) isn't written yet.
- **The first policy: highest, thermally capped.** Every CPU at
  `_CPC`'s highest level; the zones read at their shortest `_TZP`, at
  most a second apart; a step down (8 steps from lowest to highest)
  each reading while a zone is at or above its passive trip, a step up
  each reading once every zone is 5 °C below its own. A demand-based
  governor (lowering idle CPUs, through the AMU's counters) comes with
  KP.
- **Protection ships with it.** A zone at its critical trip powers the
  machine off through devmgr's `/dev/reboot`. Zones that exist but don't
  read keep every CPU at lowest (fail safe); a machine without zones
  (QEMU; a PC whose firmware cools it) runs at highest.

**Tests.**
- Host: the Sky1's real `_CPC` and `_PSD` decoded (DevMgrTests), the
  service's parsing, levels and clocks, the steps around the passive
  trip, the critical power-off and the unread-zones floor (PowerTests).
- boot-board (QEMU): power says there is no CPPC; board-test checks it.
- On the board, board-test: every CPU with a register in memory asked
  for its highest level, and every zone read. First run: 12 CPUs, 5
  domains, 1800-2600 MHz at highest, the 13 zones at 43-49 °C; the
  service's chain 5.5 ms at firmware's level, 4.3 ms after.
- Not tested: the passive steps and the critical power-off by heat on
  the board.

**Not now.** A governor and frequency invariance (D68, KP); capacities
from `_CPC`'s highest levels (D68's CAPACITY updates); `_PSD`'s domains
(every CPU moves together); active cooling and `_HOT`; the AMU's
counters to report the clock delivered (the service times a chain of
dependent multiplies instead).
