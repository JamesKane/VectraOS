// text_test.c: lib/vx-text (M7 step 7g1a). The piece tree against a plain
// byte array under random edits (lines, runes, reads, chunks past
// VX_TEXT_CHUNK); anchors followed through edits; the undo tree's undo,
// redo, branches and reverts; and sam's language: addresses, every command,
// many selections, regular expressions, and its errors in sam's words.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-text/text.c"

static uint64_t rng = 88172645463325252ull;
static uint64_t next_random(void) {
  rng ^= rng << 13, rng ^= rng >> 7, rng ^= rng << 17;
  return rng;
}

static bool same(vx_text *t, const char *want, size_t n) {
  if (vx_text_len(t) != n) return false;
  char *got = malloc(n + 1);
  bool ok = vx_text_read(t, 0, got, n) == n && memcmp(got, want, n) == 0;
  free(got);
  return ok;
}

static bool same_str(vx_text *t, const char *want) { return same(t, want, strlen(want)); }

// --- The tree against a model ---

typedef struct model {
  char *p;
  size_t n, cap;
} model;

static void model_replace(model *m, size_t p0, size_t p1, const char *s, size_t n) {
  if (m->n - (p1 - p0) + n > m->cap) {
    m->cap = (m->n + n) * 2 + 16;
    char *p = realloc(m->p, m->cap);
    if (!p) abort();
    m->p = p;
  }
  memmove(m->p + p0 + n, m->p + p1, m->n - p1);
  memcpy(m->p + p0, s, n);
  m->n = m->n - (p1 - p0) + n;
}

typedef struct tracked {
  vx_text_anchor a;
  uint64_t want;
  bool live;
} tracked;

static void check_summaries(vx_text *t, const model *m) {
  uint64_t lines = 0, runes = 0;
  for (size_t i = 0; i < m->n; i++)
    lines += m->p[i] == '\n', runes += ((unsigned char)m->p[i] & 0xc0) != 0x80;
  CHECK(vx_text_lines(t) == lines);
  CHECK(vx_text_runes(t) == runes);
  for (int k = 0; k < 20; k++) {
    uint64_t off = m->n ? next_random() % (m->n + 1) : 0;
    uint64_t want_line = 0, want_rune = 0;
    for (size_t i = 0; i < off; i++)
      want_line += m->p[i] == '\n', want_rune += ((unsigned char)m->p[i] & 0xc0) != 0x80;
    CHECK(vx_text_line_of(t, off) == want_line);
    CHECK(vx_text_rune_of(t, off) == want_rune);
    // line want_line starts after the newline before off
    uint64_t start = off;
    while (start > 0 && m->p[start - 1] != '\n') start--;
    CHECK(vx_text_line_start(t, want_line) == start);
    // rune want_rune starts at the lead byte at or after... the one counted next
    uint64_t rs = off;
    while (rs < m->n && ((unsigned char)m->p[rs] & 0xc0) == 0x80) rs++;
    CHECK(vx_text_rune_start(t, want_rune) == rs);
    char buf[300];
    uint64_t n = next_random() % sizeof buf;
    uint64_t got = vx_text_read(t, off, buf, n);
    CHECK(got == (off + n <= m->n ? n : m->n - off));
    CHECK(memcmp(buf, m->p + off, got) == 0);
  }
}

static void random_bytes(char *p, size_t n) {
  static const char alphabet[] = "ab\n\xc3\xa9\xe2\x82\xac\x80z";
  for (size_t i = 0; i < n; i++) p[i] = alphabet[next_random() % (sizeof alphabet - 1)];
}

