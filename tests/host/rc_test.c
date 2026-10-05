// rc_test.c: lib/vx-rc, the rc language, on a host of the test's own: its
// programs (echo, cat, wc, true, false, exitwith) write into buffers, its files
// are in memory, and its directory has a few names for globbing. Each script's
// output is compared with what rc gives.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-rc/rc.c"

static char out[8192], err[1024];
static size_t nout, nerr;

static struct {
  char name[32];
  char data[1024];
  size_t len;
} files[8];

static int file_of(const char *path, size_t n, bool make) {
  for (int i = 0; i < 8; i++)
    if (files[i].name[0] && strlen(files[i].name) == n && memcmp(files[i].name, path, n) == 0) return i;
  if (!make) return -1;
  for (int i = 0; i < 8; i++)
    if (!files[i].name[0] && n < sizeof files[i].name) {
      memcpy(files[i].name, path, n);
      files[i].name[n] = 0;
      files[i].len = 0;
      return i;
    }
  return -1;
}

// Output to where fd goes: a file, the shell's capture, or out/err.
static void emit(rc *r, const rc_fd *fds, uint32_t which, const char *s, size_t n, char *pipe,
                 size_t *npipe) {
  const rc_fd *fd = &fds[which];
  for (int guard = 0; fd->kind == RC_FD_DUP && fd->dup < RC_FDS && guard < 10; guard++) fd = &fds[fd->dup];
  if (fd->kind == RC_FD_CAPTURE) return rc_capture_write(r, fd, s, n);
  if (fd->kind == RC_FD_PIPE_OUT) {
    memcpy(pipe + *npipe, s, n), *npipe += n;
    return;
  }
  if (fd->kind == RC_FD_WRITE || fd->kind == RC_FD_APPEND) { // the file the shell opened
    uint32_t f = fd->handle;
    if (f < 8 && files[f].len + n <= sizeof files[f].data)
      memcpy(files[f].data + files[f].len, s, n), files[f].len += n;
    return;
  }
  if (fd->kind == RC_FD_CLOSED) return;
  if (fd->kind == RC_FD_INHERIT && fd->dup == 2)
    memcpy(err + nerr, s, n), nerr += n;
  else
    memcpy(out + nout, s, n), nout += n;
}

static bool open_now[8]; // the files the shell has open, by handle
static bool used_closed; // a stage was given a file the shell had already closed

