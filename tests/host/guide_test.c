// guide_test.c: lib/vx-guide (docs/12-manual.md §4, guide(6)). A page
// rendered exactly as Plan 9's would be; every error the format names
// refused, at its line; the inline spans and table cells; nodes rendered
// alone; and every page under man/ parsed and rendered.

#include <dirent.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-guide/guide.c"

typedef struct sink {
  char buf[1 << 16];
  size_t n;
} sink;

static void sink_write(void *ctx, const char *s, size_t n) {
  sink *k = ctx;
  if (k->n + n > sizeof k->buf) abort();
  memcpy(k->buf + k->n, s, n);
  k->n += n;
}

static sink out;

static const char *render(const char *page, uint32_t width, const char *node) {
  out.n = 0;
  vx_guide_out o = {.write = sink_write, .ctx = &out, .width = width};
  const char *error;
  size_t line;
  if (!vx_guide_render((vx_str){page, strlen(page)}, node, &o, &error, &line)) return nullptr;
  if (out.n == sizeof out.buf) abort();
  out.buf[out.n] = 0;
  return out.buf;
}

static const char CAT[] = "page=cat sect=1 summary=\"concatenate files\"\n"
                          "    names=cat\n"
                          "    src=cmd/cat.c\n"
                          "\n"
                          "# SYNOPSIS\n"
                          "\n"
                          "```usage\n"
                          "cat [-u] [file ...]\n"
                          "```\n"
                          "\n"
                          "# DESCRIPTION\n"
                          "\n"
                          "`cat` reads each <file> in order and writes it to standard output. With no\n"
                          "<file>, or with a <file> of `-`, it reads standard input. Data is copied as\n"
                          "bytes and never checked: see {text and bytes|utf(6)#bytes}.\n"
                          "\n"
                          ": `-u`\n"
                          "  Write each read as it arrives, without collecting full blocks.\n"
                          "\n"
                          "# SEE ALSO\n"
                          "\n"
                          "tail(1), read(2)\n";

static const char CAT_44[] = "CAT(1)                                CAT(1)\n"
                             "\n"
                             "NAME\n"
                             "     cat — concatenate files\n"
                             "\n"
                             "SYNOPSIS\n"
                             "     cat [-u] [file ...]\n"
                             "\n"
                             "DESCRIPTION\n"
                             "     cat reads each <file> in order and\n"
                             "     writes it to standard output. With no\n"
                             "     <file>, or with a <file> of -, it reads\n"
                             "     standard input. Data is copied as bytes\n"
                             "     and never checked: see text and bytes\n"
                             "     (utf(6)#bytes).\n"
                             "\n"
                             "     -u   Write each read as it arrives,\n"
                             "          without collecting full blocks.\n"
                             "\n"
                             "SOURCE\n"
                             "     cmd/cat.c\n"
                             "\n"
                             "SEE ALSO\n"
                             "     tail(1), read(2)\n";

static void test_render(void) {
  const char *got = render(CAT, 44, nullptr);
  CHECK(got && strcmp(got, CAT_44) == 0);
  if (got && strcmp(got, CAT_44) != 0) fprintf(stderr, "rendered:\n%s", got);
  // No line ends in a space, and none passes the width but an unbreakable word.
  got = render(CAT, 30, nullptr);
  CHECK(got && !strstr(got, " \n"));
  // SOURCE goes last when nothing comes after it in Plan 9's order.
  got = render("page=x sect=1 summary=s src=a.c,b.c\n\n# DESCRIPTION\n\nText.\n", 80, nullptr);
  CHECK(got && strstr(got, "Text.\n\nSOURCE\n     a.c\n     b.c\n"));
  // A table: columns as wide as their widest cell; a | in a literal is the cell's.
  got = render("page=t sect=7 summary=s\n\n| A | Bee |\n| `x|y` | z |\n", 80, nullptr);
  CHECK(got && strstr(got, "     A    Bee\n     x|y  z\n"));
  // A word longer than the line, and multi-byte text, wrap without splitting a rune.
  static char long_page[2048];
  int n = snprintf(long_page, sizeof long_page, "page=w sect=7 summary=s\n\n");
  for (int i = 0; i < 300; i++) n += snprintf(long_page + n, sizeof long_page - (size_t)n, "é");
  snprintf(long_page + n, sizeof long_page - (size_t)n, " end\n");
  got = render(long_page, 20, nullptr);
  CHECK(got && vx_utf_valid(got, strlen(got)) && strstr(got, "end\n"));
  // A table cell longer than its buffer is cut on a whole rune (the Odin port's finding).
  n = snprintf(long_page, sizeof long_page, "page=t sect=7 summary=s\n\n| ");
  for (int i = 0; i < 300; i++) n += snprintf(long_page + n, sizeof long_page - (size_t)n, "é");
  snprintf(long_page + n, sizeof long_page - (size_t)n, " | b |\n| c | d |\n");
  got = render(long_page, 80, nullptr);
  CHECK(got && vx_utf_valid(got, strlen(got)));
}

