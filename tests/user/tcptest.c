// tcptest: TCP through /net/tcp, against QEMU's own stack (tests/qemu/tcp.ndb).
// QEMU hands a connection to 10.0.2.100!7 to a `cat` on the host, so what is
// sent comes back. 256 KiB go through, 4 KiB at a time, checked as they
// return; then hangup sends our FIN, cat sees the end of its input and exits,
// and the read sees the end of the stream. A connection to a port nobody
// listens on is refused.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/spawn.c"

static vx_ns ns;

[[noreturn]] static void fail(const char *what, int64_t st) {
  vx_print(VX_STR("tcptest: FAILED: "));
  vx_print(vx_cstr(what));
  if (st < 0) {
    vx_print(VX_STR(": "));
    vx_print(p9_error_text((vx_status)st));
  }
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

typedef struct text {
  char buf[64];
  size_t len;
} text;

static void put(text *t, vx_str s) {
  for (size_t i = 0; i < s.len && t->len < sizeof t->buf; i++) t->buf[t->len++] = s.ptr[i];
}

typedef struct conn {
  vx_ns_file ctl, data;
} conn;

// A connection to addr ("ADDR!PORT"): the status of the connect.
static vx_status dial(const char *addr, conn *c) {
  vx_status st = vx_ns_open(&ns, VX_STR("/net/tcp/clone"), P9_ORDWR, &c->ctl);
  if (st != VX_OK) fail("/net/tcp/clone", st);
  char number[8];
  int64_t n = vx_ns_read(&c->ctl, number, sizeof number);
  if (n <= 0 || n > 2) fail("reading the conversation's number", n);
  text msg = {};
  put(&msg, VX_STR("connect "));
  put(&msg, vx_cstr(addr));
  int64_t w = vx_ns_write(&c->ctl, msg.buf, (uint32_t)msg.len); // returns once connected, or refused
  if (w < 0) return (vx_status)w;
  text path = {};
  put(&path, VX_STR("/net/tcp/"));
  put(&path, (vx_str){number, (size_t)n});
  put(&path, VX_STR("/data"));
  st = vx_ns_open(&ns, (vx_str){path.buf, path.len}, P9_ORDWR, &c->data);
  if (st != VX_OK) fail("opening data", st);
  return VX_OK;
}

static uint8_t pattern(size_t i) { return (uint8_t)(i * 13 + i / 251); }

static int echo(void) {
  conn c;
  vx_status st = dial("10.0.2.100!7", &c);
  if (st != VX_OK) fail("connect 10.0.2.100!7", st);
  vx_print(VX_STR("tcptest: connected to 10.0.2.100!7\n"));
  static uint8_t out[4096], in[4096];
  constexpr size_t TOTAL = (size_t)256 * 1024;
  for (size_t done = 0; done < TOTAL; done += sizeof out) {
    for (size_t i = 0; i < sizeof out; i++) out[i] = pattern(done + i);
    for (size_t sent = 0; sent < sizeof out;) { // a stream write may take part of it
      int64_t w = vx_ns_write(&c.data, out + sent, (uint32_t)(sizeof out - sent));
      if (w <= 0) fail("writing", w);
      sent += (size_t)w;
    }
    for (size_t got = 0; got < sizeof out;) {
      int64_t r = vx_ns_read(&c.data, in, (uint32_t)(sizeof out - got));
      if (r <= 0) fail("reading the echo", r);
      for (int64_t i = 0; i < r; i++)
        if (in[i] != pattern(done + got + (size_t)i)) fail("the echo differs from what was sent", 0);
      got += (size_t)r;
    }
  }
  vx_print(VX_STR("tcptest: 262144 bytes echoed\n"));
  if (vx_ns_write(&c.ctl, "hangup", 6) != 6) fail("hangup", 0);
  int64_t r = vx_ns_read(&c.data, in, sizeof in);
  if (r != 0) fail("expected the end of the stream", r);
  vx_print(VX_STR("tcptest: end of stream after hangup\n"));
  vx_ns_close(&c.data);
  vx_ns_close(&c.ctl);
  return 0;
}

// Waits up to 20 s for netd to have an address, as any client must.
static void await_address(void) {
  vx_handle nap;
  if (vx_port_create(0, &nap) != VX_OK) fail("port_create", 0);
  for (int i = 0; i < 200; i++) {
    vx_ns_file f;
    char status[128];
    int64_t n = 0;
    if (vx_ns_open(&ns, VX_STR("/net/ipifc/0/status"), P9_OREAD, &f) == VX_OK) {
      n = vx_ns_read(&f, status, sizeof status);
      vx_ns_close(&f);
    }
    for (int64_t j = 0; j + 9 < n; j++)
      if (memcmp(status + j, "addr=", 5) == 0 && memcmp(status + j + 5, "none", 4) != 0) return;
    vx_port_wait(nap, vx_clock_read() + 100'000'000, 0, &(vx_packet){}, 1);
  }
  fail("no address", 0);
}

const char *vx_main(void) {
  if (vx_ns_from_spawn(&ns) != VX_OK) fail("no namespace", 0);
  await_address();
  echo();
  conn c;
  vx_status st = dial("10.0.2.2!1", &c);
  if (st == VX_OK) fail("a connection to 10.0.2.2!1 was made", 0);
  vx_print(VX_STR("tcptest: 10.0.2.2!1: "));
  vx_print(p9_error_text(st));
  vx_print(VX_STR("\n"));
  vx_ns_close(&c.ctl);
  vx_print(VX_STR("tcptest: ok\n"));
  return nullptr;
}