// A pipeline, its stages run in turn; $status as rc makes it, each stage's
// joined by rc_concstatus.
static bool run(void *ctx, rc *r, const rc_command *stages, uint32_t n, bool async, uint64_t *pid) {
  (void)ctx;
  static char pipes[2][4096];
  size_t npipe[2] = {};
  char status[256] = "";
  size_t nstatus = 0;
  for (uint32_t i = 0; i < n; i++) {
    const rc_command *c = &stages[i];
    rc_fd fds[RC_FDS];
    memcpy(fds, c->fds, sizeof fds);
    for (uint32_t k = 0; k < RC_FDS; k++)
      if ((fds[k].kind == RC_FD_READ || fds[k].kind == RC_FD_WRITE || fds[k].kind == RC_FD_APPEND) &&
          (fds[k].handle >= 8 || !open_now[fds[k].handle]))
        used_closed = true;
    // Its input: the stage before's output, a file, or nothing.
    const char *in = "";
    size_t nin = 0;
    if (fds[0].kind == RC_FD_PIPE_IN) in = pipes[(i + 1) % 2], nin = npipe[(i + 1) % 2];
    if (fds[0].kind == RC_FD_READ && fds[0].handle < 8)
      in = files[fds[0].handle].data, nin = files[fds[0].handle].len;
    if (fds[0].kind == RC_FD_HERE) in = fds[0].path, nin = fds[0].path_len;
    char *mypipe = pipes[i % 2];
    size_t *mynpipe = &npipe[i % 2];
    *mynpipe = 0;
    const char *name = c->argv->s;
    const char *st = "";
    if (!strcmp(name, "warn")) { // its words, on its standard error
      for (const rc_word *w = c->argv->next; w; w = w->next) {
        emit(r, fds, 2, w->s, w->len, mypipe, mynpipe);
        emit(r, fds, 2, w->next ? " " : "\n", 1, mypipe, mynpipe);
      }
    } else if (!strcmp(name, "echo")) {
      for (const rc_word *w = c->argv->next; w; w = w->next) {
        emit(r, fds, 1, w->s, w->len, mypipe, mynpipe);
        emit(r, fds, 1, w->next ? " " : "\n", 1, mypipe, mynpipe);
      }
      if (!c->argv->next) emit(r, fds, 1, "\n", 1, mypipe, mynpipe);
    } else if (!strcmp(name, "cat")) {
      emit(r, fds, 1, in, nin, mypipe, mynpipe);
    } else if (!strcmp(name, "wc")) { // words
      int words = 0;
      for (size_t k = 0; k < nin;) {
        while (k < nin && (in[k] == ' ' || in[k] == '\n')) k++;
        if (k < nin) words++;
        while (k < nin && in[k] != ' ' && in[k] != '\n') k++;
      }
      char num[16];
      int len = snprintf(num, sizeof num, "%d\n", words);
      emit(r, fds, 1, num, (size_t)len, mypipe, mynpipe);
    } else if (!strcmp(name, "true")) {
    } else if (!strcmp(name, "false")) {
      st = "false";
    } else if (!strcmp(name, "exitwith")) {
      st = c->argv->next ? c->argv->next->s : "";
    } else {
      st = "not found";
    }
    rc_concstatus(status, &nstatus, sizeof status - 1, st, strlen(st));
  }
  if (async) *pid = 42;
  rc_set_status(r, status, nstatus);
  return true;
}

static void write_fd(void *ctx, const rc_fd *fd, uint32_t which, const char *s, size_t n) {
  (void)ctx, (void)which;
  if (fd->kind == RC_FD_INHERIT && fd->dup == 2)
    memcpy(err + nerr, s, n), nerr += n;
  else
    memcpy(out + nout, s, n), nout += n;
}

static int opened, closed;

static bool open_fake(void *ctx, rc *rr, const char *path, size_t len, uint8_t kind, uint32_t *handle) {
  (void)ctx, (void)rr;
  int k = file_of(path, len, kind != RC_FD_READ);
  if (k < 0) return false;
  if (kind == RC_FD_WRITE) files[k].len = 0; // emptied once, where the redirection is
  *handle = (uint32_t)k;
  open_now[k] = true;
  opened++;
  return true;
}

static void close_fake(void *ctx, uint32_t handle) {
  (void)ctx;
  if (handle < 8) open_now[handle] = false;
  closed++;
}

static bool readdir_fake(void *ctx, const char *path, size_t len, void (*each)(void *, const char *, size_t),
                         void *arg) {
  (void)ctx;
  static const char *const here[] = {"a.c", "b.c", "x.h", ".hidden", "dir"};
  static const char *const dir[] = {"one.c", "two.txt"};
  if (len == 1 && path[0] == '.') {
    for (size_t i = 0; i < 5; i++) each(arg, here[i], strlen(here[i]));
    return true;
  }
  if (len == 4 && memcmp(path, "dir/", 4) == 0) {
    for (size_t i = 0; i < 2; i++) each(arg, dir[i], strlen(dir[i]));
    return true;
  }
  return false;
}

static bool exists_fake(void *ctx, const char *path, size_t len) {
  (void)ctx;
  static const char *const names[] = {"a.c", "b.c", "x.h", ".hidden", "dir", "dir/one.c", "dir/two.txt"};
  for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
    if (strlen(names[i]) == len && memcmp(names[i], path, len) == 0) return true;
  return file_of(path, len, false) >= 0;
}

static const char *stdin_text; // what rc's own standard input holds, a line at a time
static size_t stdin_at;

