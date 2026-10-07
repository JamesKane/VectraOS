# ADR-0041: CPU time, sampled as 9front's

Status: accepted, 2026-10-07 (proposed 2026-10-07). M6 step 6d9b (decided the same day: tick sampling as 9front, a tick only while a CPU is busy, and children's times in the wait record). It adds `thread_state`'s `VX_STATE_GET_TIMES` and `vx_cpu_times` to the ABI (`abi/vx/abi.h`), a 100 Hz tick on a CPU running a thread, and `user=` and `sys=` to procfs's wait records.

## Context

The kernel kept no CPU time: the scheduler charged time only to realtime contexts' budgets (`kernel/sched/sched.c`, `charge`). POSIX's `times`, `getrusage`, `wait4`'s rusage and the CPU-time clocks had nothing to report; `times` was `ENOSYS` (which sbase's `time` did not notice, printing garbage) and the CPU-time clocks were the monotonic clock.

9front samples: at each clock tick (`HZ`, 100 by default) `accounttime` (`sys/src/9/port/portclock.c`) charges the tick to the running process's `TUser` or `TSys` by whether the tick came from user mode. When a process ends, `pexit` (`sys/src/9/port/proc.c:1312`) adds its times and its children's (`TCUser`, `TCSys`) to its parent's children's, and puts them in the wait message beside the real time. Fuchsia instead keeps one exact `cpu_time` per thread, summed per task (`zx_info_task_runtime`), with no user/system split.

The VectraOS kernel is tickless (01 §8): a CPU's one-shot timer fires only at a deadline, such as a busy thread's 10 ms slice end, so sampling needs a tick added.

## Decision

1. **A tick while busy.** A CPU running a thread, not its idle one, arms a tick every 10 ms (`TICK`), in fixed phase from when it left idle; each tick charges the thread one tick of user or system time, by whether the interrupt came from user mode. An idle CPU arms no tick and stays tickless. A late tick charges every tick it covers.
2. **Kept per thread, summed per task.** A thread holds its two counts; a task adds a thread's to its own when the thread is reaped, so a task's time is that plus its live threads'.
3. **`thread_state(task, thread, VX_STATE_GET_TIMES, buf, size)`**, with `VX_RIGHT_INSPECT` on the task, at any time: a `vx_cpu_times` (`user`, `sys`, nanoseconds, multiples of 10 ms) for the thread, or with thread 0 for the whole task.
4. **Children's in the wait record.** When a process ends, procfs reads its task's times, adds those of its own children that ended, adds the sum to its parent's children's, and writes it in the parent's wait record as `user=` and `sys=` in milliseconds, beside `real=`, as 9front's wait message has them. musl's back end sums the records it reads for `times`' `cutime` and `cstime` and `getrusage(RUSAGE_CHILDREN)`, and gives each to `wait4`'s rusage.

## Consequences

- `times`, `getrusage` (`SELF`, `THREAD`, `CHILDREN`), `wait4`'s rusage and `CLOCK_PROCESS_CPUTIME_ID` and `CLOCK_THREAD_CPUTIME_ID` report real figures, to 10 ms; `clock_getres` says so.
- A process that runs less than a tick at a time may be charged nothing, or a tick for a moment's work, as on 9front: the figures are statistical, and right over many ticks.
- A busy CPU takes up to 100 more interrupts a second; an idle one none. 01 §8's "an idle one stays tickless" holds.
- Another thread's or process's CPU-time clock (`pthread_getcpuclockid`, `clock_getcpuclockid`) is not given; the children's times a POSIX process has waited for are lost across `execve`.
