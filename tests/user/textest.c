// textest: text in winsrv (M7 step 7d2b, the text scenario; docs/proto/
// wsys.md §4c). A window of its own (its manifest's /wsys) and, at /n, the
// whole tree, to play an input method at the end. The scenario clicks the
// window and types: a key with the IME off is a KEY alone; with it on,
// shift-a commits A; compose ' e composes é (a PREEDIT, then the COMMIT);
// after rc sets the us-intl keymap (a KEYMAP record), the dead ' with a
// makes á; a held b repeats, flagged REPEAT, its text committed each time;
// then, holding /wsys/ime, textest's own input method answers x with ξ
// (the key consumed) and passes y on (a KEY with IMEPASS, no text). Each
// milestone is a line.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"
#include "../../lib/vx-wsys/wsysproto.h"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("textest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_handle ch, ime;
static vx_wsys_configure cfg;
static bool focused;
static char committed[256], preedit[64];
static uint32_t ncommitted, keys, imepass_keys, repeats, plain_keys;
static uint32_t key_down_usage[64], nkey_down;
static char keymap[16];

static void ctl(const char *path, const char *cmd) {
  vx_fd fd = vx_open(vx_cstr(path), VX_OWRITE);
  CHECK(fd >= 0 && vx_write(fd, vx_cstr(cmd)) > 0);
  if (fd >= 0) vx_close(fd);
}

static void on_record(const uint8_t *m, uint32_t len) {
  const vx_msg_header *h = (const vx_msg_header *)m;
  if (h->ordinal == VX_WSYS_CONFIGURE && len == sizeof(vx_wsys_configure)) {
    memcpy(&cfg, m, sizeof cfg);
    focused = cfg.flags & VX_WSYS_FOCUSED;
  } else if (h->ordinal == VX_WSYS_KEY && len == sizeof(vx_wsys_key)) {
    const vx_wsys_key *k = (const vx_wsys_key *)m;
    keys++;
    if (k->flags & VX_WSYS_IMEPASS)
      imepass_keys++;
    else
      plain_keys++;
    if (k->key.action == VX_KEY_REPEAT) repeats++;
    if (k->key.action == VX_KEY_DOWN && nkey_down < 64) key_down_usage[nkey_down++] = k->key.usage;
  } else if (h->ordinal == VX_WSYS_COMMIT && len == sizeof(vx_wsys_commit)) {
    const vx_wsys_commit *c = (const vx_wsys_commit *)m;
    if (c->len <= VX_WSYS_TEXT && ncommitted + c->len < sizeof committed)
      memcpy(committed + ncommitted, c->text, c->len), ncommitted += c->len;
  } else if (h->ordinal == VX_WSYS_PREEDIT && len == sizeof(vx_wsys_preedit)) {
    const vx_wsys_preedit *p = (const vx_wsys_preedit *)m;
    if (p->len && p->len < sizeof preedit) memcpy(preedit, p->text, p->len), preedit[p->len] = 0;
  } else if (h->ordinal == VX_WSYS_KEYMAP && len == sizeof(vx_wsys_keymap)) {
    memcpy(keymap, ((const vx_wsys_keymap *)m)->name, sizeof keymap - 1);
  }
}

// The input method's part: x becomes ξ, anything else passes on.
static void on_ime(const vx_wsys_ime_key *k) {
  vx_wsys_ime_answer a = {.h = {.ordinal = VX_WSYS_IME_ANSWER}, .seq = k->seq};
  if (k->key.usage == (VX_HID_KEYBOARD | 0x1b) && k->key.action == VX_KEY_DOWN) {
    static const char XI[] = "\xce\xbe"; // ξ
    memcpy(a.text, XI, 2), a.commit_len = 2;
  } else {
    a.flags = VX_WSYS_IME_PASS;
  }
  vx_channel_write(ime, &a, sizeof a, nullptr, 0);
}

static bool committed_ends(const char *s) {
  size_t n = vx_cstr(s).len;
  return ncommitted >= n && memcmp(committed + ncommitted - n, s, n) == 0;
}

static bool seen_down(uint32_t id) {
  for (uint32_t i = 0; i < nkey_down; i++)
    if (key_down_usage[i] == (VX_HID_KEYBOARD | id)) return true;
  return false;
}