static int64_t read_line_fake(void *ctx, char *buf, size_t cap) {
  (void)ctx;
  if (!stdin_text || !stdin_text[stdin_at]) return 0;
  size_t n = 0;
  while (stdin_text[stdin_at] && n < cap) {
    char c = stdin_text[stdin_at++];
    buf[n++] = c;
    if (c == '\n') break;
  }
  return (int64_t)n;
}

static int64_t read_file_fake(void *ctx, const char *path, size_t len, char *buf, size_t cap) {
  (void)ctx;
  int k = file_of(path, len, false);
  if (k < 0 || files[k].len > cap) return -1;
  memcpy(buf, files[k].data, files[k].len);
  return (int64_t)files[k].len;
}

static char exported[256]; // exportx's: x's value as rc_each_var gives it

static void each_var(void *arg, const char *name, const rc_word *val) {
  (void)arg;
  if (strcmp(name, "x") != 0) return;
  size_t at = strlen(exported);
  for (const rc_word *w = val; w && at + w->len + 4 < sizeof exported; w = w->next)
    at += (size_t)snprintf(exported + at, sizeof exported - at, "x=%s;", w->s);
}

static bool host_builtin(void *ctx, rc *rr, const rc_word *argv, uint32_t argc, const rc_fd *fds) {
  (void)ctx, (void)argc, (void)fds;
  if (strcmp(argv->s, "exportx") != 0) return false;
  exported[0] = 0;
  rc_each_var(rr, each_var, nullptr);
  rc_set_status(rr, "", 0);
  return true;
}

static alignas(16) uint8_t heap[4 << 20];
static rc *r;

static rc_result script(const char *text) {
  nout = nerr = 0;
  memset(out, 0, sizeof out);
  return rc_run(r, text, strlen(text));
}

static void expect(const char *text, const char *want) {
  rc_result res = script(text);
  bool ok = res == RC_OK && strcmp(out, want) == 0;
  if (!ok)
    fprintf(stderr, "script [%s]: result %d, out [%s] (wanted [%s]) %s\n", text, res, out, want, rc_err(r));
  CHECK(ok);
}

static const char *status_now(void) {
  static char buf[256];
  const rc_word *w = rc_getvar(r, "status");
  snprintf(buf, sizeof buf, "%.*s", w ? (int)w->len : 0, w ? w->s : "");
  return buf;
}

