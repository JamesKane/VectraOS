// plumb_test.c: lib/vx-plumb (M7 step 7g3a). Messages packed and unpacked,
// whole and in parts; attributes quoted; cleanname; and the rule language on
// 9front's own rules (sys/lib/plumb/basic and fileaddr, the parts this
// tree's files can show): a file and line clicked in text, a manual page,
// a URL held for its client, a message no rule takes, an explicit port,
// parse errors with the include stack, writes to the rules file and their
// listing, checked against 9front's plumber's own (release 11952).

#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-plumb/plumb.c"

// --- A file system of fixed names ---

static const char *const FILES[] = {"/usr/glenda/src/main.c", "/lib/plumb/fileaddr", "/lib/plumb/deep",
                                    nullptr};
static const char *const DIRS[] = {"/usr/glenda/src", "/usr/glenda", nullptr};

static const char FILEADDR[] = "addrelem='((#?[0-9]+)|(/[A-Za-z0-9_\\^]+/?)|[.$])'\n"
                               "addr=:($addrelem([,;+\\-]$addrelem)*):?\n";

static int kind(void *ctx, const char *path) {
  (void)ctx;
  for (size_t i = 0; FILES[i]; i++)
    if (strcmp(FILES[i], path) == 0) return VX_PLUMB_FILE;
  for (size_t i = 0; DIRS[i]; i++)
    if (strcmp(DIRS[i], path) == 0) return VX_PLUMB_DIR;
  return VX_PLUMB_NONE;
}

static char *copy(const char *s, size_t *n) {
  *n = strlen(s);
  char *p = vx_plumb_alloc(*n + 1);
  memcpy(p, s, *n + 1);
  return p;
}

static char *read_file(void *ctx, const char *path, size_t *n) {
  (void)ctx;
  if (strcmp(path, "/lib/plumb/fileaddr") == 0) return copy(FILEADDR, n);
  if (strcmp(path, "/lib/plumb/deep") == 0) return copy("type is text\nplumb nowhere x\n", n);
  if (strcmp(path, "/lib/plumb/loop") == 0) return copy("include loop\n", n);
  return nullptr;
}

#define TXT(s) (s), sizeof(s) - 1 // a literal and its length

static const vx_plumb_fs FS = {.kind = kind, .read = read_file};

// From 9front's sys/lib/plumb/basic: the rules this test's files reach.
static const char BASIC[] =
    "# from 9front's basic\n"
    "include fileaddr\n"
    "\n"
    "plumb to seemail\n"
    "plumb to showmail\n"
    "\n"
    "type is text\n"
    "data matches 'https?://[^ ]+'\n"
    "plumb to web\n"
    "plumb client window $browser\n"
    "\n"
    "type is text\n"
    "data matches '([.a-zA-Z¡-\U0010ffff0-9_/+\\-]*[a-zA-Z¡-\U0010ffff0-9_/+\\-])('$addr')?'\n"
    "arg isfile\t$1\n"
    "data set\t$file\n"
    "attr add\taddr=$3\n"
    "plumb to edit\n"
    "plumb client window $editor\n"
    "\n"
    "type is text\n"
    "data matches '([a-zA-Z¡-\U0010ffff0-9_\\-./]+)\\(([1-9])\\)'\n"
    "plumb start rc -c 'man -b '$2' '$1\n"
    "\n"
    "type\tis\ttext\n"
    "data\tmatches\t'Local (.*)'\n"
    "plumb\tto\tnone\n"
    "plumb\tstart\trc -c $1\n";

static vx_plumb_msg *message(const char *wdir, const char *data, const char *attr) {
  vx_plumb_msg *m = vx_plumb_msg_new("plumb", "", wdir, "text", data, strlen(data));
  if (attr) m->attr = vx_plumb_unpack_attr(attr);
  return m;
}

static bool argv_is(char **argv, const char *const want[]) {
  size_t i = 0;
  for (; want[i]; i++)
    if (!argv || !argv[i] || strcmp(argv[i], want[i]) != 0) return false;
  return argv[i] == nullptr;
}

