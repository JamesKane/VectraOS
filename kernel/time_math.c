// time_math.c: converting between the cycle counter and nanoseconds, exactly.
// Pure arithmetic, so the host tests check it (tests/host/time_test.c).
//
// A value splits into whole seconds and a remainder, so every step fits 64
// bits for counters up to 18 GHz (a remainder below hz times 1e9 stays under
// 2^64), with 64-bit divisions only: no fixed-point factor, whose rounding
// error would grow with uptime. Counter to nanoseconds rounds down;
// nanoseconds to counter rounds up, so the counter reaching the value it gives
// means the nanosecond deadline has passed: a timer never fires early.

#pragma once

static constexpr uint64_t NS_PER_S = 1'000'000'000;

static uint64_t time_counter_to_ns(uint64_t count, uint64_t hz) {
  return count / hz * NS_PER_S + count % hz * NS_PER_S / hz;
}

static uint64_t time_ns_to_counter(uint64_t ns, uint64_t hz) {
  return ns / NS_PER_S * hz + (ns % NS_PER_S * hz + NS_PER_S - 1) / NS_PER_S;
}