// A header value decoded from ndb's hex form must be UTF-8 too (guide_fuzz's find).
static void test_header_utf8(void) {
  CHECK(!render("page=t sect=7 summary=x\"C0\"\n\nText.\n", 80, nullptr));
  CHECK(render("page=t sect=7 summary=x\"C3A9\"\n\nText.\n", 80, nullptr)); // é
}

static void test_nodes(void) {
  const char *page = "page=rc sect=1 summary=shell\n\n# DESCRIPTION\n\nMain.\n\n"
                     "@node=quoting title=\"Quoting\"\n\nQuotes.\n\n@node=vars\n\nVariables.\n";
  const char *got = render(page, 80, "quoting");
  CHECK(got && strcmp(got, "QUOTING\n     Quotes.\n") == 0);
  got = render(page, 80, "vars");
  CHECK(got && strcmp(got, "VARS\n     Variables.\n") == 0);
  CHECK(render(page, 80, "nope") == nullptr);
  got = render(page, 80, nullptr);
  CHECK(got && strstr(got, "Main.\n\nQUOTING\n     Quotes.\n\nVARS\n     Variables.\n"));
}

// Each page is refused, its error naming the line.
static void test_errors(void) {
  static const struct {
    const char *page, *error;
    size_t line;
  } bad[] = {
      {"sect=1 page=x summary=s\n", "first tuple is page=", 1},
      {"page=x summary=s\n", "needs sect=", 1},
      {"page=x sect=9 summary=s\n", "1 to 8", 1},
      {"page=X sect=1 summary=s\n", "lower case", 1},
      {"page=x sect=1 summary=s colour=red\n", "does not know", 1},
      {"page=x sect=1 summary=s lang=go\n", "c, lua or rc", 1},
      {"page=x sect=1 summary=s host=yes\n", "flag", 1},
      {"page=x sect=1 summary=s names=a,,b\n", "empty or malformed", 1},
      {"page=x sect=1 summary=s\npage=y sect=1 summary=s\n", "one record", 1},
      {"@guide=2\npage=x sect=1 summary=s\n", "version", 1},
      {"page=x sect=1 summary=s\n\n```perl\nx\n```\n", "fence kind", 3},
      {"page=x sect=1 summary=s\n\n```\nnever closed\n", "never closed", 3},
      {"page=x sect=1 summary=s\n\n### Deep\n", "# or ##", 3},
      {"page=x sect=1 summary=s\n\n# NAME\n", "made from the header", 3},
      {"page=x sect=1 summary=s\n\nText.\n\n  dangling\n", "nothing to continue", 5},
      {"page=x sect=1 summary=s\n\n@include=y\n", "directive", 3},
      {"page=x sect=1 summary=s\n\n@guide=1\n", "comes first", 3},
      {"page=x sect=1 summary=s\n\n@node=a\n\n@node=a\n", "used twice", 5},
      {"page=x sect=1 summary=s\n\n@node=Big\n", "bare", 3},
      {"page=x sect=1 summary=s\n\n@node=\"a\"\n", "bare", 3},
      {"page=x sect=1 summary=s\n\n@node=a colour=red\n", "node key", 3},
      {"page=x sect=1 summary=s\n\n: \n", "no term", 3},
      {"page=x sect=1 summary=s\n\nAn `open literal.\n", "never closed", 3},
      {"page=x sect=1 summary=s\n\nSee {here|nowhere}.\n", "no target", 3},
      {"page=x sect=1 summary=s\n\nSee {unclosed.\n", "never closed", 3},
      {"page=x sect=1 summary=s\n\nSee {ftp://x}.\n", "no target", 3},
      {"page=x sect=1 summary=s\n\nA\x01 control.\n", "control", 3},
      {"page=x sect=1 summary=s\n\n\xff\n", "UTF-8", 1},
  };
  for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
    vx_guide_out o = {.write = sink_write, .ctx = &out};
    const char *error = nullptr;
    size_t line = 0;
    out.n = 0;
    bool ok = vx_guide_render((vx_str){bad[i].page, strlen(bad[i].page)}, nullptr, &o, &error, &line);
    bool right = !ok && error && strstr(error, bad[i].error) && line == bad[i].line;
    CHECK(right);
    if (!right) fprintf(stderr, "  page %zu: %s, line %zu\n", i, error ? error : "(accepted)", line);
  }
  // What is allowed: @guide=1 first, a target of each kind, a node with keys.
  CHECK(render("@guide=1\npage=x sect=1 summary=s\n\nA.\n", 80, nullptr) != nullptr);
  CHECK(
      render("page=x sect=1 summary=s\n\n{rc(1)} {a|rc(1)#quoting} {b|#n} {c|https://x.org/a} {d|gemini://g} "
             "{e|gopher://h}\n\n@node=n keys=a,b\n",
             80, nullptr) != nullptr);
}