// 9front's rc, as its rc(1) and source have it (M6 step 6a6a): each line is
// one of the differences a survey found, now the same.
static void test_9front(void) {
  // Syntax rc's grammar refuses.
  CHECK(script("echo a(b c)") == RC_SYNTAX);
  CHECK(script("not echo x") == RC_SYNTAX);
  CHECK(script("in") == RC_SYNTAX);
  CHECK(script("y=(a b); echo $$y") == RC_FAILED && strstr(rc_err(r), "$ variable name not singleton!"));
  CHECK(script("y=(a b); $y=1") == RC_FAILED && strstr(rc_err(r), "= variable name not singleton!"));
  expect("x=1; echo for$x", "for 1\n"); // no caret after a keyword
  expect("echo for in not", "for in not\n");
  // ~ and switch match the list as one word; ~ with no patterns does not match.
  expect("x=(a b); if(~ $x 'a b') echo joined", "joined\n");
  expect("if(~ () '') echo empty", "empty\n");
  expect("if(! ~ ()) echo none", "none\n");
  expect("x=(a b); switch($x){case a; echo A; case 'a b'; echo AB}", "AB\n");
  expect("switch(){case ''; echo empty}", "empty\n");
  CHECK(script("switch(a){echo x; case a; echo A}") == RC_SYNTAX &&
        strstr(rc_err(r), "case missing in switch"));
  expect("switch(a){case a; echo A; 'case' b; echo B}", "A\nB\n"); // a quoted case is a command
  // if not follows an if, or is refused when compiled.
  CHECK(script("if not echo x") == RC_SYNTAX && strstr(rc_err(r), "`if not' does not follow `if(...)'"));
  CHECK(script("if(false) echo a; echo mid; if not echo b") == RC_SYNTAX);
  expect("if(false) echo a\nif not echo b", "b\n");
  CHECK(script("if(false) echo a; if not echo b; if not echo c") == RC_SYNTAX); // an if not ends iflast
  expect("x=y; $x=hello; echo $y", "hello\n");                                  // a name from a variable
  // while() is true; ^ of two empty lists is empty, of one an error.
  CHECK(script("false; while(){ echo once; exit }") == RC_EXIT && strcmp(out, "once\n") == 0);
  expect("x=(); y=(); echo a $x^$y b", "a b\n");
  CHECK(script("x=(); echo a^$x") == RC_FAILED && strstr(rc_err(r), "null list in concatenation"));
  CHECK(script("x=(1 2 3); y=(a b); echo $x^$y") == RC_FAILED &&
        strstr(rc_err(r), "mismatched list lengths"));
  // Subscripts as rc's subwords; $1(...) is a variable named 1's.
  expect("x=(a b c); echo $x(0-2) . $x(2x) . $x(3-1) . $x(2-9)", ". b . . b c\n");
  expect("fn f { echo $1(1) $#1 $#3 }; f a b", "1 0\n");
  // $ifs of several words: joined by spaces, so a space separates too.
  expect("ifs=(: ';'); x=`{echo 'a:b;c d'}; echo $#x", "4\n");
  // An empty command is an error.
  CHECK(script("x=(); $x") == RC_FAILED && strstr(rc_err(r), "empty argument list"));
  // A pipeline's status, as concstatus; truth by the first word.
  expect("exitwith '' | exitwith 3; echo $status", "3\n");
  expect("exitwith 3 | exitwith ''; echo $status", "3|\n");
  expect("fn t { status=('' no) }; if(t) echo first", "first\n");
  // Functions are global: a local of the same name does not hide one.
  expect("fn f { echo F }; f=1 f", "F\n");
  CHECK(script("fn g { echo G }; g &") == RC_OK && strcmp(out, "") == 0 &&
        strcmp(status_now(), "async") == 0);
  // Globbing: . and .. alone need an explicit dot; a plain name after a
  // pattern must exist; ? and classes match runes; ranges either way round.
  expect("echo *", ".hidden a.c b.c dir x.h\n");
  expect("echo */one.c", "dir/one.c\n");
  expect("echo */nosuch", "*/nosuch\n");
  expect("if(~ \xc3\xa9 ?) echo rune", "rune\n");
  expect("if(~ b [c-a]) echo reversed", "reversed\n");
  expect("if(~ \xc3\xa9 [\xc3\xa0-\xc3\xaf]) echo class", "class\n");
  expect("echo a\x01"
         "b; if(~ a\x01"
         "b a\x01"
         "b) echo same",
         "a\x01"
         "b\nsame\n"); // the glob byte, itself
  // A block's redirection is the whole block's; a failed one says rc's way.
  expect("echo data > f; { cat; cat } < f", "data\ndata\n");
  CHECK(script("cat < nosuchfile") == RC_FAILED && strstr(rc_err(r), "rc:1: < can't open: nosuchfile"));
  CHECK(script("echo x >\n") == RC_SYNTAX);
  // A syntax error's message is $status, as rc's yyerror.
  CHECK(script("echo )") == RC_SYNTAX && strcmp(status_now(), "") != 0 && strstr(rc_err(r), status_now()));
}

static void errs_reset(void) {
  nerr = 0;
  memset(err, 0, sizeof err);
}

