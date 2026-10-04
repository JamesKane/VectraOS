// drv-rtc-cmos: the PC's CMOS real-time clock (PNP0B00), the first driver
// started from an ACPI device (M5 step 7d). devmgr gives it exactly the
// device's _CRS resources, as bus-acpi reported them: the ports (io0, at
// least the index and data ports 0x70 and 0x71) and the interrupt (irq0,
// unused so far); and a channel ("devmgr") to say the time on. It reads the
// clock once, says it, and devmgr sets the kernel's wall clock from it
// (ADR-0031). The clock is taken to keep UTC.
//
// The FADT's century register, if it names one, comes as a record
// (fadt century=0x32); without one the century is the 21st.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-rt/spawn.c"
#include "../../lib/vx-driver/clockproto.h"

static inline void outb(uint16_t port, uint8_t value) {
  __asm__ volatile("outb %0, %1" : : "a"(value), "Nd"(port));
}

static inline uint8_t inb(uint16_t port) {
  uint8_t value;
  __asm__ volatile("inb %1, %0" : "=a"(value) : "Nd"(port));
  return value;
}

static uint16_t index_port; // the first of io0's ports; data is the next

static uint8_t cmos(uint8_t reg) {
  outb(index_port, reg); // bit 7 clear: NMIs stay on
  return inb((uint16_t)(index_port + 1));
}

enum : uint8_t {
  SECONDS = 0,
  MINUTES = 2,
  HOURS = 4,
  DAY = 7,
  MONTH = 8,
  YEAR = 9,
  STATUS_A = 0xa,
  STATUS_B = 0xb
};
enum : uint8_t {
  A_UPDATING = 0x80, // an update is under way: the time registers are changing
  B_24HOUR = 0x02,
  B_BINARY = 0x04, // binary, not BCD
  HOUR_PM = 0x80,  // in 12-hour mode
};

typedef struct reading {
  uint8_t r[7]; // seconds, minutes, hours, day, month, year, century
} reading;

static void read_once(reading *t, uint8_t century_reg) {
  for (int spin = 0; spin < 1'000'000 && (cmos(STATUS_A) & A_UPDATING); spin++) {}
  t->r[0] = cmos(SECONDS), t->r[1] = cmos(MINUTES), t->r[2] = cmos(HOURS);
  t->r[3] = cmos(DAY), t->r[4] = cmos(MONTH), t->r[5] = cmos(YEAR);
  t->r[6] = century_reg ? cmos(century_reg) : 0;
}

static uint32_t bcd(uint8_t v, bool binary) { return binary ? v : (uint32_t)(v >> 4) * 10 + (v & 15); }

// Days from 1970-01-01 to a civil date (Howard Hinnant's days_from_civil).
static int64_t days_from_civil(int64_t y, uint32_t m, uint32_t d) {
  y -= m <= 2;
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  uint32_t yoe = (uint32_t)(y - era * 400);
  uint32_t doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
  uint32_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (int64_t)doe - 719468;
}

const char *vx_main(void) {
  vx_handle io = vx_spawn_take("io0"), devmgr = vx_spawn_take("devmgr");
  vx_ndb_record rec;
  uint64_t base = 0, size = 0, century_reg = 0;
  if (!io || !devmgr || !vx_spawn_record("io", &rec) || !vx_ndb_get_u64(&rec, "base", &base) ||
      !vx_ndb_get_u64(&rec, "size", &size) || size < 2 || base > 0xfffe)
    return "no CMOS ports";
  uint64_t ignored = 0;
  if (vx_as_map(vx_self, io, 0, 0, 0, &ignored) != VX_OK) return "cannot use the CMOS ports";
  if (vx_spawn_record("fadt", &rec)) vx_ndb_get_u64(&rec, "century", &century_reg);
  if (century_reg > 0x7f) century_reg = 0;
  index_port = (uint16_t)base;

  // Read until two readings agree: an update between the check and the reads
  // would leave a mix of two seconds.
  reading a, b;
  read_once(&a, (uint8_t)century_reg);
  for (int tries = 0; tries < 10; tries++) {
    read_once(&b, (uint8_t)century_reg);
    if (memcmp(&a, &b, sizeof a) == 0) break;
    a = b;
  }
  vx_instant when = vx_clock_read();
  uint8_t status = cmos(STATUS_B);
  bool binary = status & B_BINARY;
  uint32_t sec = bcd(a.r[0], binary), min = bcd(a.r[1], binary), hour = bcd(a.r[2] & 0x7f, binary);
  uint32_t day = bcd(a.r[3], binary), month = bcd(a.r[4], binary), year = bcd(a.r[5], binary);
  if (!(status & B_24HOUR)) hour = hour % 12 + (a.r[2] & HOUR_PM ? 12 : 0);
  uint32_t century = a.r[6] ? bcd(a.r[6], binary) : 20;
  if (sec > 59 || min > 59 || hour > 23 || !day || day > 31 || !month || month > 12 || year > 99 ||
      century > 99)
    return "the clock's registers make no time";
  int64_t secs = days_from_civil((int64_t)century * 100 + year, month, day) * 86400 + (int64_t)hour * 3600 +
                 (int64_t)min * 60 + sec;

  vx_clock_report rep = {.h = {.ordinal = VX_CLOCK_REPORT}, .utc = secs * 1'000'000'000, .monotonic = when};
  if (vx_channel_write(devmgr, &rep, sizeof rep, nullptr, 0) != VX_OK) return "cannot tell devmgr the time";
  vx_print(VX_STR("drv-rtc-cmos: the clock says "));
  vx_print_u64((uint64_t)secs);
  vx_print(VX_STR(" s since 1970\n"));

  // Kept running, holding the clock's ports: setting it, and its alarms,
  // come with their first users.
  vx_handle port;
  vx_port_create(0, &port);
  for (;;) {
    vx_packet pk;
    vx_port_wait(port, VX_INFINITE, 0, &pk, 1);
  }
}