static void test_tree(void) {
  static char original[20000];
  random_bytes(original, sizeof original);
  vx_text *t = vx_text_new(original, sizeof original);
  model m = {};
  model_replace(&m, 0, 0, original, sizeof original);
  CHECK(same(t, m.p, m.n));
  tracked anchors[64] = {};
  static char ins[20000];
  for (int step = 0; step < 3000; step++) {
    // anchors made at random places
    tracked *tr = &anchors[next_random() % 64];
    uint64_t at = next_random() % (m.n + 1);
    uint32_t bias = next_random() % 2 ? VX_TEXT_LEFT : VX_TEXT_RIGHT;
    *tr = (tracked){vx_text_anchor_at(t, at, bias), at, true};
    CHECK(vx_text_resolve(t, tr->a) == at);
    uint64_t p0 = next_random() % (m.n + 1), p1 = p0, n = 0;
    switch (next_random() % 4) {
    case 0: p1 = p0 + next_random() % (m.n - p0 + 1); break;                              // delete
    case 1: n = next_random() % 4 + 1; break;                                             // type
    case 2: n = step % 97 == 0 ? 9000 + next_random() % 9000 : next_random() % 40; break; // paste
    default: p1 = p0 + next_random() % (m.n - p0 + 1) % 50, n = next_random() % 30; break;
    }
    if (step % 13 == 0 && m.n) p0 = p1 = m.n, n = 3; // typing at the end extends
    random_bytes(ins, n);
    CHECK(vx_text_replace(t, p0, p1, ins, n));
    model_replace(&m, p0, p1, ins, n);
    for (int i = 0; i < 64; i++) {
      tracked *a = &anchors[i];
      if (!a->live) continue;
      uint64_t w = a->want;
      bool left = a->a.bias == VX_TEXT_LEFT;
      // the byte the anchor holds to, deleted: no longer followed
      if (p1 > p0 && a->a.insertion < VX_TEXT_START && (left ? w > p0 && w <= p1 : w >= p0 && w < p1)) {
        a->live = false;
        continue;
      }
      if (w > p1 || (w == p1 && (p1 > p0 || !left))) w = w - (p1 - p0) + n;
      a->want = w;
      CHECK(vx_text_resolve(t, a->a) == a->want);
    }
    if (step % 50 == 0) {
      CHECK(same(t, m.p, m.n));
      check_summaries(t, &m);
    }
  }
  CHECK(same(t, m.p, m.n));
  check_summaries(t, &m);
  // typing kept in few fragments: one insertion grows
  vx_text *u = vx_text_new("", 0);
  vx_text_begin(u, VX_STR("typing"));
  for (int i = 0; i < 1000; i++) vx_text_insert(u, (uint64_t)i, "x", 1);
  vx_text_end(u);
  CHECK(vx_text_len(u) == 1000);
  CHECK(u->nnodes < 10);
  vx_text_free(u);
  vx_text_free(t);
  free(m.p);
}

// --- The undo tree ---

static void test_undo(void) {
  vx_text *t = vx_text_new("hello\n", 6);
  CHECK(!vx_text_undo(t) && !vx_text_redo(t));
  vx_text_insert(t, 5, ", world", 7); // group 1
  CHECK(same_str(t, "hello, world\n"));
  vx_text_delete(t, 0, 1); // group 2
  CHECK(same_str(t, "ello, world\n"));
  CHECK(vx_text_undo(t) && same_str(t, "hello, world\n"));
  CHECK(vx_text_undo(t) && same_str(t, "hello\n"));
  CHECK(!vx_text_undo(t));
  CHECK(vx_text_redo(t) && same_str(t, "hello, world\n"));
  CHECK(vx_text_redo(t) && same_str(t, "ello, world\n"));
  CHECK(!vx_text_redo(t));
  // a branch: undo, then edit; the old branch is kept
  vx_text_undo(t);
  vx_text_insert(t, 0, ">", 1); // group 3, a child of 1
  CHECK(same_str(t, ">hello, world\n"));
  vx_text_group_info g;
  CHECK(vx_text_group(t, 3, &g) && g.parent == 1 && g.applied);
  CHECK(vx_text_group(t, 2, &g) && g.parent == 1 && !g.applied);
  vx_text_undo(t); // back to 1; redo now goes to 3, the last made
  CHECK(vx_text_redo(t) && same_str(t, ">hello, world\n"));
  vx_text_undo(t), vx_text_undo(t);
  CHECK(same_str(t, "hello\n"));
  // a group of several edits, with a source
  vx_text_begin(t, VX_STR("agent"));
  vx_text_insert(t, 0, "AB", 2);
  vx_text_delete(t, 1, 3); // deletes some of what it inserted
  vx_text_end(t);
  CHECK(same_str(t, "Aello\n"));
  uint32_t agent = vx_text_head(t);
  CHECK(vx_text_group(t, agent, &g) && g.source.len == 5 && memcmp(g.source.ptr, "agent", 5) == 0);
  CHECK(vx_text_undo(t) && same_str(t, "hello\n"));
  CHECK(vx_text_redo(t) && same_str(t, "Aello\n"));
  // an empty group leaves no trace
  uint32_t groups = vx_text_groups(t);
  vx_text_begin(t, VX_STR("nothing"));
  vx_text_end(t);
  CHECK(vx_text_groups(t) == groups);
  // revert: take back the agent's group alone, under later typing
  vx_text_insert(t, 6, "more\n", 5);
  CHECK(same_str(t, "Aello\nmore\n"));
  CHECK(vx_text_revert(t, agent, VX_STR("user")));
  CHECK(same_str(t, "hello\nmore\n"));
  CHECK(vx_text_group(t, vx_text_head(t), &g) && g.reverts == agent);
  CHECK(!vx_text_revert(t, agent, VX_STR("user")));       // already taken back
  CHECK(vx_text_undo(t) && same_str(t, "Aello\nmore\n")); // the revert undone
  CHECK(vx_text_redo(t) && same_str(t, "hello\nmore\n"));
  CHECK(vx_text_undo(t) && vx_text_undo(t) && same_str(t, "Aello\n"));
  CHECK(!vx_text_revert(t, 2, VX_STR("user"))); // not on the current path
  // undo refused inside a group
  vx_text_begin(t, VX_STR("x"));
  CHECK(!vx_text_undo(t));
  vx_text_end(t);
  vx_text_free(t);
}