static void test_messages(void) {
  vx_plumb_msg *m = vx_plumb_msg_new("term", "edit", "/usr/glenda", "text", "a b\nc", 5);
  m->attr = vx_plumb_unpack_attr("click=3 addr='4 5' q='it''s' e=");
  CHECK(strcmp(vx_plumb_lookup(m->attr, "addr"), "4 5") == 0);
  CHECK(strcmp(vx_plumb_lookup(m->attr, "q"), "it's") == 0);
  CHECK(strcmp(vx_plumb_lookup(m->attr, "e"), "") == 0);
  size_t n = 0;
  char *packed = vx_plumb_pack(m, &n);
  const char want[] = "term\nedit\n/usr/glenda\ntext\nclick=3 addr='4 5' q='it''s' e=\n5\na b\nc";
  CHECK(n == sizeof want - 1 && memcmp(packed, want, n) == 0);
  size_t more = 99;
  vx_plumb_msg *back = vx_plumb_unpack(packed, n, &more);
  CHECK(back && more == 0);
  if (back) {
    CHECK(strcmp(back->src, "term") == 0 && strcmp(back->dst, "edit") == 0 &&
          strcmp(back->wdir, "/usr/glenda") == 0);
    CHECK(back->ndata == 5 && memcmp(back->data, "a b\nc", 5) == 0 && back->data[5] == 0);
    CHECK(strcmp(vx_plumb_lookup(back->attr, "q"), "it's") == 0);
  }
  vx_plumb_free(back);
  // In parts: what is missing of the data, then too little to say.
  vx_plumb_msg *none = vx_plumb_unpack(packed, n - 2, &more);
  CHECK(none == nullptr && more == 2);
  vx_plumb_free(none);
  none = vx_plumb_unpack(packed, 10, &more);
  CHECK(none == nullptr && more == 0);
  vx_plumb_free(none);
  none = vx_plumb_unpack("a\nb\nc\nd\n\nx1\n", 13, &more); // a count that is not one
  CHECK(none == nullptr && more == 0);
  vx_plumb_free(none);
  vx_plumb_dealloc(packed);
  // Attributes deleted, added, and a malformed one ending the list.
  m->attr = vx_plumb_del_attr(m->attr, "addr");
  CHECK(!vx_plumb_lookup(m->attr, "addr") && vx_plumb_lookup(m->attr, "click"));
  m->attr = vx_plumb_add_attr(m->attr, vx_plumb_unpack_attr("z=1 bad y=2"));
  char *a = vx_plumb_pack_attr(m->attr);
  CHECK(strcmp(a, "click=3 q='it''s' e= z=1") == 0);
  vx_plumb_dealloc(a);
  vx_plumb_free(m);
  m = vx_plumb_msg_new("", "", "", "", "", 0);
  packed = vx_plumb_pack(m, &n);
  CHECK(n == 7 && memcmp(packed, "\n\n\n\n\n0\n", 7) == 0);
  vx_plumb_dealloc(packed);
  vx_plumb_free(m);
}

static void test_clean(void) {
  static const char *const cases[][2] = {
      {"/a/b/../c", "/a/c"},  {"a/../..", ".."},      {"", "."},
      {"/..", "/"},           {"./a//b/", "a/b"},     {"/", "/"},
      {"../../x", "../../x"}, {"a/b/../../..", ".."}, {"/a/./b/.", "/a/b"},
      {"x/..", "."},
  };
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
    char buf[64];
    strcpy(buf, cases[i][0]);
    vx_plumb_clean(buf);
    if (strcmp(buf, cases[i][1]) != 0)
      fprintf(stderr, "clean(%s) = %s, not %s\n", cases[i][0], buf, cases[i][1]);
    CHECK(strcmp(buf, cases[i][1]) == 0);
  }
}

