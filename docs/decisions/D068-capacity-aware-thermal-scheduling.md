# D68. The scheduler places by capacity and topology; thermal limits reach it as capacity (2026-10-16, proposed; the cpu_set_info merge decided; placement by capacity, racing to completion, decided 2026-10-26)

croi's scheduler (K3, `docs/kernel/design/cpu.md`) gives each CPU a
capacity, charges deadline budgets in capacity-scaled time and admits
reservations by capacity, as Zircon does. Its fair class doesn't use
either. Most machines in the corpus have unequal cores, and AbyssBSD's
Q8B and Sky1 work shows thermal limits changing what a core can do while
it runs. This entry extends K3; it is not a new scheduler.

**What the corpus has** (`docs/boards/`, AbyssBSD at `bfc0b05`):

| Machine | Cores | Capacity source | Thermal |
|---|---|---|---|
| Q8B (first board) | 4 A78C up to 2.44 GHz, 4 X1C up to 3.0 GHz | none in ACPI (no `_CPC`); EPSS's frequency tables | TSENS per core and cluster; LMh clips the X1Cs to 2.80–2.90 GHz under full load by itself; the ADSP runs the fan |
| Sky1 | 4 A720 at 2.6 GHz, 4 A720 at 2.5 GHz, 4 A520 | `_CPC` | 13 ACPI zones, passive from 85 °C |
| RK3588 | 4 A76, 4 A55 | core type | not yet read |
| i7-12700KF | 8 P-cores with SMT, 4 E-cores sharing an L2 | core type; HFI | HFI and Thread Director, 4 classes (CPUID read on the machine) |
| Mac mini M4 | 4 P, 6 E | none (no ACPI) | |
| Ryzen 9 7900X, 9700X | equal cores; the 7900X has two L3s | CPPC | |
| K1 (RV2) | 8 equal harts in two clusters with their own L2 | core type | |
| Mac Pro | equal cores with SMT | core type | D63's rules |

**What K3 gets wrong today:**
- A running fair thread never moves to a bigger CPU. `steal` takes only
  queued threads, so a CPU-bound thread alone on an A55 or an E-core
  stays there while big cores idle.
- `place` takes the first idle CPU from the thread's last one, whatever
  its capacity.
- `steal` picks the CPU with the most queued fair threads, whatever its
  capacity, cluster or cache.
- The PPTT topology (`CpuTopology`: package, core, last-level cache,
  thread) is parsed but only the vDSO reads it.
- `CoreCapacity` lacks the A78C (`0xD4B`) and X1C (`0xD4C`), so the
  Q8B's two clusters both default to 1024. The Sky1's two A720 tiers
  share a part number, and Apple's cores aren't in the table.
- `setCapacity` has no system call: only `DeadlineSelfTest` calls it.
- Nothing reacts when a CPU's capacity falls below the deadline work
  admitted on it.

**The decision:**
- **Each CPU has three capacities,** each scaled so the biggest core
  present is 1024:
  - *original*: what the core does at its top performance level, from the
    core type, `_CPC`'s highest performance, or a board's own tables
    (the Q8B's EPSS);
  - *sustained*: what it holds indefinitely in this machine's cooling;
    admission counts against it; it defaults to original;
  - *available*: what it does now, under thermal and power limits
    (Linux's "thermal pressure" is original less available); placement,
    misfit pulls and deadline charging use it; it defaults to original.
- **Fair placement uses available capacity and topology.**
  - `place` prefers, in order: the thread's last CPU if idle; an idle
    CPU whose available capacity fits the thread's recent demand; an
    idle whole core before an idle SMT sibling of a busy one; the same
    last-level cache (cluster, CCD) before the same package before any.
  - A thread's demand is its share of the time it was runnable, decayed
    as Linux's utilization is; one that used its whole slices is
    *misfit* on any CPU smaller than the biggest available.
  - **A misfit pull:** a CPU that goes idle, or at its tick finds itself
    idle, takes a misfit thread that is *running* on a smaller CPU, not
    only a queued one. It asks the source CPU by IPI to switch the
    thread out, the way a stolen thread is requeued today.
  - `steal` weighs a source's waiting work by its capacity and prefers
    sources in its own cache domain.
  - Equal-capacity machines lose nothing: the capacity tests tie, and
    only topology orders the choice.
- **Deadline work keeps K3's rules.** Admission picks the biggest
  *sustained* capacity that fits under the 85% bound; admitted threads
  don't migrate; budgets are charged in *available* capacity.
- **Overcommit is reported, not repaired, by the kernel.** When a CPU's
  admitted utilization, in its available capacity, passes 100%, the
  kernel keeps EDF order (misses fall on the latest deadlines), counts
  the overcommit, and reports it through `object_bind` on the POWER
  resource: a new persistent kind, OVERCOMMIT, with one coalescing
  packet naming the CPUs, like the root account's PRESSURE (D31). The
  power service decides: raise cooling, move reservations by
  re-admitting them, or tell their owners. One binding at a time, as
  with PRESSURE.
- **One call sets CPU properties in batches.** `cpu_set_idle_states`
  (245) becomes `cpu_set_info(resource, topic, items, count)`, as
  Zircon's `zx_system_set_performance_info` takes a topic. Topics:
  IDLE_STATES (today's call, per CPU) and CAPACITY (an array of CPU,
  original, sustained, available; any field may be "unchanged"). One
  call updates every CPU a thermal event touched (principle 12). The
  syscall count doesn't change. This merge is decided (owner,
  2026-10-16); the rest of this entry is proposed.
- **Thermal policy stays in the power service.** It reads the sources
  and decides capacities; the kernel only applies them. Per source:
  - Q8B: EPSS's `domain_state` level (it drops when LMh throttles) and
    TSENS, through user-space drivers (no `_CPC`, `_TMP` or `_PSS`);
  - Sky1: `_CPC` and the ACPI thermal zones' passive trips (AML, which
    stays in user space);
  - AMD: CPPC's highest performance and preferred-core ranking;
  - Intel hybrid: HFI. **Open:** the HFI table needs an MSR write and
    the package thermal interrupt, which only the kernel can do. Either
    the kernel maps the table to the power service read-only and binds
    the interrupt to its port, or the kernel reads the table itself and
    applies it as a CAPACITY update. The first keeps one path for every
    source; the second saves a round trip. To decide when the 12700KF's
    bring-up starts.