// The undo tree against saved states: random edits, undos and redos.
static void test_undo_random(void) {
  enum { MAXG = 400 };
  static char *state[MAXG];
  static uint32_t parent[MAXG], last[MAXG];
  vx_text *t = vx_text_new("start\n", 6);
  state[0] = strdup("start\n");
  uint32_t head = 0, ngroups = 1;
  char buf[4096];
  for (int step = 0; step < 1500 && ngroups < MAXG; step++) {
    uint64_t r = next_random() % 10;
    if (r < 3) {
      bool ok = vx_text_undo(t);
      CHECK(ok == (head != 0));
      if (ok) last[parent[head]] = head, head = parent[head];
    } else if (r < 5) {
      bool ok = vx_text_redo(t);
      CHECK(ok == (last[head] != 0));
      if (ok) head = last[head];
    } else {
      uint64_t len = vx_text_len(t);
      vx_text_begin(t, VX_STR("t"));
      for (int k = (int)(next_random() % 3); k >= 0; k--) {
        len = vx_text_len(t);
        uint64_t p0 = next_random() % (len + 1), p1 = p0 + next_random() % (len - p0 + 1) % 8;
        char ins[8];
        uint64_t n = next_random() % 6;
        random_bytes(ins, n);
        vx_text_replace(t, p0, p1, ins, n);
      }
      vx_text_end(t);
      if (vx_text_head(t) != head) {
        uint32_t g = vx_text_head(t);
        CHECK(g == ngroups);
        parent[g] = head, last[head] = g, last[g] = 0;
        len = vx_text_len(t);
        state[g] = malloc(len + 1);
        vx_text_read(t, 0, state[g], len);
        state[g][len] = 0;
        head = g, ngroups++;
      }
    }
    CHECK(vx_text_head(t) == head);
    uint64_t len = vx_text_read(t, 0, buf, sizeof buf - 1);
    buf[len] = 0;
    CHECK(len == vx_text_len(t) && strcmp(buf, state[head]) == 0);
  }
  for (uint32_t i = 0; i < ngroups; i++) free(state[i]);
  vx_text_free(t);
}

// --- sam ---

static char out[65536];
static size_t outn;

static void print(void *arg, const char *p, size_t n) {
  (void)arg;
  if (outn + n < sizeof out) memcpy(out + outn, p, n), outn += n;
  out[outn] = 0;
}

// The shell: | upper-cases, < gives "in\n", > prints what it gets.
static char shellout[4096];
static bool shell(void *arg, char kind, vx_str command, vx_str in, vx_str *result) {
  (void)arg;
  if (command.len == 5 && memcmp(command.ptr, "false", 5) == 0) return false;
  if (kind == '<') {
    *result = VX_STR("in\n");
    return true;
  }
  if (kind == '>') {
    print(nullptr, in.ptr, in.len);
    return true;
  }
  for (size_t i = 0; i < in.len && i < sizeof shellout; i++)
    shellout[i] = (char)(in.ptr[i] >= 'a' && in.ptr[i] <= 'z' ? in.ptr[i] - 32 : in.ptr[i]);
  *result = (vx_str){shellout, in.len};
  return true;
}