static void test_rules(void) {
  vx_plumb_rules *r = vx_plumb_rules_new(&FS);
  CHECK(vx_plumb_rules_read(r, "basic", BASIC, sizeof BASIC - 1));
  if (vx_plumb_rules_error(r)) fprintf(stderr, "basic: %s\n", vx_plumb_rules_error(r));
  // Ports: the declarations', then each ruleset's, once.
  CHECK(vx_plumb_port_count(r) == 5);
  const char *const ports[] = {"seemail", "showmail", "web", "edit", "none"};
  for (uint32_t i = 0; i < 5; i++) CHECK(vx_plumb_port(r, i) && strcmp(vx_plumb_port(r, i), ports[i]) == 0);

  // A file and line clicked in text: the file, made absolute, to edit, its
  // address an attribute, the click's gone.
  vx_plumb_msg *m = message("/usr/glenda", "see src/main.c:12 there", "click=9");
  vx_plumb_exec *e = vx_plumb_match(r, m);
  CHECK(e != nullptr);
  CHECK(strcmp(m->dst, "edit") == 0);
  CHECK(strcmp(m->data, "/usr/glenda/src/main.c") == 0 && m->ndata == strlen(m->data));
  CHECK(vx_plumb_lookup(m->attr, "addr") && strcmp(vx_plumb_lookup(m->attr, "addr"), "12") == 0);
  CHECK(!vx_plumb_lookup(m->attr, "click"));
  char **argv = nullptr;
  bool hold = false;
  CHECK(vx_plumb_startup(r, e, &argv, &hold) == nullptr && hold);
  CHECK(argv_is(argv, (const char *const[]){"window", "$editor", nullptr})); // no $editor: left as written
  vx_plumb_argv_free(argv);
  vx_plumb_exec_free(e);
  vx_plumb_free(m);

  // A click outside any file name: not edit's; nor any other's.
  m = message("/usr/glenda", "see src/none.c there", "click=6");
  e = vx_plumb_match(r, m);
  CHECK(e == nullptr);
  CHECK(strcmp(vx_plumb_startup(r, e, &argv, &hold), "no start action for plumb message") == 0 && !argv);
  vx_plumb_free(m);

  // A manual page: started, the message not held, the arguments expanded
  // with their quotes taken off.
  m = message("/", "vxui(2)", nullptr);
  e = vx_plumb_match(r, m);
  CHECK(e && strcmp(m->dst, "") == 0);
  CHECK(vx_plumb_startup(r, e, &argv, &hold) == nullptr && !hold);
  CHECK(argv_is(argv, (const char *const[]){"rc", "-c", "man -b 2 vxui", nullptr}));
  vx_plumb_argv_free(argv);
  vx_plumb_exec_free(e);
  vx_plumb_free(m);

  // A URL, whole: web's, held for its client.
  m = message("/", "https://vectra-os.org/a", nullptr);
  e = vx_plumb_match(r, m);
  CHECK(e && strcmp(m->dst, "web") == 0);
  CHECK(vx_plumb_startup(r, e, &argv, &hold) == nullptr && hold);
  vx_plumb_argv_free(argv);
  vx_plumb_exec_free(e);
  vx_plumb_free(m);

  // Not whole, and no click: no rule; to a port named, only that port's rules.
  m = message("/", "go https://vectra-os.org/a", nullptr);
  CHECK(vx_plumb_match(r, m) == nullptr);
  vx_plumb_free(m);
  m = message("/", "https://x.org/", nullptr);
  free(m->dst), m->dst = vp_dup("edit");
  CHECK(vx_plumb_match(r, m) == nullptr);
  vx_plumb_free(m);
  m = message("/", "Local echo hi", nullptr);
  e = vx_plumb_match(r, m);
  CHECK(e && strcmp(m->dst, "none") == 0 && vx_plumb_startup(r, e, &argv, &hold) == nullptr);
  CHECK(argv_is(argv, (const char *const[]){"rc", "-c", "echo hi", nullptr}));
  vx_plumb_argv_free(argv);
  vx_plumb_exec_free(e);
  vx_plumb_free(m);

  // The listing: variables, ports, rulesets as written.
  size_t n = 0;
  char *text = vx_plumb_rules_print(r, &n);
  static const char vars[] = "addrelem='((#?[0-9]+)|(/[A-Za-z0-9_\\^]+/?)|[.$])'\n\naddr=";
  CHECK(text && strncmp(text, vars, sizeof vars - 1) == 0);
  CHECK(strstr(text, "plumb to seemail\nplumb to showmail\nplumb to web\nplumb to edit\nplumb to none\n\n") !=
        nullptr);
  CHECK(strstr(
      text,
      "type\tis\ttext\ndata\tmatches\t'https?://[^ ]+'\nplumb\tto\tweb\nplumb\tclient\twindow $browser\n\n"));
  vx_plumb_dealloc(text);

  // Writing the rules file: a ruleset when its blank line comes, the rest at
  // the close; cleared rules keep their ports.
  vx_plumb_rules_clear(r);
  CHECK(vx_plumb_match(r, m = message("/", "vxui(2)", nullptr)) == nullptr);
  vx_plumb_free(m);
  CHECK(vx_plumb_rules_write(r, TXT("type is text\ndata matches 'x+'\n"), false));
  CHECK(vx_plumb_rules_write(r, TXT("plumb to xs\n\ntype is text\n"), false));
  CHECK(vx_plumb_port_count(r) == 6);
  CHECK(vx_plumb_rules_write(r, TXT("plumb to ys\n"), false) && vx_plumb_port_count(r) == 6);
  CHECK(vx_plumb_rules_write(r, nullptr, 0, true) && vx_plumb_port_count(r) == 7);
  m = message("/", "xxx", nullptr);
  e = vx_plumb_match(r, m);
  CHECK(e && strcmp(m->dst, "xs") == 0);
  vx_plumb_exec_free(e);
  vx_plumb_free(m);
  m = message("/", "yyy", nullptr);
  e = vx_plumb_match(r, m);
  CHECK(e && strcmp(m->dst, "ys") == 0);
  vx_plumb_exec_free(e);
  vx_plumb_free(m);

  // Errors, in 9front's words, with where they are.
  CHECK(!vx_plumb_rules_write(r, TXT("type is text\ndata frobs x\nplumb to z\n\n"), false));
  CHECK(strcmp(vx_plumb_rules_error(r), "<rules input>:2: unknown verb frobs") == 0);
  CHECK(vx_plumb_rules_write(r, nullptr, 0, true)); // the failed text was dropped
  CHECK(!vx_plumb_rules_read(r, "t", TXT("type is text\nplumb to send\n")));
  CHECK(strcmp(vx_plumb_rules_error(r), "t:2: illegal port name send") == 0);
  CHECK(!vx_plumb_rules_read(r, "t", TXT("data matches '('\nplumb to z\n")));
  CHECK(strncmp(vx_plumb_rules_error(r), "t:1: regexp (: ", 15) == 0);
  CHECK(!vx_plumb_rules_read(r, "t", TXT("type is text\nplumb start a\nplumb client b\nplumb to q\n")));
  CHECK(strcmp(vx_plumb_rules_error(r), "t:4: ruleset has more than one client or start action") == 0);
  CHECK(!vx_plumb_rules_read(r, "t", TXT("type is text\n\n")));
  CHECK(strcmp(vx_plumb_rules_error(r), "t:2: ruleset must have patterns and actions") == 0);
  CHECK(!vx_plumb_rules_read(r, "t", TXT("plumb is x\n")));
  CHECK(strcmp(vx_plumb_rules_error(r), "t:1: is not valid verb for object plumb") == 0);
  CHECK(!vx_plumb_rules_read(r, "t", TXT("\n\ninclude deep\n")));
  CHECK(strcmp(vx_plumb_rules_error(r), "t:3: /lib/plumb/deep:2: unknown verb nowhere") == 0);
  CHECK(!vx_plumb_rules_read(r, "t", TXT("include loop\n")));
  CHECK(strstr(vx_plumb_rules_error(r), "include stack too deep; max 10") != nullptr);
  CHECK(!vx_plumb_rules_read(r, "t", TXT("include nothere\n")));
  CHECK(strcmp(vx_plumb_rules_error(r), "t:1: can't open /lib/plumb/nothere for inclusion") == 0);
  CHECK(!vx_plumb_rules_read(r, "t", TXT("type\n")));
  CHECK(strcmp(vx_plumb_rules_error(r), "t:1: malformed rule") == 0);
  vx_plumb_rules_free(r);
}

