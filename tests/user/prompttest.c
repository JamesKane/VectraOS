// prompttest: the trusted prompt (M7 step 7d2d, the prompt scenario;
// docs/proto/wsys.md §4e). It holds the whole tree (its manifest's /wsys,
// a grant) and a window of its own at /n, which the scenario focuses. It
// asks a question on /wsys/prompt: nothing written answers it, its window
// raised stays under it, and its window gets no key while it is up; the
// scenario presses escape (Deny). It asks again; a click off the buttons
// does nothing, and a click on Allow answers it.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"
#include "../../lib/vx-wsys/wsysproto.h"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("prompttest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_handle ch;
static bool focused;
static uint32_t keys;

static void drain(void) {
  for (;;) {
    alignas(vx_wsys_configure) uint8_t m[256];
    vx_msg_size size;
    if (vx_channel_read(ch, m, sizeof m, nullptr, 0, &size) != VX_OK) return;
    const vx_msg_header *h = (const vx_msg_header *)m;
    if (h->ordinal == VX_WSYS_CONFIGURE && size.bytes == sizeof(vx_wsys_configure))
      focused = ((const vx_wsys_configure *)m)->flags & VX_WSYS_FOCUSED;
    if (h->ordinal == VX_WSYS_KEY) keys++;
  }
}

static uint32_t number(const char *s) {
  uint32_t v = 0;
  while (*s >= '0' && *s <= '9') v = v * 10 + (uint32_t)(*s++ - '0');
  return v;
}

static size_t digits(char *out, uint32_t v) {
  char d[10];
  size_t n = 0;
  do d[n++] = (char)('0' + v % 10), v /= 10;
  while (v);
  for (size_t i = 0; i < n; i++) out[i] = d[n - 1 - i];
  return n;
}

static void ctl(const char *path, const char *cmd) {
  vx_fd fd = vx_open(vx_cstr(path), VX_OWRITE);
  CHECK(fd >= 0 && vx_write(fd, vx_cstr(cmd)) > 0);
  if (fd >= 0) vx_close(fd);
}

// Asks, and waits for the answer: "allow" or "deny".
static vx_str ask(const char *question, char *buf, size_t cap) {
  vx_fd fd = vx_open(VX_STR("/wsys/prompt"), VX_ORDWR);
  CHECK(fd >= 0);
  if (fd < 0) return (vx_str){};
  char line[160] = "ask ";
  vx_str q = vx_cstr(question);
  memcpy(line + 4, q.ptr, q.len);
  CHECK(vx_write(fd, (vx_str){line, 4 + q.len}) > 0);
  // Nothing written answers it: a second open's "answer" is refused.
  vx_fd other = vx_open(VX_STR("/wsys/prompt"), VX_ORDWR);
  CHECK(other >= 0 && vx_write(other, VX_STR("answer allow")) < 0);
  if (other >= 0) vx_close(other);
  ctl("/wsys/windows/1/ctl", "raise"); // its window raised: still under the prompt
  vx_print(VX_STR("prompttest: asked\n"));
  int64_t n = vx_read(fd, (vx_bytes){(uint8_t *)buf, cap});
  vx_close(fd);
  return (vx_str){buf, n > 0 ? (size_t)n : 0};
}

const char *vx_main(void) {
  CHECK(vx_mount(VX_STR("/srv/wsys"), VX_STR("new -dx 300 -dy 200"), VX_STR("/n"), 0) == VX_OK);
  CHECK(vx_ns_open_post(vx_ns_process(), VX_STR("/n/surface"), &ch) == VX_OK);
  // The window centred, under where the prompt will be.
  char info[256];
  vx_fd fd = vx_open(VX_STR("/wsys/info"), VX_OREAD);
  int64_t n = fd >= 0 ? vx_read(fd, (vx_bytes){(uint8_t *)info, sizeof info - 1}) : -1;
  if (fd >= 0) vx_close(fd);
  uint32_t width = 0, height = 0;
  for (int64_t i = 0; i + 6 < n; i++) {
    if (!memcmp(info + i, " width=", 7)) width = number(info + i + 7);
    if (!memcmp(info + i, " height=", 8)) height = number(info + i + 8);
  }
  CHECK(width && height);
  char move[48] = "move ";
  size_t len = 5;
  len += digits(move + len, width / 2 - 150);
  move[len++] = ' ';
  len += digits(move + len, height / 2 - 100);
  move[len] = 0;
  ctl("/n/ctl", move);
  vx_print(VX_STR("prompttest: ready\n"));
  while (!focused) { // the scenario clicks it
    vx_handle port;
    vx_packet pk;
    vx_port_create(0, &port);
    vx_port_bind(port, ch, VX_TRIGGER_READABLE, 1, 0);
    vx_port_wait(port, vx_now() + 100'000'000, 0, &pk, 1);
    vx_handle_close(port);
    drain();
  }
  vx_print(VX_STR("prompttest: focused\n"));
  drain();
  uint32_t before = keys;
  char a[16];
  vx_str answer = ask("Allow the test to go on?", a, sizeof a);
  drain();
  CHECK(vx_str_eq(answer, VX_STR("deny\n")));
  CHECK(keys == before); // the key pressed while it was up, and escape, never reached the window
  vx_print(VX_STR("prompttest: the first denied\n"));
  answer = ask("And now?", a, sizeof a);
  CHECK(vx_str_eq(answer, VX_STR("allow\n")));
  vx_print(VX_STR("prompttest: the second allowed\n"));
  vx_printf("prompttest: %u checks, %u failed\n", checks, failures);
  vx_handle port;
  vx_packet pk;
  vx_port_create(0, &port);
  vx_port_wait(port, VX_INFINITE, 0, &pk, 1);
  return nullptr;
}