- **The core-type defaults are fixed now:** the A78C, X1C, X1, A715,
  A720, A725, X4 and X925 get entries scaled for their usual clocks
  (Linux's `capacity-dmips-mhz` times top frequency is the reference:
  the Q8B's A78C comes to about 780 against the X1C's 1024). Apple and
  unknown parts stay at 1024 until something better is known.
- **Not now:**
  - frequency invariance below the thermal ceiling, from APERF/MPERF,
    arm64's AMU or CPPC's delivered and reference counters: KP, beside
    the frequency floor, which already covers admitted deadline work;
  - Thread Director classes in placement: once there is a way to
    measure the gain;
  - an energy model (Zircon has one): none of the first targets runs on
    a battery;
  - placing work away from the hottest core: research.
- **Tests (Swift suites and kernel self-tests):** QEMU has no unequal
  cores, so the tests make them with CAPACITY updates, as
  `DeadlineSelfTest` does with `setCapacity`: a CPU-bound thread
  started on a small CPU moves to an idle big one; two busy threads on
  a machine described as SMT pairs land on two cores; an OVERCOMMIT
  packet arrives when available capacity drops below admitted work, and
  not before; CAPACITY refusals (bad CPU, zero, above 1024, sustained
  above original).
- **Budgets, with their checks, when the code lands:**
  - `sched.misfit_pull_ms`: how long a CPU-bound fair thread stays on a
    smaller CPU while a bigger one is idle (the self-test's tiers);
    target one timeslice (10 ms);
  - `sched.capacity_update_kernel`: a CAPACITY update of every CPU,
    from entry to applied (KVM);
  - on the Q8B (V4), `thermal.cpu_peak_c` over a soak, as D63 has for
    the Mac Pro, and the time from an LMh clip to the CAPACITY update.
  Limits are set from the first measurements, never loosened in the
  change that would fail them (`docs/performance.md`).
- **When:** the kernel half (placement, misfit pulls, topology,
  `cpu_set_info`, OVERCOMMIT, the table) is testable in QEMU and lands
  before V4, whose item 2 is SMP across the Q8B's unequal cores. The
  sources (EPSS, TSENS, `_CPC`, HFI) come with the power service on each
  board.
- **Reference:** FreeBSD is redesigning its scheduler for hybrid CPUs
  and power awareness, with reviews for HFI and Thread Director and a
  proposed common infrastructure for capacities and scores (status
  report, April–June 2026, Olivier Certner). Its outcome is worth
  reading when the HFI question above is decided.

**Amendment (owner, 2026-10-26): fair placement races to completion.**
On the Orange Pi 6 Plus, D127's small-file row found fs ~61% of its
time on the A520s, where its system calls took 5-10x as long as on the
A720s, because `place` and `steal` ignored capacity. The owner chose
the simplest capacity rule over placement by demand:
- `place` takes the least loaded CPU the thread may run on (an idle one
  first), the biggest available capacity among equally loaded ones, and
  the thread's last CPU among equals. Work runs on the fastest free
  core, ends sooner, and lets the CPUs idle sooner; light threads wake
  on big cores too while one is idle, which costs some power.
- `steal` takes from the CPU with the most fair threads waiting, the
  smallest capacity among equals, and (owner, the same day) only from a
  CPU with a thread to spare: a load of 2 or more, as FreeBSD ULE's
  `steal_thresh`. An idle CPU no longer takes a thread just woken onto
  another idle one (a client's CPU stole fs ~1 µs after each request).
  Zircon's handoff of a channel call's request to the caller's CPU was
  tried and rejected the same day (D139): no faster on the board.
- Both rules live in one place (`FairPlacement`, kernel
  Sched/Profile.swift), so the demand-fit order above, or an energy
  model, can replace them later without touching the scheduler's loops.
- Still proposed, unchanged: demand tracking, misfit pulls (a running
  thread on a small CPU stays until it blocks), topology order, the
  three capacities, OVERCOMMIT and the `sched.misfit_pull_ms` budget.
  The sched self-test checks the policy's orders on described unequal
  CPUs; a budget comes with misfit pulls, which are what it measures.