// The edge of a click: the rune it is on, counted in runes, with UTF-8
// before it; a second data match must select the same text.
static void test_click(void) {
  vx_plumb_rules *r = vx_plumb_rules_new(&FS);
  static const char rules[] = "type is text\n"
                              "data matches '[a-z]+'\n"
                              "data matches 'b[a-z]*'\n"
                              "plumb to words\n"
                              "\n"
                              "type is text\n"
                              "data matches '[a-z]+'\n"
                              "attr add from=$src\n"
                              "attr delete gone\n"
                              "plumb to other\n";
  CHECK(vx_plumb_rules_read(r, "click", rules, sizeof rules - 1));
  vx_plumb_msg *m = message("/", "ééé bravo charlie", "click=5 gone=1");
  vx_plumb_exec *e = vx_plumb_match(r, m);
  CHECK(e && strcmp(m->dst, "words") == 0 && strcmp(m->data, "bravo") == 0);
  vx_plumb_exec_free(e);
  vx_plumb_free(m);
  m = message("/", "ééé bravo charlie", "click=12 gone=1");
  e = vx_plumb_match(r, m);
  CHECK(e && strcmp(m->dst, "other") == 0 && strcmp(m->data, "charlie") == 0);
  CHECK(strcmp(vx_plumb_lookup(m->attr, "from"), "plumb") == 0 && !vx_plumb_lookup(m->attr, "gone"));
  vx_plumb_exec_free(e);
  vx_plumb_free(m);
  m = message("/", "ééé bravo charlie", "click=1");
  CHECK(vx_plumb_match(r, m) == nullptr); // on é, which no rule's letters take
  vx_plumb_free(m);
  vx_plumb_rules_free(r);
}

