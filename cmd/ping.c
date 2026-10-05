// ping [-N] ADDR: sends N ICMP echo requests (3 unless given), a second
// apart, through /net/icmp (netd), and prints each reply's round trip.
//
// A conversation: open /net/icmp/clone (the fid becomes its ctl), read its
// number, write "connect ADDR" there, then write requests to and read replies
// from N/data. netd fills in the identifier and checksum.
//
// A reply that never comes holds the read until one does; a timeout comes
// with Tflush in the 9P client.

#include "../lib/vx-rt/rt.c"
#include "../lib/vx-ns/spawn.c"

static constexpr uint32_t PAYLOAD = 56; // and 8 bytes of header: 64, as everyone's ping sends

[[noreturn]] static void fail(vx_str what, int64_t st) {
  vx_eprint(VX_STR("ping: "));
  vx_eprint(what);
  if (st < 0) {
    vx_eprint(VX_STR(": "));
    vx_eprint(p9_error_text((vx_status)st));
  }
  vx_eprint(VX_STR("\n"));
  vx_exits("error");
}

typedef struct text {
  char buf[128];
  size_t len;
} text;

static void put(text *t, vx_str s) {
  for (size_t i = 0; i < s.len && t->len < sizeof t->buf; i++) t->buf[t->len++] = s.ptr[i];
}

static void put_u64(text *t, uint64_t v) {
  char digits[20];
  size_t d = sizeof digits;
  do digits[--d] = (char)('0' + v % 10);
  while (v /= 10);
  put(t, (vx_str){digits + d, sizeof digits - d});
}

const char *vx_main(void) {
  uint64_t count = 3;
  uint32_t arg = 0;
  if (vx_spawn.argc > 1 && vx_spawn.args[0].len > 1 && vx_spawn.args[0].ptr[0] == '-') {
    count = 0;
    for (size_t i = 1; i < vx_spawn.args[0].len; i++) {
      char c = vx_spawn.args[0].ptr[i];
      if (c < '0' || c > '9' || count > 1000) fail(VX_STR(VX_USAGE), 0);
      count = count * 10 + (uint64_t)(c - '0');
    }
    arg = 1;
  }
  if (arg + 1 != vx_spawn.argc || vx_spawn.args[arg].len > 40) fail(VX_STR(VX_USAGE), 0);
  vx_str addr = vx_spawn.args[arg];

  static vx_ns ns;
  vx_ns_file ctl, data;
  vx_status st = vx_ns_from_spawn(&ns);
  if (st == VX_OK) st = vx_ns_open(&ns, VX_STR("/net/icmp/clone"), P9_ORDWR, &ctl);
  if (st != VX_OK) fail(VX_STR("/net/icmp/clone"), st);
  char number[8];
  int64_t n = vx_ns_read(&ctl, number, sizeof number);
  if (n <= 0) fail(VX_STR("reading the conversation's number"), n);
  text t = {};
  put(&t, VX_STR("connect "));
  put(&t, addr);
  int64_t w = vx_ns_write(&ctl, t.buf, (uint32_t)t.len); // ctl's offset means nothing
  if (w < 0) fail(VX_STR("connect"), w);
  text path = {};
  put(&path, VX_STR("/net/icmp/"));
  put(&path, (vx_str){number, (size_t)n});
  put(&path, VX_STR("/data"));
  st = vx_ns_open(&ns, (vx_str){path.buf, path.len}, P9_ORDWR, &data);
  if (st != VX_OK) fail((vx_str){path.buf, path.len}, st);

  vx_handle nap; // a port nothing is bound to: waiting on it is a sleep
  if ((st = vx_port_create(0, &nap)) != VX_OK) fail(VX_STR("port_create"), st);
  uint64_t received = 0;
  uint8_t msg[8 + PAYLOAD], reply[8 + PAYLOAD + 64];
  for (uint64_t seq = 1; seq <= count; seq++) {
    if (seq > 1) vx_port_wait(nap, vx_clock_read() + 1'000'000'000, 0, &(vx_packet){}, 1); // a second apart
    memset(msg, 0, sizeof msg);
    msg[0] = 8;                                          // echo request
    msg[6] = (uint8_t)(seq >> 8), msg[7] = (uint8_t)seq; // sequence
    vx_instant sent = vx_clock_read();
    memcpy(msg + 8, &sent, sizeof sent);
    for (uint32_t i = sizeof sent; i < PAYLOAD; i++) msg[8 + i] = (uint8_t)i;
    if ((w = vx_ns_write(&data, msg, sizeof msg)) < 0) fail(VX_STR("sending"), w);
    // Replies to earlier requests (late ones) are skipped; this one's comes in turn.
    for (;;) {
      int64_t got = vx_ns_read(&data, reply, sizeof reply);
      if (got < 0) fail(VX_STR("receiving"), got);
      if (got < 16 || reply[0] != 0 || (uint64_t)(reply[6] << 8 | reply[7]) != seq) continue;
      vx_instant then;
      memcpy(&then, reply + 8, sizeof then);
      text line = {};
      put(&line, VX_STR("ping: "));
      put(&line, addr);
      put(&line, VX_STR(": seq="));
      put_u64(&line, seq);
      put(&line, VX_STR(" time="));
      put_u64(&line, (uint64_t)(vx_clock_read() - then) / 1000);
      put(&line, VX_STR("us\n"));
      vx_print((vx_str){line.buf, line.len});
      received++;
      break;
    }
  }
  vx_ns_close(&data);
  vx_ns_close(&ctl);
  text line = {};
  put(&line, VX_STR("ping: "));
  put_u64(&line, count);
  put(&line, VX_STR(" sent, "));
  put_u64(&line, received);
  put(&line, VX_STR(" received\n"));
  vx_print((vx_str){line.buf, line.len});
  return received == count ? nullptr : "lost";
}
