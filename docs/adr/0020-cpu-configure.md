# ADR-0020: `cpu_configure`, so the kernel gets the firmware's idle states and performance domains

Status: proposed, 2026-10-02. A new syscall, the 63rd (01 §3). Found by looking at the Radxa Dragon Q8B (ADR-0019).

## Context

01 §8 had no CPU idle and no CPU frequency. A machine that never leaves WFI or HLT and runs at the firmware's boot frequency wastes power and heat; on the Q8B, it also never uses the deep idle state (C3) that AbyssBSD turns on by default, and never scales its two frequency domains (Qualcomm EPSS).

Both decisions belong in the kernel:
- The idle loop runs on the CPU that is going idle, with no process to ask, and knows the CPU's next timer event exactly, because the kernel is tickless.
- The frequency choice depends on per-core utilisation and on the intents running there, both of which only the scheduler knows. Linux moved from user-space governors to `schedutil` in its scheduler for that reason.

But the tables they need come from the firmware in forms only user space reads:
- **Idle states** are ACPI `_LPI` (arm64) and `_CST` (x86_64), which are AML. `bus-acpi` runs ACPICA in user space (01 §7.2), and the kernel runs no AML.
- **Performance domains** come from `_CPC` (AML) or from a vendor's registers. The Q8B's are EPSS's lookup table, read through MMIO that a driver maps.

The kernel reads static tables itself (the MADT, and the GTDT for the always-on timer). But no existing call carries a table from user space into the scheduler:
- `sched_ctx_configure` configures one scheduling context;
- `pmu_configure` configures performance counters;
- a `Resource` mints objects but configures nothing.

## Decision

- **`cpu_configure(resource, op, data, len)`**. `resource` must be the root `Resource` or one `svcd` minted for CPU configuration. Only `svcd`'s platform service, the server of `/sys/power`, and the thermal policy hold one. The operations:
  - `VX_CPU_IDLE_STATES`: a CPU set and its states. Each state has:
    - its entry: a PSCI `CPU_SUSPEND` parameter, an MWAIT hint, or WFI/HLT;
    - its exit latency and target residency, in nanoseconds;
    - flags: `TIMER_STOPS`, `CACHE_LOST`.
    A later call for the same CPUs replaces the table.
  - `VX_CPU_PERF_DOMAIN`: a domain's CPUs and levels. Each level is a frequency and the value that selects it. A domain also says how a level is selected:
    - a register: physical address and width, which the kernel maps and writes the value to (EPSS, CPPC over MMIO);
    - or `ARCH`: HWP on Intel, CPPC on AMD, through MSRs, where the kernel writes the energy-performance preference and the hardware picks.
  - `VX_CPU_LIMITS`: a domain's lowest and highest allowed level, and the preference's bias, set by one caller. Each caller's limits are kept separately (the power profile's, the thermal policy's), and the kernel applies the tightest.
- **Every table is validated:**
  - levels in increasing frequency;
  - states in increasing depth;
  - a register's range must be MMIO, not RAM;
  - a state with `TIMER_STOPS` is refused when the kernel has no always-on timer to wake it.

  A bad table is `ERR_INVALID`, and the old table stays.
- **The policies are in 01 §8:** the deepest idle state that fits the next timer event and the CPU's latency limit; the lowest level that keeps the busiest core under 80%, held up for `realtime` and `interactive-frame` contexts.
- **What the call replaces:** nothing. There was no idle or frequency control. The alternatives were worse:
  - **AML in the kernel** would bring an interpreter of firmware bytecode into the kernel, which 01 §1 keeps in user space.
  - **A user-space governor** would need a utilisation feed and a call on every change, and cannot react to a wake-up at the moment it happens.
  - **A boot module carrying the tables** cannot be built for a generic image, because they come from each machine's AML.

## Consequences

- The syscall surface is 63 calls.
- The kernel grows an idle loop with state selection, broadcast wake-ups through the memory-mapped generic timer, a frequency policy, and register writes for domains. That is perhaps 1k lines across both architectures, inside the budget (01 §1).
- `svcd`'s platform service gains the step that evaluates `_LPI`, `_CST` and `_CPC` through `bus-acpi`, or reads the SoC's own registers (EPSS) where the SoC record says to, and calls `cpu_configure` once at boot.
- `/sys/cpu/idle` and `/sys/cpu/perf` publish what the kernel does (02 §5.1). `./build bench` gains an idle-power and a wake-up-latency check on T1 hardware.
- ktest checks that tables are validated and refused whole, that limits combine to the tightest, that a CPU with a `realtime` context never enters a state past its latency limit, and that a timer deadline is met from the deepest state. Under QEMU (T0) the only idle state is WFI and there are no performance domains, so ktest drives the frequency policy with domains a test build fakes: the logic is tested there, the hardware on T1.
