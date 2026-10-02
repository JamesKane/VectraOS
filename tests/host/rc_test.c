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

static bool run(void *ctx, rc *r, const rc_command *stages, uint32_t n, bool async, uint64_t *pid) {
  (void)ctx;
  static char pipes[2][4096];
  size_t npipe[2] = {};
  const char *status = "";
  for (uint32_t i = 0; i < n; i++) {
    const rc_command *c = &stages[i];
    rc_fd fds[RC_FDS];
    memcpy(fds, c->fds, sizeof fds);
    // Its input: the stage before's output, a file, or nothing.
    const char *in = "";
    size_t nin = 0;
    if (fds[0].kind == RC_FD_PIPE_IN) in = pipes[(i + 1) % 2], nin = npipe[(i + 1) % 2];
    if (fds[0].kind == RC_FD_READ && fds[0].handle < 8)
      in = files[fds[0].handle].data, nin = files[fds[0].handle].len;
    char *mypipe = pipes[i % 2];
    size_t *mynpipe = &npipe[i % 2];
    *mynpipe = 0;
    const char *name = c->argv->s;
    status = "";
    if (!strcmp(name, "echo")) {
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
      status = "false";
    } else if (!strcmp(name, "exitwith")) {
      status = c->argv->next ? c->argv->next->s : "";
    } else {
      status = "not found";
    }
  }
  if (async) *pid = 42;
  rc_set_status(r, status, strlen(status));
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
  opened++;
  return true;
}

static void close_fake(void *ctx, uint32_t handle) {
  (void)ctx, (void)handle;
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

static int64_t read_file_fake(void *ctx, const char *path, size_t len, char *buf, size_t cap) {
  (void)ctx;
  int k = file_of(path, len, false);
  if (k < 0 || files[k].len > cap) return -1;
  memcpy(buf, files[k].data, files[k].len);
  return (int64_t)files[k].len;
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

int main(void) {
  rc_host host = {.run = run,
                  .write = write_fd,
                  .readdir = readdir_fake,
                  .read_file = read_file_fake,
                  .open = open_fake,
                  .close = close_fake};
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
  expect("echo a=b", "a=b\n");
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
  expect("exitwith 3 | true; echo $status", "\n");
  // Functions: $*, $1, dynamic scope, local assignment.
  expect("fn greet { echo hi $1 $#* }; greet bob jo", "hi bob 2\n");
  expect("fn show { echo $x }; x=1; x=2 show; show", "2\n1\n");
  expect("fn f { echo in f }; fn f; f; echo $status", "not found\n");
  // Command substitution, nested in braces and an if.
  expect("x=`{echo a b}; echo $#x", "2\n");
  expect("if(true) { y=`{echo z}; echo $y }", "z\n");
  expect("x=`:{echo a:b:c}; echo $x(2)", "b\n");
  // Redirections and pipes.
  expect("echo data > f; cat < f", "data\n");
  expect("echo more >> f; cat < f", "data\nmore\n");
  expect("{ echo x; echo y } > g; cat < g", "x\ny\n");
  expect("echo one two three | wc", "3\n");
  expect("echo a b | cat | wc", "2\n");
  expect("echo oops >[1=2]; echo fine", "fine\n");
  // Globbing: marks only where written bare; no match keeps the word.
  expect("echo *.c", "a.c b.c\n");
  expect("echo '*.c' z* ?.h", "*.c z* x.h\n");
  expect("echo dir/*.c", "dir/one.c\n");
  expect("x=*.c; echo $#x", "2\n");
  // Scripts: comments, continuations, several lines; . and eval.
  expect("# a comment\necho a \\\n  b\necho c # another", "a b\nc\n");
  CHECK(script("echo 'echo from dot' > s.rc") == RC_OK);
  expect(". s.rc", "from dot\n");
  expect("eval echo evaluated", "evaluated\n");
  // What it refuses, and exit.
  CHECK(script("if(") == RC_INCOMPLETE);
  CHECK(script("for(i in a b) {") == RC_INCOMPLETE);
  CHECK(script("echo )") == RC_SYNTAX && strstr(rc_err(r), "line 1") != nullptr);
  CHECK(script("echo 'unterminated") == RC_SYNTAX);
  CHECK(script("x=() ; echo a^$x") == RC_FAILED);
  CHECK(script("fn f { echo }; f | wc") == RC_OK && strstr(err, "pipeline") != nullptr);
  CHECK(script("echo before; exit 'it failed'; echo after") == RC_EXIT && strcmp(out, "before\n") == 0);
  expect("echo $status", "it failed\n");
  CHECK(opened > 0 && opened == closed); // every redirection's file let go
  CHECK(script("cat < nosuchfile") == RC_FAILED);
  // The heap gives back what it lent: a long loop runs in it without running out.
  expect("for(i in 1 2 3 4 5 6 7 8 9 10) { x=`{echo $i $i $i}; y=$x^-; z=$y(1) }; echo $z", "10-\n");
  for (int i = 0; i < 200; i++)
    script("x=`{echo a b c d e f g}; y=($x $x $x); fn f { echo $y }; f > /dev/null");
  expect("echo still", "still\n");
  return check_result();
}