// The second part (M6 step 6a6b): reading a command at a time, here
// documents, flag and the flags it sets, ., eval, and interactive input.
static void test_9front_reading(void) {
  // A script runs as it is read: a syntax error stops at its line, the lines
  // before it run.
  CHECK(script("echo ok\necho )\necho after") == RC_SYNTAX && strcmp(out, "ok\n") == 0);
  // Here documents: substituted unless the tag is quoted; several on a line,
  // in order; a block's; [n]; one that never ends asks for more.
  expect("x=(a b); cat <<EOF\nv=$x $$x $x^y\nEOF\n", "v=a b $x a by\n");
  expect("cat <<'EOF'\nraw $x\nEOF\n", "raw $x\n");
  expect("fn f { cat <<EOF\n$1 $2\nEOF\n}; f p q", "p q\n");
  expect("cat <<A; cat <<B\none\nA\ntwo\nB\n", "one\ntwo\n");
  expect("{ cat } <<EOF\nblock\nEOF\n", "block\n");
  expect("cat <<[0]EOF\nzero\nEOF\n", "zero\n");
  CHECK(script("cat <<EOF\nnever ends\n") == RC_INCOMPLETE);
  // A pipeline stage's here document is fed as written, not freed before the
  // stage runs; a here document closes no file (slot 0 is a real one: the
  // block's output here); an output here document is no file either (the
  // Odin port's findings).
  expect("cat <<EOF | wc\nhello there\nEOF\n", "2\n");
  int closes = closed;
  expect("{ cat <<EOF\nhi\nEOF\n echo y } >/tmp/o", "");
  CHECK(closed - closes == 1); // the block's output alone, not a here document's slot 0
  expect("cat </tmp/o", "hi\ny\n");
  expect("cat </tmp/o | wc", "2\n");
  // More redirections in one pipeline than rc keeps for it: refused, its
  // stages not run, nothing closed under them.
  static char many[8192];
  size_t at = 0;
  for (int i = 0; i < 60; i++)
    at += (size_t)snprintf(many + at, sizeof many - at,
                           "echo a >[2]/tmp/o >[3]/tmp/o >[4]/tmp/o >[5]/tmp/o >[6]/tmp/o | ");
  snprintf(many + at, sizeof many - at, "cat");
  used_closed = false;
  CHECK(script(many) != RC_OK || strcmp(status_now(), "") != 0);
  CHECK(!used_closed && strcmp(out, "") == 0);
  // Descriptors of more digits lex, and past the ones there are, are refused.
  CHECK(script("echo x >[10] f\n") == RC_SYNTAX);
  // flag, and what the flags do.
  expect("flag z; echo $status", "flag not set\n");
  CHECK(script("flag") == RC_FAILED && strstr(rc_err(r), "Usage: flag [letter] [+-]"));
  errs_reset();
  CHECK(script("flag x +\necho hi 'a b'\nflag x -") == RC_OK && strstr(err, "echo hi 'a b'\n"));
  CHECK(script("flag e +\nif(false) echo no\necho yes\nfalse\necho never\n") == RC_EXIT &&
        strcmp(out, "yes\n") == 0);
  script("flag e -");
  errs_reset();
  CHECK(script("flag s +\nfalse\nflag s -") == RC_OK && strstr(err, "status=false\n"));
  errs_reset();
  CHECK(script("flag v +\necho v\nflag v -") == RC_OK && strstr(err, "echo v\n"));
  errs_reset();
  CHECK(script("flag r +\ntrue\nflag r -") == RC_OK && strstr(err, "Xsimple"));
  // .: $0 and $*, $path, -q; refused with no file, or one not there.
  CHECK(script("echo 'echo $0 $* $#*' > d.rc") == RC_OK);
  expect(". d.rc a b", "d.rc a b 2\n");
  expect("path=(/x .); . d.rc z", "d.rc z 1\n");
  expect(". -q nofile; echo q", "q\n");
  CHECK(script(". nofile") == RC_FAILED && strstr(rc_err(r), ". can't open: nofile: file does not exist"));
  CHECK(script(".") == RC_FAILED && strstr(rc_err(r), "Usage: . [-biq] file [arg ...]"));
  CHECK(script("echo 'echo first' > bad.rc; echo 'echo )' >> bad.rc") == RC_OK);
  CHECK(script(". bad.rc") == RC_SYNTAX && strcmp(out, "first\n") == 0 && strstr(rc_err(r), "bad.rc:2:"));
  script("path=()");
  // eval.
  CHECK(script("eval") == RC_FAILED && strstr(rc_err(r), "Usage: eval cmd ..."));
  expect("eval 'y=5'; echo $y", "5\n");
  CHECK(script("eval 'echo )'") == RC_SYNTAX && strstr(rc_err(r), "*eval*"));
  // Interactive: prompts on rc's standard error; an error goes back to it,
  // and the next line runs.
  errs_reset();
  stdin_text = "x=(); echo a^$x\necho two\n", stdin_at = 0;
  CHECK(script(". -i '#d/0'") == RC_OK && strcmp(out, "two\n") == 0 && strstr(err, "% ") &&
        strstr(err, "null list"));
  errs_reset();
  stdin_text = "prompt=('> ' '>> ')\nif(true) {\necho in\n}\n", stdin_at = 0;
  CHECK(script(". -i '#d/0'") == RC_OK && strcmp(out, "in\n") == 0 && strstr(err, ">> "));
  script("prompt=()");
  stdin_text = "echo s1\nx=(); echo a^$x\necho s2\n", stdin_at = 0; // not interactive: an error ends it
  CHECK(script(". '#d/0'") == RC_FAILED && strcmp(out, "s1\n") == 0);
  stdin_text = nullptr;
}

