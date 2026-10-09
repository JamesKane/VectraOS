# ADR-0050: a task's hardware counters

Status: proposed, 2026-10-09 (M7 step 7a3b). Design: docs/05 §9, 20 §6.

## Context

05 §9 reserved `pmu_configure` (syscall 67, pmu(2)) for a task's performance counters, saved and restored at each switch so a program reads its own (`rdpmc`, `PMEVCNTR`). 20 §6 adds overflow sampling where a PMU exists. The prior art: Fuchsia's perfmon is system-wide, per CPU, programmed through `mtrace_control` with the root resource, its records in buffers of their own (`zircon/kernel/lib/perfmon/include/lib/perfmon.h`); its arm64 overflow interrupt was never wired (`zircon/kernel/arch/arm64/perf_mon.cc:609`). Linux's `perf_event_open` counts per task or per CPU. M7 needs a program's own counts, and the system's samples already have a home: the trace (ADR-0049).

## Decision

1. **`pmu_configure(task, op, data, len)`**, shaped as `trace_configure` is, in the reserved slot. The task handle needs `INSPECT`, as debugging it would. Ops: `INFO` (`vx_pmu_info`: counters, their width, the events the PMU counts), `SET` (`vx_pmu_config`: up to `VX_PMU_MAX` = 4 events, flags; count 0 turns them off), `READ` (the task's totals).
2. **Generic events, mapped per vendor:** cycles, retired instructions, cache misses and branch misses. Cache misses are each vendor's nearest (AMD's L2 misses from the data cache, Intel's last-level misses, Arm's L1D refills), so they compare runs, not machines. An event the PMU does not count (TCG's aarch64 instructions without precise icount) is `UNSUPPORTED`; `INFO` says which.
3. **User mode only.** Counters never count the kernel: a task learns nothing of other tasks' work done in it.
4. **Per thread, summed per task.** A thread's counters start where it left off at each switch in, as wide as the counter is; at each switch out what it counted is added to the task's totals. A `SET` is a new configuration: running threads take it at their next switch, the caller at once, and the totals start from 0. `READ` gives each thread's counts to its last switch, the caller's own to now.
5. **A thread reads its own** with `VX_PMU_USER_READ`: `rdpmc N` (CR4.PCE) or `PMXEVCNTR_EL0` after `PMSELR_EL0` (PMUSERENR_EL0.ER), counter N counting `events[N]`, `width` bits.
6. **Back ends:** AMD's core counters with PerfMonV2's global control, Intel's architectural counters (CPUID 0xa), Arm's PMUv3; general-purpose counters only.
7. **Overflow sampling (7a3b2)** takes `sample_period`: an overflow writes the trace's `SAMPLE` and `FRAMES` records (ADR-0049 item 9) while the trace samples. Until then a non-zero period is `UNSUPPORTED`.

## Consequences

- The ABI grows two records and four constants; the syscall's number was allotted. `libvx` does not export it yet: vx-rt's `vx_pmu_configure` is internal, for a later level.
- A switch costs two MSR or system-register writes a counter for a task that counts, nothing for one that does not.
- Intel's legacy counters take 32-bit writes, so a thread's own reading there is 31 bits wide; the totals are not. Intel is untested here (the host is AMD).
