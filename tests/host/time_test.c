// time_test.c: kernel/time_math.c. For counter rates real hardware has (arm64
// generic timers at 19.2, 24, 50, 62.5 and 1000 MHz; TSCs at odd rates up to
// 5 GHz), and up to ten years of uptime: a deadline's counter value is the
// first one at or after the deadline, so a timer never fires early (the
// interrupt storm a drifting fixed-point factor caused) and never later than
// one tick.

#include <stdint.h>

#include "check.h"
#include "../../kernel/time_math.c"

static void test_rate(uint64_t hz) {
  static const uint64_t TEN_YEARS = 10ull * 365 * 24 * 3600 * NS_PER_S;
  uint64_t bad = 0;
  for (uint64_t ns = 1; ns < TEN_YEARS; ns = ns * 3 + 12345) {
    uint64_t c = time_ns_to_counter(ns, hz);
    if (time_counter_to_ns(c, hz) < ns) bad++;           // the counter there is still before the deadline
    if (c && time_counter_to_ns(c - 1, hz) >= ns) bad++; // a tick earlier would already do: one late
  }
  CHECK(bad == 0);
  CHECK(time_counter_to_ns(hz, hz) == NS_PER_S && time_ns_to_counter(NS_PER_S, hz) == hz);
  uint64_t year = 365ull * 24 * 3600 * hz; // a year's counts: exact, with no drift
  CHECK(time_counter_to_ns(year, hz) == 365ull * 24 * 3600 * NS_PER_S);
}

int main(void) {
  static const uint64_t RATES[] = {19'200'000,    24'000'000,    50'000'000,    62'500'000,    1'000'000'000,
                                   2'399'987'000, 3'187'200'000, 4'999'999'999, 18'000'000'000};
  for (size_t i = 0; i < sizeof RATES / sizeof RATES[0]; i++) test_rate(RATES[i]);
  return check_result();
}