static char fns[256]; // rc_each_fn's, as name=body;

static void each_fn(void *arg, const char *name, const char *src) {
  (void)arg;
  size_t at = strlen(fns);
  snprintf(fns + at, sizeof fns - at, "%s=%s;", name, src);
}

// The third part (M6 step 6a6c): the builtins as rc(1) has them, functions
// for export, sigexit, and notes as functions.
static void test_9front_builtins(void) {
  CHECK(script("false; exit") == RC_EXIT && strcmp(status_now(), "false") == 0); // $status kept
  CHECK(script("exit a b") == RC_EXIT && strcmp(status_now(), "a") == 0);
  expect("fn f { shift 2; echo $* }; f a b c d", "c d\n");
  expect("fn f { shift x; echo $* }; f a b", "a b\n"); // as atoi: 0
  expect("shift 1 2; echo $status", "shift usage\n");
  expect("fn echo { builtin echo wrapped $* }; echo hi; fn echo", "wrapped hi\n");
  CHECK(script("builtin") == RC_FAILED && strstr(rc_err(r), "builtin: empty argument list"));
  CHECK(script("exec") == RC_FAILED && strstr(rc_err(r), "exec: empty argument list"));
  expect("x=(a 'b c'); y=1; whatis x y", "x=(a 'b c')\ny=1\n");
  expect("fn g {echo  G}; whatis g", "fn g {echo  G}\n");
  expect("whatis shift", "builtin shift\n");
  expect("whatis nosuchthing; echo $status", "not found\n");
  expect("path=(dir); whatis one.c; path=()", "dir/one.c\n");
  CHECK(script("whatis") == RC_FAILED && strstr(rc_err(r), "Usage: whatis name ..."));
  fns[0] = 0;
  rc_each_fn(r, each_fn, nullptr);
  CHECK(strstr(fns, "g={echo  G};") != nullptr);
  CHECK(script("fn g") == RC_OK);
  // sigexit, once, at exit.
  CHECK(script("fn sigexit { echo bye }; echo before; exit") == RC_EXIT && strcmp(out, "before\nbye\n") == 0);
  CHECK(script("exit") == RC_EXIT && strcmp(out, "") == 0);
  script("fn sigexit");
  r->trapped = false;
  // A note: its function before the next command; with none, a hangup ends it.
  script("fn sigint { echo caught }");
  rc_trap(r, 2);
  expect("echo next", "caught\nnext\n");
  script("fn sigint");
  // Which function a note runs: 9front's words, and VectraOS's notes as signals.
  CHECK(rc_note_trap(VX_STR("interrupt")) == 2 && rc_note_trap(VX_STR("hangup")) == 1);
  CHECK(rc_note_trap(VX_STR("sys: fp: divide by zero")) == 6);
  CHECK(rc_note_trap(VX_STR("sys: trap: arithmetic pc=0x401000")) == 6);
  CHECK(rc_note_trap(VX_STR("term")) == 7 && rc_note_trap(VX_STR("posix: SIGTERM pid=12")) == 7);
  CHECK(rc_note_trap(VX_STR("posix: SIGQUIT")) == 3 && rc_note_trap(VX_STR("posix: SIGQUIT pid=4")) == 3);
  CHECK(rc_note_trap(VX_STR("posix: SIGUSR1 pid=4")) == 0 &&
        rc_note_trap(VX_STR("sys: trap: fault read")) == 0);
  rc_trap(r, 1);
  CHECK(script("echo never") == RC_EXIT && strcmp(out, "") == 0);
}

