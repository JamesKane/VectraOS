# ADR-0038: Scheduling contexts, intents, admission and core reservations

Status: proposed, 2026-10-06. M6 step 6d6c's ABI (01 §8). It gives the four calls 01 §2 names and `syscalls.def` reserved, `sched_ctx_create`, `sched_ctx_bind`, `sched_ctx_configure` and `sched_reserve`, their arguments, and adds a `SchedContext` object. Decided with it (2026-10-06): limits are system-wide until keyd (M10) gives the kernel users; donation through `channel_call` is 6d6c2's.

## Context

01 §8 describes intents (rule 6), a `realtime` class behind an admission test, and core reservations, and says the v1 policy is small: each intent a fixed priority band, round robin within a band, `realtime` a constant-bandwidth server that a thread exhausting its budget is throttled by until its next period. Since M1 every thread has run as `VX_INTENT_INTERACTIVE` in one round-robin queue, and the four calls answered `UNSUPPORTED`.

## Decision

1. **The parameters** of a context, and of a thread's own intent:

   ```c
   typedef struct vx_sched_params {
     uint32_t intent;            // enum vx_intent
     uint32_t flags;             // 0
     vx_duration period, budget; // realtime's: CPU time `budget` in each `period`
   } vx_sched_params;
   ```
   A `realtime` context's period is 1 ms to 10 s, its budget 100 µs up to the period (at most one CPU); other intents take neither (0).

2. **`sched_ctx_create(params, out)`** makes a `SchedContext` and returns a handle to it with `WRITE` (threads may be bound to it), `MANAGE` (it may be configured and reserve cores), `INSPECT`, `DUPLICATE` and `TRANSFER`. A `realtime` context is admitted or `REFUSED`, never degraded: the budgets of every admitted context, as fractions of their periods, may come to at most 80% of the CPUs online. A context is gone with its last handle and its last bound thread; its budget and its cores go with it.

3. **`sched_ctx_bind(ctx, thread, core)`** binds a thread (a handle with `MANAGE`, or `VX_HANDLE_NONE` for the caller) to a context it holds with `WRITE`: the thread runs with the context's intent and, if it is `realtime`, against its budget, shared with every thread bound to it (01 §8's workgroups). <core> is -1, or a CPU of the context's reservation, which the thread then runs on alone. A <ctx> of `VX_HANDLE_NONE` unbinds: the thread is back to its own intent.

4. **`sched_ctx_configure(ctx, params)`** changes a context (`MANAGE`), a `realtime` one admitted again, its old budget left in place if the new one is `REFUSED`. With `VX_HANDLE_NONE` it sets the calling thread's own intent, which may be anything but `realtime` (that needs a context): libvx's `vx_intent_set`.

5. **`sched_reserve(ctx, count, cls, domain, flags, out)`** reserves `count` whole CPUs for the context (`MANAGE`), or, with 0, gives back what it has. It is all or `REFUSED`. One CPU, the first, is never reserved, so at least one stays shared. `cls` is `VX_CORE_ANY` or `VX_CORE_TIER(0)`, `domain` `VX_DOMAIN_ANY`, until `/sys/cpu` publishes tiers and domains; `flags` may name `VX_RESERVE_NO_SMT_SIBLINGS` and `VX_RESERVE_SAME_LLC`, which hold on the machines the kernel runs on today (no SMT is reported, and one LLC). `out` is a `vx_core_set`: a mask of CPU indices and their count. A reserved CPU runs only threads bound to it: others leave it at their next switch, and never come back while it is reserved.

6. **The policy (v1).** Five bands, highest first: `realtime`, `interactive-frame`, `interactive`, `throughput`, `background`; round robin in 10 ms slices within a band. A thread made ready in a band above one running on some CPU preempts it. A `realtime` context's budget is charged for the time its threads run; spent, its threads wait until its next period, when it is filled again. A channel message's `sender_intent` is the sender's intent.

7. **Visible:** `thread_state`'s new `VX_STATE_GET_SCHED` gives a thread's `vx_sched_info`, and `/proc/N/threads/T/sched` gives the thread's intent, and its context's period, budget, what is left of it this period and how many periods it ran out in (01 §8's deadline misses, as the v1 server counts them).

## Consequences

- Programs say what they need rather than how; the bands can become EDF and EEVDF later (01 §13) without a change here.
- Lower bands can starve under load from higher ones, as bands do; `realtime` takes at most 80% of the CPUs, so the rest always get some.
- Without users the limits are the machine's: one program can take all 80%, or every CPU but the first. keyd (M10) brings per-user budgets and quotas.
- The kernel-internal core mask 01 §8 gives `sched_ctx_configure` for drivers, IRQ steering away from reserved CPUs, tiers and NUMA domains are later work; so is donation (6d6c2).