static const vx_text_io io = {.print = print, .shell = shell};

// Runs cmd on text with dot at d0,d1; checks the text, then dot ("p0,p1"
// a selection, joined by spaces), what was printed, and the error.
static void sam_case(int line, const char *text, uint64_t d0, uint64_t d1, const char *cmd, const char *want,
                     const char *want_dot, const char *want_out, const char *want_err) {
  vx_text *t = vx_text_new(text, strlen(text));
  vx_text_dot dot = {};
  vx_text_dot_set(&dot, d0, d1);
  char err[128];
  outn = 0, out[0] = 0;
  bool ok = vx_text_run(t, (vx_str){cmd, strlen(cmd)}, &dot, &io, VX_STR("test"), err, sizeof err);
  char got_dot[1024];
  size_t k = 0;
  got_dot[0] = 0;
  for (size_t i = 0; i < dot.n && k < sizeof got_dot - 64; i++)
    k += (size_t)snprintf(got_dot + k, sizeof got_dot - k, "%s%llu,%llu", i ? " " : "",
                          (unsigned long long)dot.r[i].p0, (unsigned long long)dot.r[i].p1);
  char got[4096];
  uint64_t n = vx_text_read(t, 0, got, sizeof got - 1);
  got[n] = 0;
  bool good = (want_err ? !ok && strcmp(err, want_err) == 0 : ok) && strcmp(got, want) == 0 &&
              (!want_dot || strcmp(got_dot, want_dot) == 0) && (!want_out || strcmp(out, want_out) == 0);
  if (!good)
    fprintf(stderr, "text_test.c:%d: %s: text \"%s\" dot %s out \"%s\" error \"%s\"\n", line, cmd, got,
            got_dot, out, ok ? "" : err);
  CHECK(good);
  vx_text_dot_free(&dot);
  vx_text_free(t);
}

#define SAM(...) sam_case(__LINE__, __VA_ARGS__)

static const char C[] = "int main(void) {\n"
                        "  fprintf(stderr, \"a\");\n"
                        "  return 0;\n"
                        "}\n"
                        "static int foo_bar(int x) {\n"
                        "  fprintf(stderr, \"b\"); // TODO\n"
                        "}\n";