int main(void) {
  rc_host host = {.run = run,
                  .write = write_fd,
                  .readdir = readdir_fake,
                  .read_file = read_file_fake,
                  .builtin = host_builtin,
                  .open = open_fake,
                  .close = close_fake,
                  .exists = exists_fake,
                  .read_line = read_line_fake};
  r = rc_new(heap, sizeof heap, &host);
  CHECK(r != nullptr);
  if (!r) return check_result();
  // Words, quoting, lists, carets.
  expect("echo hello world", "hello world\n");
  expect("echo 'it''s' '$x'", "it's $x\n");
  expect("x=(a b c); echo $x $#x $x(2) $\"x", "a b c 3 b a b c\n");
  expect("x=(a b c d); echo $x(2-3) $x(3-)", "b c c d\n");
  expect("x=foo; echo $x.c pre^$x a^(b c)", "foo.c prefoo ab ac\n");
  expect("x=b; echo a$x^c", "abc\n");
  expect("x=(1 2); y=(a b); echo $x^$y", "1a 2b\n");
  CHECK(script("echo a=b") == RC_SYNTAX); // = is not a word, as rc's
  // Control flow.
  expect("if(false) echo no; if not echo yes", "yes\n");
  expect("if(true) echo yes; if not echo no", "yes\n");
  expect("for(i in 1 2 3) echo $i", "1\n2\n3\n");
  expect("x=(a b c); while(! ~ $#x 0) { echo $x(1); x=$x(2-) }", "a\nb\nc\n");
  expect("switch(b){ case a; echo A; case b c; echo BC; case *; echo other }", "BC\n");
  expect("switch(zz){ case a; echo A; case *; echo other }", "other\n");
  expect("if(~ foo f*) echo match", "match\n");
  expect("if(! ~ foo b*) echo nomatch", "nomatch\n");
  expect("true && echo t; false || echo f; false && echo no", "t\nf\n");
  expect("false; echo $status", "false\n");
  expect("exitwith 3 | true; echo $status", "3|\n");
  expect("if(true | true) echo all; if(false | true) echo no", "all\n"); // | and 0s are true, as in rc
  // Functions: $*, $1, dynamic scope, local assignment.
  expect("fn greet { echo hi $1 $#* }; greet bob jo", "hi bob 2\n");
  expect("fn show { echo $x }; x=1; x=2 show; show", "2\n1\n");
  expect("fn f { echo in f }; fn f; f; echo $status", "not found\n");
  // Command substitution, nested in braces and an if.
  expect("x=`{echo a b}; echo $#x", "2\n");
  expect("if(true) { y=`{echo z}; echo $y }", "z\n");
  expect("x=`:{echo a:b:c}; echo $x(2)", "b\n");
  expect("echo `{for(i in a b) echo $i}", "a b\n");
  expect("fn c { echo $* }; c x `{for(i in a b) echo $i}", "x a b\n");
  // Redirections and pipes.
  expect("echo data > f; cat < f", "data\n");
  expect("echo more >> f; cat < f", "data\nmore\n");
  expect("{ echo x; echo y } > g; cat < g", "x\ny\n");
  expect("echo one two three | wc", "3\n");
  expect("echo a b | cat | wc", "2\n");
  expect("echo oops >[1=2]; echo fine", "fine\n");
  // A stage's own files stay open until it runs; its redirections come after
  // the pipe, so >[2=1] follows it, and >f takes the output from it.
  expect("echo data > f; cat < f | wc", "1\n");
  expect("echo a b c | wc > h; cat < h", "3\n");
  expect("warn oops >[2=1] | wc", "1\n");
  expect("echo hi > f | wc; cat < f", "0\nhi\n");
  expect("echo x | echo `{echo a b | wc}", "2\n"); // the inner pipeline runs its own stages only
  CHECK(!used_closed);
  // Globbing: marks only where written bare; no match keeps the word.
  expect("echo *.c", "a.c b.c\n");
  expect("echo '*.c' z* ?.h", "*.c z* x.h\n");
  expect("echo dir/*.c", "dir/one.c\n");
  expect("x=*.c; echo $#x", "2\n");
  expect("for(f in *.c) echo $f", "a.c\nb.c\n");
  expect("echo `{for(f in dir/*.c) echo $f}", "dir/one.c\n");
  expect("x='*.c'; echo $x; for(f in '*.c') echo $f", "*.c\n*.c\n");
  // Scripts: comments, continuations, several lines; . and eval.
  expect("# a comment\necho a \\\n  b\necho c # another", "a b\nc\n");
  CHECK(script("echo 'echo from dot' > s.rc") == RC_OK);
  expect(". s.rc", "from dot\n");
  expect("eval echo evaluated", "evaluated\n");
  // What it refuses, and exit.
  CHECK(script("if(") == RC_INCOMPLETE);
  CHECK(script("for(i in a b) {") == RC_INCOMPLETE);
  CHECK(script("echo )") == RC_SYNTAX && strstr(rc_err(r), "rc:1: ") != nullptr);
  CHECK(script("echo 'unterminated") == RC_INCOMPLETE); // more lines may close it
  CHECK(script("echo a \\\n") == RC_INCOMPLETE);
  expect("echo a\\\nb", "a b\n"); // a \ ending a line is white space, mid-word too
  expect("ifs=() { x=`{echo a b}; echo $#x }", "1\n");
  {
    const char *name = "myscript";
    size_t len = strlen(name);
    rc_set(r, "0", &name, &len, 1);
    expect("echo $0 $#0", "myscript 1\n");
  }
  { // Long scripts and switches: run whole, or refused, never cut short.
    static char text[64 * 1024];
    size_t at = 0;
    for (int i = 0; i < 2000; i++) at += (size_t)snprintf(text + at, sizeof text - at, "x=%d\n", i);
    snprintf(text + at, sizeof text - at, "echo $x\n");
    expect(text, "1999\n");
    at = (size_t)snprintf(text, sizeof text, "switch(c299){\n");
    for (int i = 0; i < 300; i++)
      at += (size_t)snprintf(text + at, sizeof text - at, "case c%d\n echo %d\n", i, i);
    snprintf(text + at, sizeof text - at, "}\n");
    expect(text, "299\n");
  }
  CHECK(script("x=() ; echo a^$x") == RC_FAILED);
  CHECK(script("fn f { echo }; f | wc") == RC_OK && strstr(err, "pipeline") != nullptr);
  CHECK(script("echo before; exit 'it failed'; echo after") == RC_EXIT && strcmp(out, "before\n") == 0);
  expect("echo $status", "it failed\n");
  CHECK(opened > 0 && opened == closed); // every redirection's file let go
  CHECK(script("cat < nosuchfile") == RC_FAILED);
  // Variables as a program would get them: a local hides its global.
  CHECK(script("x=global; y=(a b); fn f { exportx }; x=local f") == RC_OK);
  CHECK(strcmp(exported, "x=local;") == 0);
  CHECK(script("exportx") == RC_OK && strcmp(exported, "x=global;") == 0);
  // The heap gives back what it lent: a long loop runs in it without running out.
  expect("for(i in 1 2 3 4 5 6 7 8 9 10) { x=`{echo $i $i $i}; y=$x^-; z=$y(1) }; echo $z", "10-\n");
  for (int i = 0; i < 200; i++)
    script("x=`{echo a b c d e f g}; y=($x $x $x); fn f { echo $y }; f > /dev/null");
  expect("echo still", "still\n");
  test_9front();
  test_9front_reading();
  test_9front_builtins();
  return check_result();
}
