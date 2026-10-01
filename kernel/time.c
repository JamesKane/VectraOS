// time.c: the monotonic clock and the one-shot deadline timer (docs/01 §4.4, §8).
//
// The clock is the CPU's cycle counter (TSC, or the aarch64 virtual counter),
// read without a syscall and converted to nanoseconds with a fixed-point factor.
// The timer is one-shot: arch_timer_arm programs the next deadline as a counter
// value and its interrupt calls timer_interrupt. Hardware that counts down
// rather than comparing with the counter may interrupt early, so an interrupt
// before the deadline only re-arms. The kernel is tickless (01 §8): nothing
// fires unless a deadline is armed.

static void sched_timer(void);   // sched/sched.c

static struct {
    uint64_t hz;          // counter frequency, published in /sys/clock/info (02 §5.1)
    uint64_t ns_mult;     // ns = counter * ns_mult >> 32
    uint64_t count_mult;  // counter = ns * count_mult >> 24
    uint64_t boot_count;  // the counter at kernel entry: log timestamps count from here
    uint64_t armed;       // the armed deadline as a counter value; 0 if none
    volatile uint64_t fired;
} clock;

static void clock_init(uint64_t hz, uint64_t boot_count) {
    if (!hz) panic(VX_STR("the cycle counter's frequency is unknown"));
    // Both factors fit 64 bits (1e9 << 32 is about 4.3e18; hz << 24 does up to
    // 1 THz), so only the multiplies need 128 bits, and those are single
    // instructions; a 128-bit division would need compiler-rt.
    clock.hz         = hz;
    clock.ns_mult    = (1'000'000'000ull << 32) / hz;
    clock.count_mult = (hz << 24) / 1'000'000'000ull;
    clock.boot_count = boot_count;
}

static uint64_t counter_to_ns(uint64_t count) {
    return (uint64_t)(((unsigned __int128)count * clock.ns_mult) >> 32);
}

static uint64_t ns_to_counter(uint64_t ns) {
    return (uint64_t)(((unsigned __int128)ns * clock.count_mult) >> 24);
}

// Nanoseconds on the one monotonic clock (01 §4.4).
static vx_instant clock_now(void) { return (vx_instant)counter_to_ns(arch_counter()); }

// Arms the timer for an absolute deadline on the monotonic clock.
static void timer_arm(vx_instant deadline) {
    clock.armed = ns_to_counter((uint64_t)deadline);
    if (!clock.armed) clock.armed = 1;
    arch_timer_arm(clock.armed);
}

// Called by the architecture's timer interrupt, with the interrupt acknowledged.
static void timer_interrupt(void) {
    if (!clock.armed) return;
    if (arch_counter() < clock.armed) {   // early: a countdown ran out first
        arch_timer_arm(clock.armed);
        return;
    }
    clock.armed = 0;
    clock.fired++;
    sched_timer();
}

// The log prefix: "[    s.mmm] ", seconds since kernel entry.
static void kput_stamp(void) {
    uint64_t ms = clock.hz ? counter_to_ns(arch_counter() - clock.boot_count) / 1000000 : 0;
    char buf[16] = "[    0.000] ";
    uint64_t s = ms / 1000;
    buf[7] = (char)('0' + ms % 1000 / 100);
    buf[8] = (char)('0' + ms % 100 / 10);
    buf[9] = (char)('0' + ms % 10);
    for (int i = 5; i >= 1 && (s || i == 5); i--, s /= 10) buf[i] = (char)('0' + s % 10);
    arch_console_write((vx_str){ buf, 12 });
}
