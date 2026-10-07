# ADR-0045: CPU counts

Status: proposed, 2026-10-07. M6 step 6e1e (split in two: 6e1e1 the CPU count and `libvx`'s small calls, 6e1e2 `vx_heap`). Decided the same day: the count in `thread_state`'s `GET_CPU` record for programs, and a file in sysfs for scripts. This ADR adds three fields to `vx_cpu_info` (`abi/vx/abi.h`, ADR-0035) and `/sys/cpu/topology`.

## Context

A program sizing a thread pool needs the number of CPUs it may use (`swift-on-vectra`'s os-requirements R12: Swift's Concurrency sizes its cooperative pool from it). The kernel knew the count only at boot; no call returned it. Its scheduler (ADR-0038) also lets a context reserve whole CPUs: an unbound thread then never runs on them, and a thread bound to one runs only there. The number a process may use is therefore not the machine's.

Fuchsia gives a constant from its vDSO (`zx_system_get_num_cpus`, `zircon/kernel/lib/userabi/vdso/zx_system_get_num_cpus.cc:11`), the CPUs the kernel may use, and leaves reservations to its scheduler profiles. 9front has no call: its scripts count the lines of `/dev/sysstat`, one a processor (`rc/bin/termrc:6`, `NPROC=`{wc -l </dev/sysstat}``).

## Decision

1. **`vx_cpu_info` gains three fields,** after `keys`:
   - `cpus_online`: the CPUs that reached the scheduler, numbered from 0;
   - `cpus_usable`: of them, those the calling thread's process may run threads on: every CPU no context has reserved, and the ones the caller's own context reserves;
   - `cpus_reserved`: a mask, bit *i* set while CPU *i* is reserved by any context.
   They are read at the call, so a program that caches `vx_cpu`'s record for its features asks again for counts (`vx_cpu_count`).
2. **sysfs serves `/sys/cpu/topology`,** as 02 §5.1 drafted it: one ndb record per online CPU, `cpu=cpuN`, with the flag `reserved` while it is. 02's other keys (cluster, cache, tier, frequency, `reserved=` naming the context) wait for what measures them. `wc -l /sys/cpu/topology` is a script's count, as 9front's.

## Consequences

- Swift's Concurrency, and any C or C++ program through `libvx`'s `vx_cpu_count`, sizes itself to the CPUs it can use, one syscall each time it asks.
- A reservation made after a program sized its pool is not seen until it asks again; nothing tells it (a `VX_EV_` event could, later).
- The record grows by 16 bytes; every program is rebuilt with the kernel, so no older reader exists.
