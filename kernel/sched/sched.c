// sched.c: the v1 scheduler (docs/01 §8): one CPU, one run queue served round
// robin, a sleep queue ordered by deadline, and a 10 ms time slice for user
// threads while others are ready. Intents, priority bands and the realtime
// class arrive with scheduling contexts (M2 onward); SMP with the stretch goal.
//
// The kernel runs with interrupts off. They are on only in user mode and in the
// idle thread's wait, so nothing in here needs a lock on one CPU.

constexpr vx_duration TIME_SLICE = 10'000'000;

static struct {
    thread *current;
    thread *run_head, *run_tail;
    thread *sleepers;       // blocked threads with a deadline, earliest first
    thread  idle;           // the boot context, which becomes the idle thread
    vx_instant slice_end;
    bool    started;
    bool    resched;        // a trap handler should call schedule before returning to user mode
} sched;

static void sched_arm_timer(void);
static void port_remove_waiter(struct port *p, thread *t);   // obj/port.c

static void run_enqueue(thread *t) {
    t->state = THREAD_READY;
    t->next  = nullptr;
    if (sched.run_tail) sched.run_tail->next = t;
    else sched.run_head = t;
    sched.run_tail = t;
}

static thread *run_dequeue(void) {
    thread *t = sched.run_head;
    if (t) {
        sched.run_head = t->next;
        if (!sched.run_head) sched.run_tail = nullptr;
        t->next = nullptr;
    }
    return t;
}

static void sleep_remove(thread *t) {
    for (thread **link = &sched.sleepers; *link; link = &(*link)->sleep_next) {
        if (*link == t) {
            *link = t->sleep_next;
            t->sleep_next = nullptr;
            return;
        }
    }
}

// Switches to the next ready thread, or to idle. The current thread is queued
// again if it is still running; a blocked or dead one is not.
static void schedule(void) {
    thread *prev = sched.current;
    if (prev->state == THREAD_RUNNING && prev != &sched.idle) run_enqueue(prev);
    thread *next = run_dequeue();
    if (!next) next = &sched.idle;
    sched.resched = false;
    if (next != &sched.idle) sched.slice_end = clock_now() + TIME_SLICE;
    sched_arm_timer();
    if (next == prev) {
        prev->state = THREAD_RUNNING;
        return;
    }
    next->state   = THREAD_RUNNING;
    sched.current = next;
    if (next->task) {
        arch_set_kernel_stack(thread_kstack_top(next));
        if (!prev->task || prev->task != next->task) arch_switch_user_root(next->task->root);
    }
    arch_context_switch(&prev->kernel_sp, next->kernel_sp);
}

// Makes a blocked thread ready, with the result its wait returns.
static void thread_wake(thread *t, int64_t result) {
    if (t->state != THREAD_BLOCKED) return;
    sleep_remove(t);
    t->wait_result = result;
    t->port = nullptr;
    run_enqueue(t);
    sched.resched = true;
}

// Blocks the current thread until thread_wake, or until the deadline (plus up
// to `leeway`, which lets the timer serve several waits with one interrupt).
// Returns the wait's result: VX_ERR_TIMED_OUT if the deadline passed.
static int64_t thread_block(vx_instant deadline, vx_duration leeway) {
    thread *t = sched.current;
    t->state = THREAD_BLOCKED;
    if (deadline != VX_INFINITE) {
        t->wake_at   = deadline;
        t->wake_late = leeway > 0 && deadline <= VX_INFINITE - leeway ? deadline + leeway : deadline;
        thread **link = &sched.sleepers;
        while (*link && (*link)->wake_at <= deadline) link = &(*link)->sleep_next;
        t->sleep_next = *link;
        *link = t;
    }
    schedule();
    return t->wait_result;
}

// Arms the timer for the next thing that needs it: the earliest sleeper's
// latest acceptable wake-up, or the end of the slice if others are waiting.
static void sched_arm_timer(void) {
    vx_instant next = VX_INFINITE;
    for (thread *t = sched.sleepers; t; t = t->sleep_next)
        if (t->wake_late < next) next = t->wake_late;
    if (sched.run_head && sched.current != &sched.idle && sched.slice_end < next) next = sched.slice_end;
    if (next != VX_INFINITE) timer_arm(next);
}

// The timer fired (time.c): wake every sleeper whose deadline has passed, and
// end the slice if it is over.
static void sched_timer(void) {
    if (!sched.started) return;
    vx_instant now = clock_now();
    while (sched.sleepers && sched.sleepers->wake_at <= now) {
        thread *t = sched.sleepers;
        if (t->port) port_remove_waiter(t->port, t);
        thread_wake(t, VX_ERR_TIMED_OUT);
    }
    if (sched.run_head && now >= sched.slice_end) sched.resched = true;
    sched_arm_timer();
}

// The boot context becomes the idle thread: it runs whenever nothing else can,
// and sleeps until an interrupt makes something ready.
[[noreturn]] static void sched_run(void) {
    sched.idle.state = THREAD_RUNNING;
    sched.current    = &sched.idle;
    sched.started    = true;
    for (;;) {
        schedule();
        if (!sched.run_head) arch_wait();
    }
}

static void sched_start_thread(thread *t) { run_enqueue(t); }

// The first time a thread runs, arch_context_switch returns into the
// architecture's trampoline, which calls this. It never returns: it enters user mode.
[[noreturn]] void thread_entry(thread *t) {
    arch_enter_user(t->user_entry, t->user_sp, t->user_arg, thread_kstack_top(t));
}

// Starts the report of a fault that kills the current thread:
// "vx: task 1 (svcd) killed: " and whatever the caller adds.
static void task_fault_start(void) {
    task *t = sched.current->task;
    kput(VX_STR("vx: task "));
    kput_u64(t->id);
    kput(VX_STR(" ("));
    kput_cstr(t->name);
    kput(VX_STR(") killed: "));
}

// Ends the current thread after a fault it cannot recover from.
[[noreturn]] static void thread_kill_current(void) {
    sched.current->state = THREAD_DEAD;
    schedule();
    panic(VX_STR("a dead thread was scheduled"));
}