// 9front's plumber's own listing of these rules (release 11952, its
// fileaddr included), byte for byte: what a read of /mnt/plumb/rules gives.
static void test_listing(void) {
  static const char rules[] =
      "# from 9front's basic\n"
      "include fileaddr\n"
      "\n"
      "plumb to seemail\n"
      "plumb to showmail\n"
      "\n"
      "type is text\n"
      "data matches 'https?://[^ ]+'\n"
      "plumb to web\n"
      "plumb client window $browser\n"
      "\n"
      "type is text\n"
      "data matches '([.a-zA-Z¡-\U0010ffff0-9_/+\\-]*[a-zA-Z¡-\U0010ffff0-9_/+\\-])('$addr')?'\n"
      "arg isfile\t$1\n"
      "data set\t$file\n"
      "attr add\taddr=$3\n"
      "plumb to edit\n"
      "plumb client window $editor\n"
      "\n"
      "type\tis\ttext\n"
      "data\tmatches\t'Local (.*)'\n"
      "plumb\tto\tnone\n"
      "plumb\tstart\techo $1\n";
  static const char want[] =
      "addrelem='((#?[0-9]+)|(/[A-Za-z0-9_\\^]+/?)|[.$])'\n"
      "\n"
      "addr=:($addrelem([,;+\\-]$addrelem)*):?\n"
      "\n"
      "plumb to seemail\n"
      "plumb to showmail\n"
      "plumb to web\n"
      "plumb to edit\n"
      "plumb to none\n"
      "\n"
      "type\tis\ttext\n"
      "data\tmatches\t'https?://[^ ]+'\n"
      "plumb\tto\tweb\n"
      "plumb\tclient\twindow $browser\n"
      "\n"
      "type\tis\ttext\n"
      "data\tmatches\t'([.a-zA-Z¡-\U0010ffff0-9_/+\\-]*[a-zA-Z¡-\U0010ffff0-9_/+\\-])('$addr')?'\n"
      "arg\tisfile\t$1\n"
      "data\tset\t$file\n"
      "attr\tadd\taddr=$3\n"
      "plumb\tto\tedit\n"
      "plumb\tclient\twindow $editor\n"
      "\n"
      "type\tis\ttext\n"
      "data\tmatches\t'Local (.*)'\n"
      "plumb\tto\tnone\n"
      "plumb\tstart\techo $1\n"
      "\n";
  vx_plumb_rules *r = vx_plumb_rules_new(&FS);
  CHECK(vx_plumb_rules_read(r, "rules", TXT(rules)));
  size_t n = 0;
  char *text = vx_plumb_rules_print(r, &n);
  CHECK(text && n == sizeof want - 1 && memcmp(text, want, n) == 0);
  vx_plumb_dealloc(text);
  // And its message to edit for a click on "src/main.c:12" in /tmp/pt.
  vx_plumb_msg *m = message("/tmp/pt", "see src/main.c:12 there", "click=9");
  free(m->wdir), m->wdir = vp_dup("/tmp/pt");
  vx_plumb_exec *e = vx_plumb_match(r, m);
  CHECK(e == nullptr); // /tmp/pt/src/main.c is not this test's file
  vx_plumb_exec_free(e);
  vx_plumb_free(m);
  m = message("/usr/glenda", "see src/main.c:12 there", "click=9");
  e = vx_plumb_match(r, m);
  char *packed = e ? vx_plumb_pack(m, &n) : nullptr;
  static const char sent[] = "plumb\nedit\n/usr/glenda\ntext\naddr=12\n22\n/usr/glenda/src/main.c";
  CHECK(packed && n == sizeof sent - 1 && memcmp(packed, sent, n) == 0);
  vx_plumb_dealloc(packed);
  vx_plumb_exec_free(e);
  vx_plumb_free(m);
  vx_plumb_rules_free(r);
}

int main(void) {
  test_messages();
  test_clean();
  test_rules();
  test_click();
  test_listing();
  return check_result();
}