static void test_sam(void) {
  // addresses
  SAM("one\ntwo\nthree\n", 0, 0, "2", "one\ntwo\nthree\n", "4,8", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "0", "one\ntwo\nthree\n", "0,0", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "$", "one\ntwo\nthree\n", "14,14", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, ",", "one\ntwo\nthree\n", "0,14", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "2,3", "one\ntwo\nthree\n", "4,14", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 4, 8, "+", "one\ntwo\nthree\n", "8,14", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 4, 8, "-", "one\ntwo\nthree\n", "0,4", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 4, 8, "-0", "one\ntwo\nthree\n", "4,4", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "1+1", "one\ntwo\nthree\n", "4,8", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "3-2", "one\ntwo\nthree\n", "0,4", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "#5", "one\ntwo\nthree\n", "5,5", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "#1,#3", "one\ntwo\nthree\n", "1,3", nullptr, nullptr);
  SAM("h\xc3\xa9llo\n", 0, 0, "#2,#4", "h\xc3\xa9llo\n", "3,5", nullptr, nullptr); // runes, not bytes
  SAM("one\ntwo\nthree\n", 0, 0, "/t/", "one\ntwo\nthree\n", "4,5", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "/t.*/", "one\ntwo\nthree\n", "4,7", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 5, 5, "/t/", "one\ntwo\nthree\n", "8,9", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 9, 9, "/o/", "one\ntwo\nthree\n", "0,1", nullptr, nullptr);   // wraps
  SAM("one\ntwo\nthree\n", 14, 14, "?o?", "one\ntwo\nthree\n", "6,7", nullptr, nullptr); // backward
  SAM("one\ntwo\nthree\n", 3, 3, "?t?", "one\ntwo\nthree\n", "8,9", nullptr, nullptr);   // wraps back
  SAM("one\ntwo\nthree\n", 0, 0, "/two/+", "one\ntwo\nthree\n", "8,14", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "/two/-", "one\ntwo\nthree\n", "0,4", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "/o/;/e/", "one\ntwo\nthree\n", "0,3", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "/o/,/e/", "one\ntwo\nthree\n", "0,3", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "/w/;/e/", "one\ntwo\nthree\n", "5,12", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "3;-", "one\ntwo\nthree\n", "8,8", nullptr, nullptr); // ; moves dot first
  SAM("int x;\n{\n  a;\n}\nb\n", 7, 7, ".,/^}/", "int x;\n{\n  a;\n}\nb\n", "7,15", nullptr, nullptr);
  SAM("abc", 0, 0, "/c$/", "abc", "2,3", nullptr, nullptr); // $ at the end of text
  SAM("one\ntwo\n", 0, 0, "/^t/", "one\ntwo\n", "4,5", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "/e\\n/", "one\ntwo\n", "2,4", nullptr, nullptr);
  SAM("a/b\n", 0, 0, "/\\//", "a/b\n", "1,2", nullptr, nullptr);       // an escaped delimiter
  SAM("aXbXc\n", 0, 0, "/X/\n//", "aXbXc\n", "3,4", nullptr, nullptr); // // is the last pattern
  SAM("one\n", 0, 0, "5", "one\n", "0,0", nullptr, "address range");
  SAM("one\n", 0, 0, "/zz/", "one\n", "0,0", nullptr, "search");
  SAM("one\ntwo\n", 0, 0, "3,1", "one\ntwo\n", "0,0", nullptr, "addresses out of order");
  SAM("one\n", 0, 0, "#9", "one\n", "0,0", nullptr, "address range");

  // the commands
  SAM("one\ntwo\n", 0, 0, "2d", "one\n", "4,4", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "1a/X\\n/", "one\nX\ntwo\n", "4,6", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "2i/X\\n/", "one\nX\ntwo\n", "4,6", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "2c/X\\n/", "one\nX\n", "4,6", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "$a\nthree\nfour\n.\n", "one\ntwo\nthree\nfour\n", "8,19", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "1c\n.\n", "two\n", "0,0", nullptr, nullptr);
  SAM("one\n", 0, 0, "a/a\\nb\\\\c/", "a\nb\\cone\n", nullptr, nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, ",p", "one\ntwo\n", "0,8", "one\ntwo\n", nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "2=", "one\ntwo\nthree\n", "0,0", "2\n", nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "2,3=", "one\ntwo\nthree\n", nullptr, "2,3\n", nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, "2=#", "one\ntwo\nthree\n", nullptr, "#4,#8\n", nullptr);
  SAM("one two\n", 0, 0, ",s/o/0/", "0ne two\n", "0,8", nullptr, nullptr);
  SAM("one two\n", 0, 0, ",s/o/0/g", "0ne tw0\n", "0,8", nullptr, nullptr);
  SAM("one two\n", 0, 0, ",s2/o/0/", "one tw0\n", nullptr, nullptr, nullptr);
  SAM("aabbb\n", 0, 0, ",s/(a+)(b+)/\\2\\1/", "bbbaa\n", nullptr, nullptr, nullptr);
  SAM("abc\n", 0, 0, ",s/b/[&]/", "a[b]c\n", nullptr, nullptr, nullptr);
  SAM("abc\n", 0, 0, ",s/b/\\&/", "a&c\n", nullptr, nullptr, nullptr);
  SAM("abc\n", 0, 0, ",s/x*/-/g", "-a-b-c-\n-", nullptr, nullptr, nullptr);
  SAM("abc\n", 0, 0, ",s/z/y/", "abc\n", "0,0", nullptr, "substitution");
  SAM("one\ntwo\n", 0, 0, "1m$", "two\none\n", "4,8", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "2m0", "two\none\n", "0,4", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "1t$", "one\ntwo\none\n", "8,12", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "1,2m1", "one\ntwo\n", nullptr, nullptr, "addresses overlap");
  SAM("one\ntwo\n", 0, 0, "1|tr", "ONE\ntwo\n", "0,4", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "2<cmd", "one\nin\n", "4,7", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, "2>cmd", "one\ntwo\n", "4,8", "two\n", nullptr);
  SAM("one\n", 0, 0, "1|false", "one\n", nullptr, nullptr, "exit status");
  SAM("one\ntwo\n", 0, 0, "{\n1d\n2d\n}", "", "0,0", nullptr, nullptr);
  SAM("one\n", 0, 0, ",{\nd\nd\n}", "one\n", nullptr, nullptr, "changes not in sequence");
  SAM("one\n", 0, 0, "1d\nu", "one\n", nullptr, nullptr, nullptr);
  SAM("one\n", 0, 0, "1d\nu\nu-1", "", nullptr, nullptr, nullptr);

  // x, y, g, v: the loops, and selection
  SAM(C, 0, 0, ",x/fprintf\\(stderr, /c/vx_log(/",
      "int main(void) {\n  vx_log(\"a\");\n  return 0;\n}\nstatic int foo_bar(int x) {\n  vx_log(\"b\"); // "
      "TODO\n}\n",
      "19,26 76,83", nullptr, nullptr);
  SAM(C, 0, 0, ",x/^static int [a-z_]+\\(/", C, "55,74", nullptr, nullptr);
  SAM("a b  c\n", 0, 6, "y/[ \\t]+/", "a b  c\n", "0,1 2,3 5,6", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, ",x", "one\ntwo\nthree\n", "0,4 4,8 8,14", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, ",x g/o/d", "three\n", "0,0", nullptr, nullptr);
  SAM("one\ntwo\nthree\n", 0, 0, ",x v/o/d", "one\ntwo\n", "8,8", nullptr, nullptr);
  SAM(C, 0, 0, ",x g/TODO/ |tr",
      "int main(void) {\n  fprintf(stderr, \"a\");\n  return 0;\n}\nstatic int foo_bar(int x) {\n"
      "  FPRINTF(STDERR, \"B\"); // TODO\n}\n",
      "83,115", nullptr, nullptr);
  SAM("a1b22c\n", 0, 0, ",x/[0-9]+/i/</", "a<1b<22c\n", "1,2 4,5", nullptr, nullptr);
  SAM("a1b22c\n", 0, 0, ",x/[0-9]+/a/>/", "a1>b22>c\n", "2,3 6,7", nullptr, nullptr);
  SAM("abab\n", 0, 0, ",x/a|ab/", "abab\n", "0,2 2,4", nullptr, nullptr); // leftmost-longest
  SAM("aaa\n", 0, 0, ",x/a*/", "aaa\n", "0,3 4,4", nullptr, nullptr);
  SAM("a\nb\n", 0, 0, ",x/./", "a\nb\n", "0,1 2,3", nullptr, nullptr); // . is not a newline
  SAM("a\nb\n", 0, 0, ",x/[^a]/", "a\nb\n", "2,3", nullptr, nullptr);  // nor is [^a]
  SAM("x-y]z\n", 0, 0, ",x/[\\]\\-]/", "x-y]z\n", "1,2 3,4", nullptr, nullptr);
  SAM("a1-b2\n", 0, 0, ",x/[a-z][0-9]/", "a1-b2\n", "0,2 3,5", nullptr, nullptr); // two classes
  SAM("caf\xc3\xa9!\n", 0, 0, ",x/[\xc3\xa0-\xc3\xbf]/", "caf\xc3\xa9!\n", "3,5", nullptr, nullptr);
  SAM("one\ntwo\n", 0, 0, ",x/o/x/./c/0/", "0ne\ntw0\n", nullptr, nullptr, nullptr);
  SAM("a b\n", 0, 0, ",x/[a-z]/{\ni/(/\na/)/\n}", "(a) (b)\n", "0,1 2,3 4,5 6,7", nullptr, nullptr);

  // many selections: a command once for each
  {
    vx_text *t = vx_text_new("one two three\n", 14);
    vx_text_dot dot = {};
    char err[64];
    CHECK(vx_text_run(t, VX_STR(",x/[a-z]+/"), &dot, &io, VX_STR("user"), err, sizeof err));
    CHECK(dot.n == 3);
    CHECK(vx_text_run(t, VX_STR("i/<</"), &dot, &io, VX_STR("user"), err, sizeof err));
    CHECK(same_str(t, "<<one <<two <<three\n"));
    CHECK(dot.n == 3 && dot.r[1].p0 == 6 && dot.r[1].p1 == 8);
    CHECK(vx_text_run(t, VX_STR("c/X/"), &dot, &io, VX_STR("user"), err, sizeof err));
    CHECK(same_str(t, "Xone Xtwo Xthree\n"));
    CHECK(vx_text_run(t, VX_STR("+-"), &dot, &io, VX_STR("user"), err, sizeof err)); // each its line: one
    CHECK(dot.n == 1 && dot.r[0].p0 == 0 && dot.r[0].p1 == 17);
    // one run is one group: a single undo takes back the x's three changes
    vx_text_undo(t);
    CHECK(same_str(t, "<<one <<two <<three\n"));
    vx_text_dot_free(&dot);
    vx_text_free(t);
  }

  // parse errors, in sam's words (9front sam's own, release 11952)
  SAM("one\n", 0, 0, ",x/(/", "one\n", nullptr, nullptr, "no operand for `('");
  SAM("one\n", 0, 0, ",x/(a/", "one\n", nullptr, nullptr, "unmatched `('");
  SAM("one\n", 0, 0, ",x/)/", "one\n", nullptr, nullptr, "unmatched `)'");
  SAM("one\n", 0, 0, ",x/[a/", "one\n", nullptr, nullptr, "malformed `[]'");
  SAM("one\n", 0, 0, ",x/*/", "one\n", nullptr, nullptr, "no operand for `*'");
  SAM("one\n", 0, 0, ",x/a|/", "one\n", nullptr, nullptr, "no operand for `|'");
  SAM("one\n", 0, 0, ",z", "one\n", nullptr, nullptr, "unknown command `z'");
  SAM("one\n", 0, 0, ",sapbp", "one\n", nullptr, nullptr, "bad delimiter `a'");
  SAM("one\n", 0, 0, "d d", "one\n", nullptr, nullptr, "newline expected");
  SAM("one\n", 0, 0, ",x/o/{\nd", "one\n", nullptr, nullptr, "unmatched `{'");
  SAM("one\n", 0, 0, "}", "one\n", nullptr, nullptr, "unmatched `}'");
  SAM("one\n", 0, 0, "1u", "one\n", nullptr, nullptr, "command takes no address");
  SAM("one\n", 0, 0, ",x/o/u", "one\n", nullptr, nullptr, "u in a loop");
  SAM("one\n", 0, 0, "x", "one\n", nullptr, nullptr, nullptr);
  SAM("one\n", 0, 0, "1|cmd", "ONE\n", nullptr, nullptr, nullptr);
  {
    vx_text *t = vx_text_new("ab", 2);
    vx_text_dot dot = {};
    char err[64];
    CHECK(!vx_text_run(t, VX_STR("1|x"), &dot, nullptr, VX_STR("u"), err, sizeof err));
    CHECK(strcmp(err, "no shell") == 0);
    vx_text_dot_free(&dot);
    vx_text_free(t);
  }
}