static void present_once(void) {
  vx_buffer b;
  uint8_t *px = nullptr;
  CHECK(vx_buffer_alloc(&b, cfg.pwidth, cfg.pheight, VX_FORMAT_XRGB8888) == VX_OK &&
        vx_buffer_map(&b, true, &px) == VX_OK);
  for (uint32_t y = 0; px && y < cfg.pheight; y++)
    for (uint32_t x = 0; x < cfg.pwidth; x++)
      ((uint32_t *)(px + (size_t)y * b.desc.plane[0].stride))[x] = 0xf0f0e8;
  vx_wsys_attach at = {.h = {.ordinal = VX_WSYS_ATTACH}, .id = 1};
  vx_handle h[2];
  CHECK(vx_buffer_put(&b, false, &at.desc, h) == VX_OK);
  vx_wsys_reply r = {};
  vx_call c = {.wr_bytes = &at,
               .wr_handles = h,
               .wr_len = sizeof at,
               .wr_count = 2,
               .rd_bytes = &r,
               .rd_cap = sizeof r};
  CHECK(vx_channel_call(ch, &c, vx_now() + 5'000'000'000) == VX_OK && !r.h.flags);
  vx_buffer_signal(&b, 1);
  vx_wsys_present p = {.h = {.ordinal = VX_WSYS_PRESENT},
                       .seq = 1,
                       .id = 1,
                       .acquire = 1,
                       .release = 2,
                       .config_seq = cfg.seq};
  vx_channel_write(ch, &p, sizeof p, nullptr, 0);
}

const char *vx_main(void) {
  ctl("/wsys/ctl", "move 60 60");
  CHECK(vx_ns_open_post(vx_ns_process(), VX_STR("/wsys/surface"), &ch) == VX_OK);
  CHECK(vx_mount(VX_STR("/srv/wsys"), VX_STR(""), VX_STR("/n"), 0) == VX_OK); // the whole tree, for the IME
  bool presented = false;
  uint32_t stage = 0, mark = 0;
  vx_print(VX_STR("textest: ready\n"));
  for (;;) {
    vx_handle port;
    vx_packet pk;
    vx_port_create(0, &port);
    vx_port_bind(port, ch, VX_TRIGGER_READABLE, 1, 0);
    if (ime) vx_port_bind(port, ime, VX_TRIGGER_READABLE, 2, 0);
    vx_port_wait(port, vx_now() + 50'000'000, 0, &pk, 1);
    vx_handle_close(port);
    for (;;) {
      alignas(vx_wsys_configure) uint8_t m[256];
      vx_msg_size size;
      if (vx_channel_read(ch, m, sizeof m, nullptr, 0, &size) != VX_OK) break;
      on_record(m, size.bytes);
    }
    for (; ime;) {
      vx_wsys_ime_key k;
      vx_msg_size size;
      if (vx_channel_read(ime, &k, sizeof k, nullptr, 0, &size) != VX_OK) break;
      if (size.bytes == sizeof k && k.h.ordinal == VX_WSYS_IME_KEY) on_ime(&k);
    }
    if (!presented && cfg.seq) present_once(), presented = true;
    if (stage == 0 && focused) {
      vx_print(VX_STR("textest: focused\n"));
      stage = 1, mark = keys;
    } else if (stage == 1 && seen_down(0x04) && keys >= mark + 2) { // a's DOWN and UP
      CHECK(ncommitted == 0 && plain_keys == keys);                 // the IME off: keys alone, no text
      ctl("/wsys/ime", "enable");
      vx_print(VX_STR("textest: a as a key alone; the ime on\n"));
      stage = 2;
    } else if (stage == 2 && committed_ends("A")) {
      vx_print(VX_STR("textest: committed A\n"));
      stage = 3;
    } else if (stage == 3 && committed_ends("\xc3\xa9")) { // é
      CHECK(vx_str_eq(vx_cstr(preedit), VX_STR("'")));     // the sequence shown while it was made
      vx_print(VX_STR("textest: compose ' e made \xc3\xa9\n"));
      stage = 4;
    } else if (stage == 4 && vx_str_eq(vx_cstr(keymap), VX_STR("us-intl"))) {
      vx_print(VX_STR("textest: keymap us-intl\n"));
      stage = 5;
    } else if (stage == 5 && committed_ends("\xc3\xa1")) { // á
      vx_print(VX_STR("textest: dead ' a made \xc3\xa1\n"));
      stage = 6, mark = repeats;
    } else if (stage == 6 && repeats > mark && committed_ends("b") && seen_down(0x05)) {
      stage = 7;
    } else if (stage == 7 && vx_now() > 0) {
      // Wait for the hold to end: no repeat in the last 300 ms.
      static uint32_t last = 0;
      static vx_instant since = 0;
      if (repeats != last) last = repeats, since = vx_now();
      if (vx_now() - since > 300'000'000) {
        uint32_t n = repeats - mark;
        CHECK(n >= 5);
        vx_printf("textest: b repeated, %s\n", n >= 5 ? "flagged REPEAT" : "too few times");
        CHECK(vx_ns_open_post(vx_ns_process(), VX_STR("/n/ime"), &ime) == VX_OK);
        vx_print(VX_STR("textest: holding the ime\n"));
        stage = 8, mark = keys;
      }
    } else if (stage == 8 && committed_ends("\xce\xbe") && seen_down(0x1c)) { // ξ, then y's DOWN
      CHECK(!seen_down(0x1b));                                                // x consumed by the IME: no KEY
      CHECK(!committed_ends("y") && imepass_keys > 0);
      vx_print(VX_STR("textest: the ime made \xce\xbe and passed y\n"));
      vx_handle_close(ime), ime = VX_HANDLE_NONE;
      vx_printf("textest: %u checks, %u failed\n", checks, failures);
      vx_print(VX_STR("textest: holding\n"));
      stage = 9;
    }
  }
}