static void test_spans(void) {
  static const char text[] = "Use ``a `b` c`` and <file-1>, rc(1). {x|vx_create(2)}<no";
  static const struct {
    vx_guide_span_kind kind;
    const char *text;
  } want[] = {
      {VX_SPAN_TEXT, "Use"},
      {VX_SPAN_SPACE, " "},
      {VX_SPAN_LITERAL, "a `b` c"},
      {VX_SPAN_SPACE, " "},
      {VX_SPAN_TEXT, "and"},
      {VX_SPAN_SPACE, " "},
      {VX_SPAN_PARAM, "<file-1>"},
      {VX_SPAN_TEXT, ","},
      {VX_SPAN_SPACE, " "},
      {VX_SPAN_REF, "rc(1)"},
      {VX_SPAN_TEXT, "."},
      {VX_SPAN_SPACE, " "},
      {VX_SPAN_LINK, "{x|vx_create(2)}"},
      {VX_SPAN_TEXT, "<no"},
      {VX_SPAN_END, ""},
  };
  vx_guide_inline it = {.s = {text, strlen(text)}};
  vx_guide_span sp;
  for (size_t i = 0; i < sizeof want / sizeof want[0]; i++) {
    vx_guide_span_kind k = vx_guide_span_next(&it, &sp);
    bool right = k == want[i].kind && sp.text.len == strlen(want[i].text) &&
                 (!sp.text.len || memcmp(sp.text.ptr, want[i].text, sp.text.len) == 0);
    CHECK(right);
    if (!right) fprintf(stderr, "  span %zu: kind %d, '%.*s'\n", i, (int)k, (int)sp.text.len, sp.text.ptr);
    if (k == VX_SPAN_REF) CHECK(sp.sect == 1 && sp.name.len == 2);
    if (k == VX_SPAN_LINK) CHECK(sp.label.len == 1 && sp.target.len == 12);
  }
  // A reference needs a name before it ends: "x(1)" in "ax(1)" is the name "ax".
  vx_guide_inline ref = {.s = VX_STR("ax(1) (b(2))")};
  CHECK(vx_guide_span_next(&ref, &sp) == VX_SPAN_REF && sp.name.len == 2);
  vx_guide_span_next(&ref, &sp);
  CHECK(vx_guide_span_next(&ref, &sp) == VX_SPAN_TEXT && sp.text.len == 1);
  CHECK(vx_guide_span_next(&ref, &sp) == VX_SPAN_REF && sp.sect == 2);

  vx_str row = VX_STR(" a | `x|y` |  | last"), cell;
  const char *cells[] = {"a", "`x|y`", "", "last"};
  for (size_t i = 0; i < 4; i++)
    CHECK(vx_guide_cell_next(&row, &cell) && cell.len == strlen(cells[i]) &&
          memcmp(cell.ptr, cells[i], cell.len) == 0);
  CHECK(!vx_guide_cell_next(&row, &cell));
}

// Every page under man/ parses and renders, whole and node by node.
static void test_pages(void) {
  int pages = 0;
  for (int sect = 1; sect <= 8; sect++) {
    char dir[32];
    snprintf(dir, sizeof dir, "man/%d", sect);
    DIR *d = opendir(dir);
    if (!d) continue;
    for (struct dirent *e; (e = readdir(d));) {
      if (e->d_name[0] == '.') continue;
      char path[300];
      snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
      FILE *f = fopen(path, "rb");
      static char text[1 << 16];
      size_t n = f ? fread(text, 1, sizeof text - 1, f) : 0;
      if (f) fclose(f);
      text[n] = 0;
      vx_guide_out o = {.write = sink_write, .ctx = &out};
      const char *error = nullptr;
      size_t line = 0;
      out.n = 0;
      bool ok = vx_guide_render((vx_str){text, n}, nullptr, &o, &error, &line);
      CHECK(ok);
      if (!ok) fprintf(stderr, "  %s:%zu: %s\n", path, line, error);
      static vx_guide g;
      vx_guide_block b;
      CHECK(vx_guide_open(&g, (vx_str){text, n}) && g.h.sect == sect && strcmp(e->d_name, "") != 0);
      CHECK(g.h.page.len == strlen(e->d_name) && memcmp(g.h.page.ptr, e->d_name, g.h.page.len) == 0);
      while (vx_guide_next(&g, &b) > VX_GUIDE_END)
        if (b.kind == VX_GUIDE_NODE) {
          char id[64];
          snprintf(id, sizeof id, "%.*s", (int)b.node.len, b.node.ptr);
          CHECK(render(text, 80, id) != nullptr);
        }
      pages++;
    }
    closedir(d);
  }
  CHECK(pages >= 1);
}

int main(void) {
  test_header_utf8();
  test_render();
  test_nodes();
  test_errors();
  test_spans();
  test_pages();
  return check_result();
}