// A big text: ,x/re/c/ over many lines, against the obvious loop.
static void test_big(void) {
  enum { LINES = 100000 };
  size_t cap = (size_t)LINES * 24, n = 0;
  char *src = malloc(cap), *want = malloc(cap * 2);
  size_t wn = 0;
  for (int i = 0; i < LINES; i++) {
    n += (size_t)snprintf(src + n, cap - n, i % 3 ? "x = %d;\n" : "fprintf(%d);\n", i);
    wn += (size_t)snprintf(want + wn, cap * 2 - wn, i % 3 ? "x = %d;\n" : "vx_log(%d);\n", i);
  }
  vx_text *t = vx_text_new(src, n);
  vx_text_dot dot = {};
  char err[64];
  CHECK(vx_text_run(t, VX_STR(",x/fprintf/c/vx_log/"), &dot, &io, VX_STR("user"), err, sizeof err));
  CHECK(dot.n == (LINES + 2) / 3);
  CHECK(same(t, want, wn));
  CHECK(vx_text_lines(t) == LINES);
  CHECK(vx_text_line_start(t, 50000) == (uint64_t)(strstr(want, "x = 50000;") - want));
  CHECK(vx_text_undo(t) && same(t, src, n));
  vx_text_dot_free(&dot);
  vx_text_free(t);
  free(src), free(want);
}

int main(void) {
  test_tree();
  test_undo();
  test_undo_random();
  test_sam();
  test_big();
  return check_result();
}
