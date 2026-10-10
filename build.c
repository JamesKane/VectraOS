// build.c: the VectraOS build tool (docs/04-bootstrap-toolchain.md §3.2).
//
// First time:  cc -std=c23 -o build build.c
// After that:  ./build <command>        (it rebuilds itself when its sources change)
//
// Every first-party component is one translation unit, so there is no dependency
// tracking: each command rebuilds what it names, and the build-time budget keeps
// that fast. Vendored ports are built once and cached by the hash of their inputs.

#define _GNU_SOURCE // nftw with FTW_ACTIONRETVAL
#include <elf.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "lib/vx-ndb/ndb.c"
#include "lib/vx-sha256/sha256.c"
#include "lib/vx-tar/tar.c"
#include "lib/vx-guide/guide.c"

// ADR-0001: the toolchain is pinned to these exact binaries and versions.
// Each pin is one line of the tool's --version output, compared exactly.
static const char CLANG[] = "/usr/bin/clang";
static const char CLANGXX[] = "/usr/bin/clang++"; // the native target's C++ (ADR-0033 §2a)
static const char LLD[] = "/usr/bin/ld.lld";
static const char OBJCOPY[] = "/usr/bin/llvm-objcopy";
static const char NASM[] = "/usr/bin/nasm";
static const char CLANG_FORMAT[] = "/usr/bin/clang-format";
static const char CLANG_TIDY[] = "/usr/bin/clang-tidy";
static const char CLANG_VERSION[] = "clang version 22.1.8 (Fedora 22.1.8-4.fc44)";
static const char LLD_VERSION[] = "LLD 22.1.8 (compatible with GNU linkers)";
static const char OBJCOPY_VERSION[] = "LLVM version 22.1.8";
static const char LLVM_AR[] = "/usr/bin/llvm-ar";
static const char LLVM_AR_VERSION[] = "LLVM version 22.1.8";
static const char CLANG_RESOURCE_INCLUDE[] = "/usr/lib/clang/22/include"; // the pinned clang's own headers
static const char CLANG_FORMAT_VERSION[] = "clang-format version 22.1.8 (Fedora 22.1.8-4.fc44)";
static const char CLANG_TIDY_VERSION[] = "LLVM version 22.1.8";
static const char NASM_VERSION[] = "NASM version 3.02 compiled on Jul 14 2026"; // nasm-3.02-1.fc44

// When any of these changes, ./build rebuilds itself, and cached ports rebuild.
static const char *const BUILD_SOURCES[] = {
    "build.c",
    "abi/vx/ndb.h",
    "lib/vx-ndb/ndb.c",
    "lib/vx-sha256/sha256.c",
    "abi/vx/abi.h",
    "abi/vx/syscalls.def",
    "abi/vx/rights.def",
    "abi/vx/status.def",
    "lib/vx-tar/tar.c",
    "lib/vx-guide/guide.h",
    "lib/vx-guide/guide.c",
    "abi/vx/utf.h",
    nullptr,
};

static constexpr int KERNEL_LOC_BUDGET = 25000; // docs/01 §1

// ---------------------------------------------------------------------------
// Flags

static const char *const HOST_FLAGS[] = {
    "-std=c23", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-Wshadow", "-Wvla", "-Wimplicit-fallthrough",
    nullptr,
};

// The house subset (docs/04 §1.1). Applies to the OS tree, not to applications.
static const char *const HOUSE_FLAGS[] = {
    "-std=c23",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wshadow",
    "-Wvla",
    "-Wimplicit-fallthrough",
    "-fno-strict-aliasing",
    "-ftrivial-auto-var-init=zero",
    "-g",
    "-fno-omit-frame-pointer",
    "-mno-omit-leaf-frame-pointer",
    nullptr,
};

static const char *const KERNEL_FLAGS[] = {
    "-ffreestanding",
    "-nostdlibinc", // clang's own headers, never the host's C library's (6e2b2)
    "-fno-pic",
    "-mgeneral-regs-only",
    "-fno-asynchronous-unwind-tables",
    "-fno-unwind-tables", // frame pointers unwind the kernel
    "-fsanitize=kcfi",
    "-fstack-protector-strong",
    "-mstack-protector-guard=global",
    "-Iabi",
    "-Ikernel",
    "-Ithird_party/limine/limine-protocol/include",
    nullptr,
};

// Debug builds of the OS tree, kernel and user space, trap on undefined
// behaviour, at -O0: what debugging wants, and a quarter of -O1's compile
// time, which keeps a clean kernel build within its 1 s budget (04 §3.2).
static const char *const DEBUG_FLAGS[] = {
    "-O0", "-fsanitize=undefined", "-fno-sanitize=function", "-fsanitize-trap=undefined", nullptr,
};

static const char *const RELEASE_FLAGS[] = {"-O2", nullptr};

// First-party user programs in M1: freestanding, static, non-PIE, against
// lib/vx-rt. No FP/SIMD until the kernel saves that state (M2). No hosted
// header (ADR-0033 §4, M6 step 6e2b2): clang's own, freestanding ones only,
// where x86_64-unknown-none-elf would otherwise find the host's /usr/include.
static const char *const USER_FLAGS[] = {
    "-ffreestanding",
    "-nostdlibinc",
    "-fno-pic",
    "-fstack-protector-strong",
    "-mstack-protector-guard=global",
    nullptr,
};

static const char *const X86_64_FLAGS[] = {
    "--target=x86_64-unknown-none-elf", "-mno-red-zone", "-mcmodel=kernel", "-fcf-protection=full", nullptr,
};

static const char *const AARCH64_FLAGS[] = {
    "--target=aarch64-unknown-none-elf",
    "-mbranch-protection=standard",
    nullptr,
};

// Userland's baseline (M6 step 6c3, decided 2026-10-05): x86-64-v3 (AVX2,
// FMA, BMI2, MOVBE; Haswell and Zen on) and armv8.2-a, which every tiered
// machine has and QEMU's TCG emulates. What is above it, AVX-512 and the
// rest, is chosen at run time (vx_cpu_has). The kernel stays general-
// registers-only, as before.
static const char *const X86_64_USER_FLAGS[] = {
    "--target=x86_64-unknown-none-elf",
    "-march=x86-64-v3",
    "-fcf-protection=full",
    nullptr,
};

static const char *const AARCH64_USER_FLAGS[] = {
    "--target=aarch64-unknown-none-elf",
    "-march=armv8.2-a",
    "-mbranch-protection=standard",
    nullptr,
};

typedef struct arch {
  const char *name;
  const char *const *flags;      // the kernel
  const char *const *user_flags; // user programs
} arch;

static const arch ARCHES[] = {
    {"x86_64", X86_64_FLAGS, X86_64_USER_FLAGS},
    {"aarch64", AARCH64_FLAGS, AARCH64_USER_FLAGS},
};
static constexpr int ARCH_COUNT = sizeof ARCHES / sizeof ARCHES[0];

// ---------------------------------------------------------------------------
// Helpers

[[noreturn]] static void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("build: ", stderr);
  vfprintf(stderr, fmt, ap);
  fputc('\n', stderr);
  va_end(ap);
  exit(1);
}

static bool verbose;
static char root[1024]; // the repository root, absolute

// One arena for the whole run. build is short-lived, so nothing is freed.
// 32 MiB ran out building aarch64's debug test images (with musl, M4); the
// pages are the host's to map as they are touched.
static char arena[512 << 20];
static size_t arena_used;

static void *alloc(size_t n) {
  n = (n + 15) & ~(size_t)15;
  if (sizeof arena - arena_used < n) die("out of arena memory");
  void *p = arena + arena_used;
  arena_used += n;
  return p;
}

static char *fmt(const char *f, ...) {
  va_list ap;
  va_start(ap, f);
  int n = vsnprintf(nullptr, 0, f, ap);
  va_end(ap);
  char *s = alloc((size_t)n + 1);
  va_start(ap, f);
  vsnprintf(s, (size_t)n + 1, f, ap);
  va_end(ap);
  return s;
}

static char *str_dup(vx_str s) {
  char *p = alloc(s.len + 1);
  if (s.len) memcpy(p, s.ptr, s.len);
  p[s.len] = 0;
  return p;
}

static vx_str read_file(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) die("cannot read %s: %s", path, strerror(errno));
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *p = alloc((size_t)n + 1);
  if (n && fread(p, 1, (size_t)n, f) != (size_t)n) die("cannot read %s", path);
  fclose(f);
  p[n] = 0;
  return (vx_str){p, (size_t)n};
}

static void write_file(const char *path, vx_str data) {
  FILE *f = fopen(path, "wb");
  if (!f || fwrite(data.ptr, 1, data.len, f) != data.len || fclose(f) != 0)
    die("cannot write %s: %s", path, strerror(errno));
}

typedef struct cmd {
  const char *argv[1024];
  int argc;
  const char *dir; // run in this directory, if set
  const char *log; // send stdout and stderr here, if set and not verbose
} cmd;

static void cmd_add(cmd *c, const char *arg) {
  if (c->argc == 1023) die("command line too long");
  c->argv[c->argc++] = arg;
  c->argv[c->argc] = nullptr;
}

static void cmd_addv(cmd *c, const char *const *args) {
  for (; *args; args++) cmd_add(c, *args);
}

// Adds each space-separated word of s.
static void cmd_add_words(cmd *c, vx_str s) {
  size_t i = 0;
  while (i < s.len) {
    while (i < s.len && s.ptr[i] == ' ') i++;
    size_t start = i;
    while (i < s.len && s.ptr[i] != ' ') i++;
    if (i > start) cmd_add(c, str_dup((vx_str){s.ptr + start, i - start}));
  }
}

static void cmd_print(const cmd *c) {
  if (c->dir) fprintf(stderr, "(cd %s) ", c->dir);
  for (int i = 0; i < c->argc; i++) fprintf(stderr, "%s%s", i ? " " : "", c->argv[i]);
  fputc('\n', stderr);
}

static pid_t spawn(const cmd *c) {
  if (verbose) cmd_print(c);
  pid_t pid = fork();
  if (pid < 0) die("fork failed");
  if (pid == 0) {
    if (c->dir && chdir(c->dir) != 0) {
      fprintf(stderr, "build: cannot enter %s\n", c->dir);
      _exit(127);
    }
    if (c->log && !verbose) {
      int fd = open(c->log, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
      if (fd < 0 || dup2(fd, 1) < 0 || dup2(fd, 2) < 0) _exit(127);
    }
    execv(c->argv[0], (char *const *)c->argv);
    fprintf(stderr, "build: cannot run %s: %s\n", c->argv[0], strerror(errno));
    _exit(127);
  }
  return pid;
}

static bool wait_ok(pid_t pid) {
  int status;
  while (waitpid(pid, &status, 0) < 0)
    if (errno != EINTR) die("waitpid failed");
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static bool run(const cmd *c) { return wait_ok(spawn(c)); }

// Runs commands with up to one per CPU in flight. Stops starting new ones after a failure.
static bool run_parallel(cmd *const *cmds, int count) {
  long cpus = sysconf(_SC_NPROCESSORS_ONLN);
  int slots = cpus > 0 ? (int)cpus : 1, running = 0, next = 0;
  bool ok = true;
  while (next < count || running > 0) {
    while (ok && next < count && running < slots) {
      spawn(cmds[next++]);
      running++;
    }
    if (running == 0) break;
    int status;
    if (wait(&status) < 0) {
      if (errno == EINTR) continue;
      die("wait failed");
    }
    running--;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) ok = false;
  }
  return ok;
}

static void mkdirs(const char *path) {
  char *buf = fmt("%s", path);
  for (char *p = buf + 1; *p; p++) {
    if (*p != '/') continue;
    *p = 0;
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) die("cannot create %s", buf);
    *p = '/';
  }
  if (mkdir(buf, 0755) != 0 && errno != EEXIST) die("cannot create %s", buf);
}

static void mkdirs_for(const char *file) {
  char *dir = fmt("%s", file);
  char *slash = strrchr(dir, '/');
  if (slash) {
    *slash = 0;
    mkdirs(dir);
  }
}

static bool newer(const struct stat *a, const struct stat *b) {
  if (a->st_mtim.tv_sec != b->st_mtim.tv_sec) return a->st_mtim.tv_sec > b->st_mtim.tv_sec;
  return a->st_mtim.tv_nsec > b->st_mtim.tv_nsec;
}

static bool exists(const char *path) {
  struct stat st;
  return stat(path, &st) == 0;
}

// Runs a command, without a shell, and returns what it writes to standard
// output (fd 1) or error (fd 2), NUL-terminated (at most 64 KiB); the other
// is discarded. Returns nullptr if it could not run or did not exit with
// status 0.
static char *run_capture_fd(const char *const *argv, int fd) {
  int fds[2];
  if (pipe(fds) != 0) die("pipe failed");
  pid_t pid = fork();
  if (pid < 0) die("fork failed");
  if (pid == 0) {
    int null = open("/dev/null", O_WRONLY);
    if (null < 0 || dup2(fds[1], fd) < 0 || dup2(null, 3 - fd) < 0) _exit(127);
    close(fds[0]);
    execv(argv[0], (char *const *)argv);
    _exit(127);
  }
  close(fds[1]);
  size_t cap = 64 << 10, len = 0;
  char *out = alloc(cap + 1);
  for (ssize_t n; len < cap && (n = read(fds[0], out + len, cap - len)) > 0;) len += (size_t)n;
  close(fds[0]);
  out[len] = 0;
  return wait_ok(pid) ? out : nullptr;
}

static char *run_capture(const char *const *argv) { return run_capture_fd(argv, 1); }

// Runs `prog --version` and looks for a line equal to the pin, ignoring leading blanks.
static void check_version(const char *prog, const char *want) {
  char *out = run_capture((const char *const[]){prog, "--version", nullptr});
  bool found = false;
  for (char *line = out; line && *line;) {
    char *nl = strchr(line, '\n');
    if (nl) *nl = 0;
    if (strcmp(line + strspn(line, " \t"), want) == 0) found = true;
    line = nl ? nl + 1 : nullptr;
  }
  if (!found) die("%s does not report \"%s\", the version ADR-0001 pins", prog, want);
}

// FNV-1a. Used only to notice that a port's inputs changed, never for integrity.
static uint64_t hash_bytes(uint64_t h, vx_str s) {
  for (size_t i = 0; i < s.len; i++) h = (h ^ (unsigned char)s.ptr[i]) * 0x100000001b3;
  return h;
}

// ---------------------------------------------------------------------------
// Self-rebuild

static void rebuild_self(char **argv) {
  struct stat bin, top;
  if (stat("build.c", &top) != 0) die("run ./build from the repository root (no build.c here)");
  bool stale = stat("build", &bin) != 0;
  // A source not there (moved, say) makes it stale too: the rebuild, from
  // build.c's own list, says what is missing, if anything is.
  for (const char *const *src = BUILD_SOURCES; *src; src++) {
    struct stat st;
    if (!stale && (stat(*src, &st) != 0 || newer(&st, &bin))) stale = true;
  }
  if (!stale) return;

  fprintf(stderr, "build: sources changed, rebuilding ./build\n");
  cmd c = {};
  cmd_add(&c, CLANG);
  cmd_addv(&c, HOST_FLAGS);
  cmd_add(&c, "-o");
  cmd_add(&c, "build.new");
  cmd_add(&c, "build.c");
  if (!run(&c)) die("rebuild failed; ./build is unchanged");
  if (rename("build.new", "build") != 0) die("cannot replace ./build");
  execv("./build", argv);
  die("cannot re-run ./build");
}

// ---------------------------------------------------------------------------
// Ports: vendored code built from ports/<name>/port.ndb (docs/04 §3.1)

static constexpr int PORT_MAX_TARGETS = 8;
static constexpr int PORT_MAX_FILES = 32;
static constexpr int PORT_MAX_PROGRAMS = 128;

typedef struct port port;

struct port {
  const char *name;
  const char *dir;    // ports/<name>, which also holds the captured config.h
  const char *src;    // third_party/<name>, absolute
  vx_ndb_record head; // the port= record
  vx_ndb_record targets[PORT_MAX_TARGETS];
  int target_count;
  vx_ndb_record files[PORT_MAX_FILES];
  int file_count;
  vx_ndb_record programs[PORT_MAX_PROGRAMS]; // program= records: POSIX programs built from it
  int program_count;
  uint64_t input_hash;
};

static port limine;

static uint64_t hash_tree(uint64_t h, const char *dir); // below, with the file walker

static void port_load(port *p, const char *name) {
  p->name = name;
  p->dir = fmt("ports/%s", name);
  const char *path = fmt("%s/port.ndb", p->dir);
  vx_ndb_reader r = {.src = read_file(path), .scratch = alloc(64 << 10), .scratch_cap = 64 << 10};

  for (;;) {
    vx_ndb_record rec;
    vx_ndb_result res = vx_ndb_next(&r, &rec);
    if (res == VX_NDB_END) break;
    if (res == VX_NDB_ERROR) die("%s:%zu: %s", path, r.error_line, r.error);
    if (vx_ndb_has(&rec, "port")) {
      p->head = rec;
    } else if (vx_ndb_has(&rec, "target")) {
      if (p->target_count == PORT_MAX_TARGETS) die("%s: too many targets", path);
      p->targets[p->target_count++] = rec;
    } else if (vx_ndb_has(&rec, "file")) {
      if (p->file_count == PORT_MAX_FILES) die("%s: too many file records", path);
      p->files[p->file_count++] = rec;
    } else if (vx_ndb_has(&rec, "program")) {
      if (p->program_count == PORT_MAX_PROGRAMS) die("%s: too many program records", path);
      p->programs[p->program_count++] = rec;
    } else {
      die("%s:%zu: a record must start with port=, target=, file= or program=", path, rec.line);
    }
  }
  vx_str src = vx_ndb_get(&p->head, "src");
  if (!src.len) die("%s: the port= record needs src=", path);
  p->src = fmt("%s/%s", root, str_dup(src));

  // The cache key: the port's own files, the vendor record, build itself and the pins.
  uint64_t h = 0xcbf29ce484222325;
  h = hash_bytes(h, read_file(path));
  if (exists(fmt("%s/config.h", p->dir))) h = hash_bytes(h, read_file(fmt("%s/config.h", p->dir)));
  h = hash_bytes(h, read_file("third_party/VENDOR.ndb"));
  for (const char *const *s = BUILD_SOURCES; *s; s++) h = hash_bytes(h, read_file(*s));
  h = hash_bytes(h, (vx_str){CLANG_VERSION, sizeof CLANG_VERSION - 1});
  // And every file of the vendored tree, path and contents, so an edited (or
  // tampered) tree is never built over by what was cached from the old one.
  p->input_hash = hash_tree(h, p->src);
}

// Collects the files under each comma-separated directory whose names end in ext.
typedef struct file_list {
  const char *paths[4096];
  int count;
} file_list;

static file_list *walk_out;
static const char *walk_ext;
static size_t walk_strip; // length of the "<src>/" prefix

static bool ends_with(const char *s, const char *suffix) {
  size_t n = strlen(s), m = strlen(suffix);
  return n >= m && strcmp(s + n - m, suffix) == 0;
}

static int walk_visit(const char *path, const struct stat *st, int type, struct FTW *ftw) {
  (void)st;
  (void)ftw;
  if (type == FTW_F && ends_with(path, walk_ext)) {
    if (walk_out->count == 4096) die("too many source files");
    walk_out->paths[walk_out->count++] = fmt("%s", path + walk_strip);
  }
  return 0;
}

static int by_path(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

// Every file with extension ext under the listed directories, in byte order, as common.mk has it.
static void collect(file_list *out, const port *p, vx_str dirs, const char *ext) {
  int first = out->count;
  walk_out = out;
  walk_ext = ext;
  walk_strip = strlen(p->src) + 1;
  size_t i = 0;
  while (i < dirs.len) {
    size_t start = i;
    while (i < dirs.len && dirs.ptr[i] != ',') i++;
    const char *dir = fmt("%s/%s", p->src, str_dup((vx_str){dirs.ptr + start, i - start}));
    if (nftw(dir, walk_visit, 32, FTW_PHYS) != 0) die("cannot walk %s", dir);
    i++;
  }
  qsort(out->paths + first, (size_t)(out->count - first), sizeof out->paths[0], by_path);
}

// Folds every file under dir (an absolute path under root) into h: its path
// and its contents, in path order.
static uint64_t hash_tree(uint64_t h, const char *dir) {
  static file_list tree;
  tree = (file_list){};
  port top = {.src = root};
  size_t skip = strlen(root) + 1;
  collect(&tree, &top, (vx_str){dir + skip, strlen(dir + skip)}, "");
  for (int i = 0; i < tree.count; i++) {
    h = hash_bytes(h, (vx_str){tree.paths[i], strlen(tree.paths[i])});
    size_t mark = arena_used;
    h = hash_bytes(h, read_file(tree.paths[i]));
    arena_used = mark; // the file's bytes are not needed again: a vendored tree is megabytes
  }
  return h;
}

// Each comma-separated extension in its own sorted group, in the order given.
static void collect_each(file_list *out, const port *p, vx_str dirs, vx_str exts) {
  size_t i = 0;
  while (i < exts.len) {
    size_t start = i;
    while (i < exts.len && exts.ptr[i] != ',') i++;
    collect(out, p, dirs, str_dup((vx_str){exts.ptr + start, i - start}));
    i++;
  }
}

static vx_str port_file_cflags(const port *p, const char *rel) {
  for (int i = 0; i < p->file_count; i++) {
    vx_str f = vx_ndb_get(&p->files[i], "file");
    if (f.len == strlen(rel) && memcmp(f.ptr, rel, f.len) == 0) return vx_ndb_get(&p->files[i], "cflags");
  }
  return (vx_str){};
}

static const char *object_for(const char *objdir, const char *rel) {
  char *o = fmt("%s/%s", objdir, rel);
  char *dot = strrchr(o, '.');
  strcpy(dot, ".o"); // ".o" is never longer than the extension it replaces
  return o;
}

// Writes a symbol map as assembly: for each function in a .text section, in
// address order, `.quad address` and `.asciz "name"`, then `.quad -1`. Limine
// links one into itself for its panic backtraces (what common/gensyms.sh makes
// with objdump, sort, grep, awk and sed), and so does the kernel. With no ELF
// file, the map holds only the terminator: the first of the two links.
static void write_symbol_map(const char *elf_path, const char *out_path, const char *section,
                             const char *symbol) {
  FILE *f = fopen(out_path, "w");
  if (!f) die("cannot write %s", out_path);
  fprintf(f, "%s\n.globl %s\n%s:\n", section, symbol, symbol);
  if (!elf_path) {
    fprintf(f, ".quad 0xffffffffffffffff\n");
    fclose(f);
    return;
  }
  vx_str elf = read_file(elf_path);
  const Elf64_Ehdr *eh = (const Elf64_Ehdr *)elf.ptr;
  if (elf.len < sizeof *eh || memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 ||
      eh->e_ident[EI_CLASS] != ELFCLASS64)
    die("%s is not a 64-bit ELF file", elf_path);
  if (eh->e_shoff + (uint64_t)eh->e_shnum * sizeof(Elf64_Shdr) > elf.len)
    die("%s: bad section table", elf_path);
  const Elf64_Shdr *sh = (const Elf64_Shdr *)(elf.ptr + eh->e_shoff);
  const char *shstr = elf.ptr + sh[eh->e_shstrndx].sh_offset;

  typedef struct sym {
    uint64_t addr;
    const char *name;
  } sym;
  sym *syms = nullptr;
  size_t count = 0;
  for (int i = 0; i < eh->e_shnum; i++) {
    if (sh[i].sh_type != SHT_SYMTAB) continue;
    const Elf64_Sym *st = (const Elf64_Sym *)(elf.ptr + sh[i].sh_offset);
    size_t n = sh[i].sh_size / sizeof *st;
    const char *strs = elf.ptr + sh[sh[i].sh_link].sh_offset;
    syms = alloc(n * sizeof *syms);
    for (size_t k = 0; k < n; k++) {
      if (ELF64_ST_TYPE(st[k].st_info) != STT_FUNC) continue;
      if (st[k].st_shndx == SHN_UNDEF || st[k].st_shndx >= eh->e_shnum) continue;
      if (strncmp(shstr + sh[st[k].st_shndx].sh_name, ".text", 5) != 0) continue;
      syms[count++] = (sym){st[k].st_value, strs + st[k].st_name};
    }
  }
  // By address, then name: the order `sort` gives objdump's lines.
  for (size_t i = 1; i < count; i++)
    for (size_t k = i; k > 0; k--) {
      sym *a = &syms[k - 1], *b = &syms[k];
      if (a->addr < b->addr || (a->addr == b->addr && strcmp(a->name, b->name) <= 0)) break;
      sym t = *a;
      *a = *b;
      *b = t;
    }

  for (size_t i = 0; i < count; i++)
    fprintf(f, ".quad 0x%016llx\n.asciz \"%s\"\n", (unsigned long long)syms[i].addr, syms[i].name);
  fprintf(f, ".quad 0xffffffffffffffff\n");
  fclose(f);
}

static bool build_port_target(const port *p, const vx_ndb_record *t) {
  const char *target = str_dup(vx_ndb_get(t, "target"));
  const char *output = str_dup(vx_ndb_get(t, "output"));
  const char *outdir = fmt("%s/out/%s/%s", root, p->name, target);
  const char *objdir = fmt("%s/obj", outdir);
  const char *result = fmt("%s/%s", outdir, output);
  const char *stamp = fmt("%s/stamp", outdir);
  const char *key = fmt("%016llx\n", (unsigned long long)p->input_hash);

  if (exists(result) && exists(stamp) && strcmp(read_file(stamp).ptr, key) == 0) {
    fprintf(stderr, "  PORT  %s  %s (cached)\n", p->name, target);
    return true;
  }

  vx_str cflags = vx_ndb_get(t, "cflags");
  vx_str cppflags = vx_ndb_get(&p->head, "cppflags");
  vx_str nasm_ext = vx_ndb_get(t, "nasm.ext");
  const char *prefix_map = fmt("-ffile-prefix-map=%s=/src", root);
  const char *config_inc = fmt("-I%s/%s", root, p->dir);

  if (nasm_ext.len) {
    if (!exists(NASM)) die("%s %s needs nasm (ADR-0002): sudo dnf install nasm", p->name, target);
    check_version(NASM, NASM_VERSION);
  }

  file_list *c_files = alloc(sizeof *c_files);
  file_list *s_files = alloc(sizeof *s_files);
  file_list *nasm_files = alloc(sizeof *nasm_files);
  file_list *cpp_files = alloc(sizeof *cpp_files);
  *c_files = *s_files = *nasm_files = *cpp_files = (file_list){};
  collect(c_files, p, vx_ndb_get(t, "c.dirs"), ".c");
  collect(s_files, p, vx_ndb_get(t, "S.dirs"), ".S");
  if (nasm_ext.len) collect_each(nasm_files, p, vx_ndb_get(t, "nasm.dirs"), nasm_ext);
  vx_str cpp_ext = vx_ndb_get(t, "cppasm.ext");
  if (cpp_ext.len) collect_each(cpp_files, p, vx_ndb_get(t, "cppasm.dirs"), cpp_ext);

  // One command per source file, in common.mk's link order.
  int total = c_files->count + s_files->count + nasm_files->count + cpp_files->count;
  cmd **cmds = alloc((size_t)total * sizeof *cmds);
  const char **objs = alloc((size_t)total * sizeof *objs);
  int n = 0;
  const file_list *clang_lists[] = {c_files, s_files};
  for (int l = 0; l < 2; l++)
    for (int i = 0; i < clang_lists[l]->count; i++) {
      const char *rel = clang_lists[l]->paths[i];
      cmd *c = alloc(sizeof *c);
      *c = (cmd){.dir = p->src};
      cmd_add(c, CLANG);
      cmd_add_words(c, cflags);
      cmd_add_words(c, cppflags);
      cmd_add(c, config_inc);
      cmd_add_words(c, port_file_cflags(p, rel));
      cmd_add(c, prefix_map);
      cmd_add(c, "-c");
      cmd_add(c, rel);
      cmd_add(c, "-o");
      cmd_add(c, objs[n] = object_for(objdir, rel));
      cmds[n++] = c;
    }
  for (int i = 0; i < nasm_files->count; i++) {
    const char *rel = nasm_files->paths[i];
    cmd *c = alloc(sizeof *c);
    *c = (cmd){.dir = p->src};
    cmd_add(c, NASM);
    cmd_add(c, rel);
    cmd_add_words(c, vx_ndb_get(t, "nasmflags"));
    cmd_add(c, "-o");
    cmd_add(c, objs[n] = object_for(objdir, rel));
    cmds[n++] = c;
  }
  for (int i = 0; i < cpp_files->count; i++) {
    const char *rel = cpp_files->paths[i];
    cmd *c = alloc(sizeof *c);
    *c = (cmd){.dir = p->src};
    cmd_add(c, CLANG);
    cmd_add_words(c, cflags);
    cmd_add_words(c, cppflags);
    cmd_add(c, config_inc);
    cmd_add(c, prefix_map);
    cmd_add(c, "-x");
    cmd_add(c, "assembler-with-cpp");
    cmd_add(c, "-c");
    cmd_add(c, rel);
    cmd_add(c, "-o");
    cmd_add(c, objs[n] = object_for(objdir, rel));
    cmds[n++] = c;
  }
  for (int i = 0; i < n; i++) mkdirs_for(objs[i]);

  fprintf(stderr, "  PORT  %s  %s (%d files)\n", p->name, target, n);
  if (!run_parallel(cmds, n)) return false;

  // Link twice: once without the symbol map, to learn the addresses, then with it.
  const char *ldscript = fmt("%s/%s", p->src, str_dup(vx_ndb_get(t, "ldscript")));
  const char *map_s = fmt("%s/full.map.S", outdir);
  const char *map_o = fmt("%s/full.map.o", outdir);
  for (int pass = 0; pass < 2; pass++) {
    const char *script = fmt("%s/%s", outdir, pass == 0 ? "linker_nomap.ld" : "linker.ld");
    const char *elf = fmt("%s/%s", outdir, pass == 0 ? "limine_nomap.elf" : "limine.elf");

    cmd pp = {.dir = p->src};
    cmd_add(&pp, CLANG);
    cmd_addv(&pp, (const char *const[]){"-x", "c", "-E", "-P", "-undef", nullptr});
    if (pass == 0) cmd_add(&pp, "-DLINKER_NOMAP");
    cmd_add(&pp, ldscript);
    cmd_add(&pp, "-o");
    cmd_add(&pp, script);
    if (!run(&pp)) return false;

    if (pass == 1) {
      write_symbol_map(fmt("%s/limine_nomap.elf", outdir), map_s, ".section .full_map", "full_map");
      cmd cc = {.dir = p->src};
      cmd_add(&cc, CLANG);
      cmd_add_words(&cc, cflags);
      cmd_add_words(&cc, cppflags);
      cmd_add(&cc, config_inc);
      cmd_add(&cc, "-c");
      cmd_add(&cc, map_s);
      cmd_add(&cc, "-o");
      cmd_add(&cc, map_o);
      if (!run(&cc)) return false;
    }

    cmd ld = {};
    cmd_add(&ld, LLD);
    cmd_add(&ld, fmt("-T%s", script));
    cmd_add_words(&ld, vx_ndb_get(t, "ldflags"));
    for (int i = 0; i < n; i++) cmd_add(&ld, objs[i]);
    if (pass == 1) cmd_add(&ld, map_o);
    cmd_add(&ld, "-o");
    cmd_add(&ld, elf);
    if (!run(&ld)) return false;
  }

  // The loader is the raw image of the PE file the linker script lays out, padded to 4 KiB.
  cmd oc = {};
  cmd_add(&oc, OBJCOPY);
  cmd_addv(&oc, (const char *const[]){"-O", "binary", nullptr});
  cmd_add(&oc, fmt("%s/limine.elf", outdir));
  cmd_add(&oc, result);
  if (!run(&oc)) return false;
  struct stat st;
  if (stat(result, &st) != 0) die("%s was not written", result);
  if (truncate(result, (st.st_size + 4095) & ~(off_t)4095) != 0) die("cannot pad %s", result);

  FILE *f = fopen(stamp, "w");
  if (!f) die("cannot write %s", stamp);
  fputs(key, f);
  fclose(f);
  return true;
}

// The port target for an architecture, or nullptr.
static const vx_ndb_record *port_target_for(const port *p, const arch *a) {
  for (int i = 0; i < p->target_count; i++) {
    vx_str arch_name = vx_ndb_get(&p->targets[i], "arch");
    if (arch_name.len == strlen(a->name) && memcmp(arch_name.ptr, a->name, arch_name.len) == 0)
      return &p->targets[i];
  }
  return nullptr;
}

// ---------------------------------------------------------------------------
// The POSIX personality: musl, compiler-rt's builtins and the vx back end,
// into the vectra-musl sysroot (ADR-0007, ADR-0008)
//
// out/ARCH/MODE/vectra-musl/lib holds what a program against musl links:
// crt1.o, crti.o, crtn.o, libc.a and libclang_rt.builtins.a, and empty libm.a
// and the rest, as musl installs them. Programs compile against the vendored
// headers in place (posix_flags), in the order musl's own build uses, so
// check needs nothing built. musl and the builtins are built once, at -O2,
// and cached (out/musl/ARCH, out/compiler-rt/ARCH); the back end is
// first-party and built with the mode's flags.

static port musl, compiler_rt;

static const char *const MUSL_EMPTY_LIBS[] = {"m",    "rt",     "pthread", "crypt", "util",
                                              "xnet", "resolv", "dl",      nullptr};

// The target and include path of everything compiled for the POSIX
// personality, per architecture.
static const char *const *posix_flags(const arch *a) {
  static const char *flags[ARCH_COUNT][16];
  int i = (int)(a - ARCHES), n = 0;
  if (!flags[i][0]) {
    const char **f = flags[i];
    f[n++] = fmt("--target=%s-vectra-unknown-musl", a->name);
    f[n++] = a->user_flags[1]; // the baseline's -march
    f[n++] = "-nostdinc";
    f[n++] = "-isystem";
    f[n++] = CLANG_RESOURCE_INCLUDE;
    f[n++] = "-isystem";
    f[n++] = fmt("third_party/musl/arch/%s", a->name);
    f[n++] = "-isystem";
    f[n++] = "third_party/musl/arch/generic";
    f[n++] = "-isystem";
    f[n++] = fmt("ports/musl/generated/%s/include", a->name);
    f[n++] = "-isystem";
    f[n++] = "third_party/musl/include";
    f[n] = nullptr;
  }
  return flags[i];
}

// First-party code against musl: the back end (which uses musl's global
// stack guard, as it runs before TLS is set up) and programs.
static const char *const POSIX_BACKEND_FLAGS[] = {
    "-fstack-protector-strong",
    "-mstack-protector-guard=global",
    nullptr,
};
static const char *const POSIX_PROGRAM_FLAGS[] = {"-fstack-protector-strong", nullptr};

static const char *vectra_musl_lib(const arch *a, bool release) {
  return fmt("out/%s/%s/vectra-musl/lib", a->name, release ? "release" : "debug");
}

// The files directly in src/rel (not below it) ending in one of exts, sorted,
// as paths relative to src.
static void list_dir(file_list *out, const char *src, const char *rel, const char *const *exts) {
  DIR *d = opendir(fmt("%s/%s", src, rel));
  if (!d) return;
  int first = out->count;
  for (struct dirent *e; (e = readdir(d));) {
    if (e->d_type != DT_REG) continue;
    for (const char *const *x = exts; *x; x++) {
      if (!ends_with(e->d_name, *x)) continue;
      if (out->count == 4096) die("too many source files in %s", rel);
      out->paths[out->count++] = fmt("%s/%s", rel, e->d_name);
      break;
    }
  }
  closedir(d);
  qsort(out->paths + first, (size_t)(out->count - first), sizeof out->paths[0], by_path);
}

static bool words_has(vx_str words, const char *w) {
  size_t n = strlen(w);
  for (size_t i = 0; i < words.len;) {
    size_t start = i;
    while (i < words.len && words.ptr[i] != ' ') i++;
    if (i - start == n && memcmp(words.ptr + start, w, n) == 0) return true;
    i++;
  }
  return false;
}

// "dir/x86_64/name.s" and "dir/name.c" both as "dir/name": the object they make.
static const char *object_key(const char *rel, const char *arch_dir) {
  char *k = fmt("%s", rel);
  char *a = strstr(k, arch_dir); // "/x86_64/"
  if (a) memmove(a + 1, a + strlen(arch_dir), strlen(a + strlen(arch_dir)) + 1);
  char *dot = strrchr(k, '.');
  if (dot) *dot = 0;
  return k;
}

typedef struct keyed_source {
  const char *path, *key;
} keyed_source;

static int by_key(const void *a, const void *b) {
  return strcmp(((const keyed_source *)a)->key, ((const keyed_source *)b)->key);
}

// A port's sources, generic and per architecture, the architecture's
// replacing the generic ones of the same name, sorted by the object they make.
static void merge_sources(file_list *out, const file_list *generic, const file_list *specific,
                          const char *arch) {
  const char *arch_dir = fmt("/%s/", arch);
  keyed_source *srcs = alloc((size_t)(generic->count + specific->count) * sizeof *srcs);
  int n = 0;
  for (int i = 0; i < specific->count; i++)
    srcs[n++] = (keyed_source){specific->paths[i], object_key(specific->paths[i], arch_dir)};
  int specific_n = n;
  for (int i = 0; i < generic->count; i++) {
    const char *key = object_key(generic->paths[i], arch_dir);
    bool replaced = false;
    for (int k = 0; k < specific_n && !replaced; k++) replaced = strcmp(srcs[k].key, key) == 0;
    if (!replaced) srcs[n++] = (keyed_source){generic->paths[i], key};
  }
  qsort(srcs, (size_t)n, sizeof *srcs, by_key);
  for (int i = 0; i < n; i++) out->paths[out->count++] = srcs[i].path;
}

// Drops the paths `words` lists, keeping the rest in order.
static void drop_listed(file_list *l, vx_str words) {
  int kept = 0;
  for (int k = 0; k < l->count; k++)
    if (!words_has(words, l->paths[k])) l->paths[kept++] = l->paths[k];
  l->count = kept;
}

// musl's source set (port.ndb): src/*/ and src/malloc/mallocng, with each
// directory's ARCH/ files replacing the generic ones, less exclude=.
static void musl_sources(file_list *out, const arch *a, vx_str exclude) {
  static file_list generic, specific, dirs;
  generic = specific = dirs = (file_list){};
  DIR *d = opendir(fmt("%s/src", musl.src));
  if (!d) die("cannot read %s/src", musl.src);
  for (struct dirent *e; (e = readdir(d));)
    if (e->d_type == DT_DIR && e->d_name[0] != '.') dirs.paths[dirs.count++] = fmt("src/%s", e->d_name);
  closedir(d);
  qsort(dirs.paths, (size_t)dirs.count, sizeof dirs.paths[0], by_path);
  dirs.paths[dirs.count++] = "src/malloc/mallocng";
  static const char *const C[] = {".c", nullptr}, *const ARCH_EXTS[] = {".c", ".s", ".S", nullptr};
  for (int i = 0; i < dirs.count; i++) {
    list_dir(&generic, musl.src, dirs.paths[i], C);
    list_dir(&specific, musl.src, fmt("%s/%s", dirs.paths[i], a->name), ARCH_EXTS);
  }
  drop_listed(&generic, exclude);
  drop_listed(&specific, exclude);
  merge_sources(out, &generic, &specific, a->name);
}

// The names in each set(NAME ...) of CMakeLists.txt that `lists` names.
static void cmake_lists(file_list *out, vx_str text, vx_str lists) {
  for (size_t i = 0; i < lists.len;) {
    size_t start = i;
    while (i < lists.len && lists.ptr[i] != ' ') i++;
    const char *head = fmt("set(%s\n", str_dup((vx_str){lists.ptr + start, i - start}));
    i++;
    const char *at = strstr(text.ptr, head);
    if (!at) die("compiler-rt: no %s in CMakeLists.txt", head);
    at += strlen(head);
    for (;;) {
      at += strspn(at, " \t");
      const char *end = at + strcspn(at, "\n");
      if (*at == ')') break;
      if (*at && *at != '#' && *at != '$')
        out->paths[out->count++] = str_dup((vx_str){at, (size_t)(end - at)});
      if (!*end) die("compiler-rt: %s does not end", head);
      at = end + 1;
    }
  }
}

static void add_words(file_list *out, vx_str words) {
  for (size_t i = 0; i < words.len;) {
    size_t start = i;
    while (i < words.len && words.ptr[i] != ' ') i++;
    if (i > start) out->paths[out->count++] = str_dup((vx_str){words.ptr + start, i - start});
    i++;
  }
}

static void compiler_rt_sources(file_list *out, const arch *a) {
  static file_list generic, specific;
  generic = specific = (file_list){};
  const vx_ndb_record *t = port_target_for(&compiler_rt, a);
  vx_str text = read_file(fmt("%s/CMakeLists.txt", compiler_rt.src));
  cmake_lists(&generic, text, vx_ndb_get(&compiler_rt.head, "cmake.lists"));
  add_words(&generic, vx_ndb_get(&compiler_rt.head, "extra"));
  cmake_lists(&generic, text, vx_ndb_get(t, "cmake.lists"));
  for (int i = 0; i < generic.count; i++) { // the architecture's own, like cpu_model/x86.c, are not generic
    const char *g = generic.paths[i];
    if (strchr(g, '/')) specific.paths[specific.count++] = g;
  }
  int kept = 0;
  for (int i = 0; i < generic.count; i++)
    if (!strchr(generic.paths[i], '/')) generic.paths[kept++] = generic.paths[i];
  generic.count = kept;
  add_words(&specific, vx_ndb_get(t, "extra"));
  // filter_builtin_sources: an architecture's file replaces the generic one by its base name.
  static file_list merged;
  merged = (file_list){};
  for (int i = 0; i < specific.count; i++) merged.paths[merged.count++] = specific.paths[i];
  for (int i = 0; i < generic.count; i++) {
    const char *base = generic.paths[i];
    size_t blen = strcspn(base, ".");
    bool replaced = false;
    for (int k = 0; k < specific.count && !replaced; k++) {
      const char *sb = strrchr(specific.paths[k], '/') + 1;
      replaced = strcspn(sb, ".") == blen && strncmp(sb, base, blen) == 0;
    }
    if (!replaced) merged.paths[merged.count++] = base;
  }
  qsort(merged.paths, (size_t)merged.count, sizeof merged.paths[0], by_path);
  for (int i = 0; i < merged.count; i++) out->paths[out->count++] = merged.paths[i];
}

// Compiles each source (relative to src) into objdir, a batch at a time.
// extra(rel) gives a file's own flags, if any.
static bool compile_port_sources(const port *p, const arch *a, const file_list *files, const char *objdir,
                                 const char **objs, vx_str (*extra)(const char *rel)) {
  static constexpr int BATCH = 256;
  static cmd batch[BATCH];
  cmd *ptrs[BATCH];
  const char *prefix_map = fmt("-ffile-prefix-map=%s=/src", root);
  for (int start = 0; start < files->count; start += BATCH) {
    int n = 0;
    for (int i = start; i < files->count && n < BATCH; i++, n++) {
      const char *rel = files->paths[i];
      cmd *c = &batch[n];
      *c = (cmd){.dir = root};
      cmd_add(c, CLANG);
      if (p == &musl) { // musl's own headers only, in its Makefile's order (CFLAGS_ALL)
        cmd_add(c, posix_flags(a)[0]);
        cmd_add(c, posix_flags(a)[1]); // the baseline
        cmd_add_words(c, vx_ndb_get(&p->head, "cflags"));
        cmd_add(c, "-Iports/musl/vx/arch/generic");
        cmd_add(c, fmt("-I%s/arch/%s", musl.src, a->name));
        cmd_add(c, fmt("-I%s/arch/generic", musl.src));
        cmd_add(c, "-Iports/musl/generated/internal");
        cmd_add(c, fmt("-I%s/src/include", musl.src));
        cmd_add(c, fmt("-I%s/src/internal", musl.src));
        cmd_add(c, fmt("-Iports/musl/generated/%s/include", a->name));
        cmd_add(c, fmt("-I%s/include", musl.src));
      } else if (words_has(vx_ndb_get(&p->head, "native"), "yes")) { // freestanding, as native programs are
        cmd_addv(c, a->user_flags);
        cmd_addv(c, USER_FLAGS);
        cmd_add_words(c, vx_ndb_get(&p->head, "cflags"));
      } else {
        cmd_addv(c, posix_flags(a));
        cmd_add_words(c, vx_ndb_get(&p->head, "cflags"));
      }
      if (extra) cmd_add_words(c, extra(rel));
      cmd_add(c, prefix_map);
      cmd_add(c, "-c");
      cmd_add(c, strncmp(rel, "ports/", 6) == 0 ? rel : fmt("%s/%s", p->src, rel)); // ports/: generated
      cmd_add(c, "-o");
      cmd_add(c, objs[i] = object_for(objdir, rel));
      mkdirs_for(objs[i]);
      ptrs[n] = c;
    }
    if (!run_parallel(ptrs, n)) return false;
  }
  return true;
}

// libc.so's objects (6f1b2) are musl's again, position-independent and
// SHARED, as its Makefile compiles them (LOBJS, LDSO_OBJS), the dynamic
// linker's without the stack protector (its NOSSP).
static bool musl_pic;

static vx_str musl_file_flags(const char *rel) {
  const char *base = strrchr(rel, '/') + 1;
  size_t n = strcspn(base, ".");
  vx_str nossp = vx_ndb_get(&musl.head, "nossp");
  bool ldso = strstr(rel, "ldso/") != nullptr;
  bool no_ssp = ldso || words_has(nossp, str_dup((vx_str){base, n}));
  static const char *const flags[2][2] = {{"", "-fno-stack-protector"},
                                          {"-fPIC -DSHARED", "-fPIC -DSHARED -fno-stack-protector"}};
  const char *f = flags[musl_pic][no_ssp];
  return (vx_str){f, strlen(f)};
}

// musl's dynlink.c with the one line VectraOS's start needs (ports/musl/vx/
// ldso.c): __dls2b first calls __vx_dls2b_hook, which starts the back end
// and gives it the program's stack. Written as a generated source, as the
// vendored tree is not changed; a musl whose __dls2b differs stops the build.
static const char *musl_dynlink(void) {
  const char *out = "ports/musl/generated/ldso/dynlink.c";
  vx_str in = read_file(fmt("%s/ldso/dynlink.c", musl.src));
  const char *at = "void __dls2b(size_t *sp, size_t *auxv)\n{\n";
  const char *hit = strstr(in.ptr, at);
  if (!hit || strstr(hit + 1, at))
    die("%s/ldso/dynlink.c: no one __dls2b to start the back end in", musl.src);
  size_t head = (size_t)(hit - in.ptr) + strlen(at);
  const char *text =
      fmt("/* Generated by ./build from %s/ldso/dynlink.c (M6 step 6f1b2): */\n"
          "/* __dls2b calls __vx_dls2b_hook first (ports/musl/vx/ldso.c). */\n"
          "%.*shidden void __vx_dls2b_hook(size_t **, size_t **);\n%.*s"
          "\t__vx_dls2b_hook(&sp, &auxv); /* VectraOS */\n%s",
          musl.src, (int)(hit - in.ptr), in.ptr, (int)(head - (size_t)(hit - in.ptr)), hit, in.ptr + head);
  if (!exists(out) || strcmp(read_file(out).ptr, text) != 0) {
    mkdirs_for(out);
    write_file(out, (vx_str){text, strlen(text)});
  }
  return out;
}

// llvm-ar, with the members in a response file in objdir: libc.a has more
// than a command line holds.
static bool archive(const char *lib, const char *objdir, const char *const *objs, int count) {
  remove(lib);
  const char *list = fmt("%s/%s.members", objdir, strrchr(lib, '/') + 1);
  FILE *f = fopen(list, "w");
  if (!f) die("cannot write %s", list);
  for (int i = 0; i < count; i++) fprintf(f, "%s\n", objs[i]);
  fclose(f);
  cmd c = {};
  cmd_addv(&c, (const char *const[]){LLVM_AR, "rcsD", lib, fmt("@%s", list), nullptr});
  return run(&c);
}

// Builds a cached port's objects for one architecture: once per change of
// its inputs, as build_port_target does for Limine.
static bool build_cached_as(const port *p, const arch *a, file_list *files, const char **objs,
                            vx_str (*extra)(const char *rel), const char *variant) {
  const char *outdir = variant ? fmt("%s/out/%s/%s-%s", root, p->name, a->name, variant)
                               : fmt("%s/out/%s/%s", root, p->name, a->name);
  const char *stamp = fmt("%s/stamp", outdir);
  const char *key = fmt("%016llx\n", (unsigned long long)p->input_hash);
  if (exists(stamp) && strcmp(read_file(stamp).ptr, key) == 0) {
    for (int i = 0; i < files->count; i++) objs[i] = object_for(fmt("%s/obj", outdir), files->paths[i]);
    fprintf(stderr, "  PORT  %-7s %s (cached)\n", p->name, a->name);
    return true;
  }
  remove(stamp);
  fprintf(stderr, "  PORT  %-7s %s (%d files)\n", p->name, a->name, files->count);
  if (!compile_port_sources(p, a, files, fmt("%s/obj", outdir), objs, extra)) return false;
  write_file(stamp, (vx_str){key, strlen(key)});
  return true;
}

static bool build_cached(const port *p, const arch *a, file_list *files, const char **objs,
                         vx_str (*extra)(const char *rel)) {
  return build_cached_as(p, a, files, objs, extra, nullptr);
}

// libc.so (M6 step 6f1b2; decided 2026-10-07: musl's own dynamic linker):
// musl's objects again, position-independent (out/musl/ARCH-pic), with its
// dynamic linker (ldso/dlstart.c, and dynlink.c as musl_dynlink makes it);
// the back end with VectraOS's start for it (ports/musl/vx/ldso.c); linked as
// musl links libc.so, entered at _vx_dlstart. It is the interpreter of a
// dynamic POSIX program, /lib/ld-musl-ARCH.so.1. And dcrt1.o, musl's own
// crt1, which a dynamic program starts in once libc.so has loaded it.
static vx_str pic_flag(const char *rel) {
  (void)rel;
  return (vx_str){"-fPIC", 5};
}

static bool build_musl_shared(const arch *a, bool release, const file_list *musl_files, file_list *rt_files) {
  const char *lib = vectra_musl_lib(a, release);
  const char *objdir = fmt("out/%s/%s/musl-vx", a->name, release ? "release" : "debug");
  static file_list pic;
  pic = *musl_files;
  pic.paths[pic.count++] = "ldso/dlstart.c";
  pic.paths[pic.count++] = musl_dynlink();
  int rt_count = rt_files->count;
  const char **pic_objs = alloc((size_t)(pic.count + 2 + rt_count) * sizeof *pic_objs);
  const char **rt_objs = alloc((size_t)rt_count * sizeof *rt_objs);
  musl_pic = true;
  bool ok = build_cached_as(&musl, a, &pic, pic_objs, musl_file_flags, "pic") &&
            build_cached_as(&compiler_rt, a, rt_files, rt_objs, pic_flag, "pic");
  musl_pic = false;
  if (!ok) return false;

  cmd be = {};
  cmd_add(&be, CLANG);
  cmd_addv(&be, posix_flags(a));
  cmd_addv(&be, HOUSE_FLAGS);
  cmd_addv(&be, POSIX_BACKEND_FLAGS);
  cmd_addv(&be, release ? RELEASE_FLAGS : DEBUG_FLAGS);
  cmd_addv(&be, (const char *const[]){"-fPIC", "-DSHARED", nullptr});
  cmd_add(&be, fmt("-ffile-prefix-map=%s=/src", root));
  const char *be_obj = fmt("%s/backend.pic.o", objdir);
  cmd_addv(&be, (const char *const[]){"-c", "ports/musl/vx/backend.c", "-o", be_obj, nullptr});
  static file_list crt;
  crt = (file_list){.count = 1};
  crt.paths[0] = "crt/crt1.c";
  const char *crt_obj[1];
  if (!run(&be) || !compile_port_sources(&musl, a, &crt, fmt("%s/dcrt", objdir), crt_obj, nullptr))
    return false;
  write_file(fmt("%s/dcrt1.o", lib), read_file(crt_obj[0]));

  pic_objs[pic.count] = be_obj;
  int n = pic.count + 1;
  for (int i = 0; i < rt_count; i++) pic_objs[n++] = rt_objs[i]; // musl links libgcc; compiler-rt's builtins
  const char *list = fmt("%s/libc.so.members", objdir);
  FILE *f = fopen(list, "w");
  if (!f) die("cannot write %s", list);
  for (int i = 0; i < n; i++) fprintf(f, "%s\n", pic_objs[i]);
  fclose(f);
  cmd so = {};
  cmd_addv(&so, (const char *const[]){LLD, "-shared", "-soname", "libc.so", "-nostdlib", "-e", "_vx_dlstart",
                                      "--build-id=sha1", "-z", "max-page-size=0x1000", "-z", "noexecstack",
                                      "--hash-style=both", nullptr});
  cmd_add(&so, fmt("--dynamic-list=%s/dynamic.list", musl.src));
  cmd_addv(&so, (const char *const[]){"-o", fmt("%s/libc.so", lib), fmt("@%s", list), nullptr});
  return run(&so);
}

static bool build_vectra_musl(const arch *a, bool release) {
  const char *lib = vectra_musl_lib(a, release);
  const char *objdir = fmt("out/%s/%s/musl-vx", a->name, release ? "release" : "debug");
  mkdirs(lib);
  mkdirs(objdir);

  static file_list musl_files, rt_files;
  musl_files = rt_files = (file_list){};
  musl_sources(&musl_files, a, vx_ndb_get(port_target_for(&musl, a), "exclude"));
  compiler_rt_sources(&rt_files, a);
  const char **musl_objs = alloc((size_t)(musl_files.count + 1) * sizeof *musl_objs);
  const char **rt_objs = alloc((size_t)rt_files.count * sizeof *rt_objs);
  if (!build_cached(&musl, a, &musl_files, musl_objs, musl_file_flags) ||
      !build_cached(&compiler_rt, a, &rt_files, rt_objs, nullptr))
    return false;

  // The back end and crt1, with this mode's flags; crti and crtn, musl's.
  static cmd cc[4];
  const char *srcs[4] = {"ports/musl/vx/backend.c", "ports/musl/vx/crt1.c",
                         fmt("third_party/musl/crt/%s/crti.s", a->name),
                         fmt("third_party/musl/crt/%s/crtn.s", a->name)};
  const char *outs[4] = {fmt("%s/backend.o", objdir), fmt("%s/crt1.o", lib), fmt("%s/crti.o", lib),
                         fmt("%s/crtn.o", lib)};
  cmd *ccs[4];
  fprintf(stderr, "  CC    libc    %s (the vx back end)\n", a->name);
  for (int i = 0; i < 4; i++) {
    cc[i] = (cmd){};
    cmd_add(&cc[i], CLANG);
    cmd_add(&cc[i], posix_flags(a)[0]); // the target: crti.s and crtn.s are assembly
    if (i < 2) {
      cmd_addv(&cc[i], posix_flags(a) + 1);
      cmd_addv(&cc[i], HOUSE_FLAGS);
      cmd_addv(&cc[i], POSIX_BACKEND_FLAGS);
      cmd_addv(&cc[i], release ? RELEASE_FLAGS : DEBUG_FLAGS);
    }
    cmd_add(&cc[i], fmt("-ffile-prefix-map=%s=/src", root));
    cmd_addv(&cc[i], (const char *const[]){"-c", srcs[i], "-o", outs[i], nullptr});
    ccs[i] = &cc[i];
  }
  if (!run_parallel(ccs, 4)) return false;

  musl_objs[musl_files.count] = outs[0];
  if (!archive(fmt("%s/libc.a", lib), objdir, musl_objs, musl_files.count + 1) ||
      !archive(fmt("%s/libclang_rt.builtins.a", lib), objdir, rt_objs, rt_files.count))
    return false;
  for (const char *const *e = MUSL_EMPTY_LIBS; *e; e++)
    if (!archive(fmt("%s/lib%s.a", lib, *e), objdir, nullptr, 0)) return false;
  return build_musl_shared(a, release, &musl_files, &rt_files);
}

// ---------------------------------------------------------------------------
// The kernel

static bool build_kernel(const arch *a, bool release) {
  const char *dir = fmt("out/%s/%s", a->name, release ? "release" : "debug");
  mkdirs(dir);

  // kernel.c, the unity root, plus each assembly file under kernel/arch/<arch>/.
  static file_list asm_files;
  asm_files = (file_list){};
  port arch_dir = {.src = fmt("%s/kernel/arch", root)};
  collect(&asm_files, &arch_dir, (vx_str){a->name, strlen(a->name)}, ".S");

  const char *objs[64];
  int n = 0;
  cmd *cmds[64];
  const char *sources[64] = {"kernel/kernel.c"};
  if (asm_files.count > 63) die("more than 63 assembly files in kernel/arch/%s", a->name);
  for (int i = 0; i < asm_files.count; i++) sources[i + 1] = fmt("kernel/arch/%s", asm_files.paths[i]);
  int source_count = 1 + asm_files.count;
  for (int i = 0; i < source_count; i++) {
    const char *base = strrchr(sources[i], '/') + 1;
    objs[n] = fmt("%s/%.*s.o", dir, (int)(strrchr(base, '.') - base), base);
    cmd *c = alloc(sizeof *c);
    *c = (cmd){};
    cmd_add(c, CLANG);
    cmd_addv(c, a->flags);
    cmd_addv(c, HOUSE_FLAGS);
    cmd_addv(c, KERNEL_FLAGS);
    cmd_addv(c, release ? RELEASE_FLAGS : DEBUG_FLAGS);
    cmd_add(c, fmt("-ffile-prefix-map=%s=/src", root)); // docs/05 §4
    cmd_add(c, "-c");
    cmd_add(c, sources[i]);
    cmd_add(c, "-o");
    cmd_add(c, objs[n]);
    cmds[n++] = c;
  }
  fprintf(stderr, "  CC    kernel  %s (%d files)\n", a->name, n);
  if (!run_parallel(cmds, n)) return false;

  // Link twice: first with an empty symbol map, then with the real one. The map
  // goes at the end of .rodata, after all code, so no function moves.
  fprintf(stderr, "  LD    kernel  %s\n", a->name);
  for (int pass = 0; pass < 2; pass++) {
    const char *map_s = fmt("%s/symbols%d.S", dir, pass);
    const char *map_o = fmt("%s/symbols%d.o", dir, pass);
    const char *elf = fmt("%s/%s", dir, pass == 0 ? "kernel_nomap.elf" : "kernel.elf");
    write_symbol_map(pass == 0 ? nullptr : fmt("%s/kernel_nomap.elf", dir), map_s,
                     ".section .vx_symbols,\"a\"", "vx_symbols");
    cmd as = {};
    cmd_add(&as, CLANG);
    cmd_addv(&as, a->flags);
    cmd_addv(&as, (const char *const[]){"-c", nullptr});
    cmd_add(&as, map_s);
    cmd_add(&as, "-o");
    cmd_add(&as, map_o);
    if (!run(&as)) return false;

    cmd ld = {};
    cmd_add(&ld, LLD);
    cmd_addv(&ld, (const char *const[]){"-static", "-nostdlib", "--build-id=sha1", "-z",
                                        "max-page-size=0x1000", "-z", "noexecstack", "-T", nullptr});
    cmd_add(&ld, fmt("kernel/linker/%s.ld", a->name));
    cmd_add(&ld, "-o");
    cmd_add(&ld, elf);
    for (int i = 0; i < n; i++) cmd_add(&ld, objs[i]);
    cmd_add(&ld, map_o);
    if (!run(&ld)) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// all, image, qemu, test

// The user programs in the boot image, each one translation unit (04 §1.1).
// Where a program goes: a Limine module, which the kernel can start as the root
// task; boot/bin in bootfs, where svcd finds it; or boot/bin only in the test
// images whose scenario names it with `with=`, together with its manifest if
// it has one (one without is run by another test).
typedef enum placement : uint8_t { IN_MODULE, IN_BOOTFS, IN_TESTS } placement;

typedef struct program {
  const char *name, *source;
  placement where;
  const char *arch;             // the only architecture it is built for, or nullptr for every one
  bool posix;                   // against vectra-musl, rather than freestanding against vx-rt
  const port *lib;              // a native port it links (its archive), or nullptr
  const char *const *lib_flags; // what compiling against that port's headers takes
  bool native;                  // ISO C against the native target's sysroot (ADR-0033, 6e2b)
  // How it links (ADR-0047): a static program; the dynamic loader, at its
  // fixed address; a shared library (-fPIC, initial-exec TLS); or a dynamic
  // program, whose interpreter is /lib/ld-vx. The loader and libraries go in
  // bootfs's lib/, which a namespace with the boot image as root has at /lib.
  enum : uint8_t { LINK_STATIC, LINK_LOADER, LINK_SHARED, LINK_DYNAMIC } link;
  const char *const *needs; // a shared library's or dynamic program's libraries, by their names here
} program;

static const char *const DLTEST_A_NEEDS[] = {"libdltestb.so", nullptr};
static const char *const DLTEST_NEEDS[] = {"libdltesta.so", nullptr};
static const char *const VXCXXEXC_NEEDS[] = {"libvxcxxexc.so", nullptr};
static const char *const VXCXXEXC_STATIC[] = {"-DVXCXXEXC_STATIC", nullptr};
static const char *const PIXELSDYN_NEEDS[] = {"libvxui.so", nullptr};
// imagetest's images (ADR-0056): one source, plain, with TLS, and needing an image.
static const char *const IMAGE_TLS[] = {"-DIMAGE_TLS", nullptr};
static const char *const IMAGE_NEEDS_FLAGS[] = {"-DIMAGE_NEEDS", nullptr};
static const char *const IMAGE_NEEDS[] = {"libimage.so", nullptr};
// The hot-reload test's (7g2b): its host and its two images, on libvxui.so.
static const char *const RELOAD_NEEDS[] = {"libvxui.so", nullptr};
static const char *const RELOAD_B[] = {"-Ilib/vxui", "-DRELOAD_B", nullptr};
static const char *const REPLAY_B[] = {"-Ilib/vxui", "-DREPLAY_B", nullptr}; // looped playback's (7g2c)
// An SDK app's flags for vxui.h (ADR-0056): its header alone, libvxui.so answering it.
static const char *const VXUI_APP_FLAGS[] = {"-Ilib/vxui", nullptr};
// libvxui.so's: vxui with the font port's headers as system ones.
// Hidden but for what VXUI_API exports.
static const char *const VXUI_LIB_FLAGS[] = {
    "-Ilib/vxui",          "-isystem", "third_party/stb_truetype", "-isystem", "third_party/kb_text_shape",
    "-fvisibility=hidden", nullptr};

// ACPICA, a native port (ADR-0030), and what bus-acpi needs to include its
// headers: its environment header first, its include directories as system
// ones, so the house warnings stay the house's.
static port acpica, monocypher, font;
// vxui (lib/vxui, 7e2): a program writes #include <vxui.h>.
static const char *const VXUI_FLAGS[] = {
    "-Ilib/vxui", "-isystem", "third_party/stb_truetype", "-isystem", "third_party/kb_text_shape",
    nullptr}; // and the font port
// The font port (ports/font: stb_truetype and kb_text_shape, ADR-0052 and
// 0053), for winsrv and what draws text: their headers as system ones.
static const char *const FONT_USE_FLAGS[] = {"-isystem", "third_party/stb_truetype", "-isystem",
                                             "third_party/kb_text_shape", nullptr};
// Monocypher (ADR-0032), for distd and install: its headers as system ones.
static const char *const MONOCYPHER_USE_FLAGS[] = {"-isystem", "third_party/monocypher/src", "-isystem",
                                                   "third_party/monocypher/src/optional", nullptr};
static const char *const ACPICA_USE_FLAGS[] = {"-include", "ports/acpica/acvectra.h",
                                               "-isystem", "third_party/acpica/source/include",
                                               "-isystem", "third_party/acpica/source/include/platform",
                                               nullptr};

static const program USER_PROGRAMS[] = {
    {"svcd", "servers/svcd/svcd.c", IN_MODULE, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"ktest", "tests/kernel/ktest.c", IN_MODULE, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // the root task instead of svcd with vx.root=ktest
    {"bootfs", "servers/bootfs/bootfs.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"bus-acpi", "servers/bus-acpi/bus-acpi.c", IN_BOOTFS, nullptr, false, &acpica, ACPICA_USE_FLAGS, false,
     LINK_STATIC, nullptr},
    {"nstest", "tests/user/nstest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"dreftest", "tests/user/dreftest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"threadtest", "tests/user/threadtest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"p9pipetest", "tests/user/p9pipetest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"wstattest", "tests/user/wstattest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"srvtest", "tests/user/srvtest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"relaytest", "tests/user/relaytest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"pooltestd", "tests/user/pooltestd.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"pooltest", "tests/user/pooltest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"fsdconc", "tests/user/fsdconc.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"fsdfix", "tests/user/fsdfix.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"constest", "tests/user/constest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"nettest", "tests/user/nettest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"tcptest", "tests/user/tcptest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"proctest", "tests/user/proctest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"plugintest", "tests/user/plugintest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"notifytest", "tests/user/notifytest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"starttest", "tests/user/starttest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"tracetest", "tests/user/tracetest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // the kernel's trace, /proc/trace (7a1b)
    {"benchtest", "tests/user/benchtest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // ./build bench's measurements (7a5)
    {"flighttest", "tests/user/tracetest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // tracetest's flight recorder test, as a program of its own (7a4a)
    {"textgen", "tests/user/textgen.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // the terminal's throughput (7f1)
    {"uitest", "tests/user/uitest.c", IN_TESTS, nullptr, false, &font, VXUI_FLAGS, false, LINK_STATIC,
     nullptr}, // vxui's immediate-mode UI (7e2b)
    {"minimal", "tests/user/minimal.c", IN_TESTS, nullptr, false, &font, VXUI_FLAGS, false, LINK_STATIC,
     nullptr}, // 03's minimal program, M7's exit (7e2)
    {"pixels", "tests/user/pixels.c", IN_TESTS, nullptr, false, &font, VXUI_FLAGS, false, LINK_STATIC,
     nullptr}, // 03's CPU pixel program, M7's exit (7e2)
    {"frametest", "tests/user/frametest.c", IN_TESTS, nullptr, false, &font, VXUI_FLAGS, false, LINK_STATIC,
     nullptr}, // frames in the trace (7g1b1)
    {"tlgen", "tests/user/tlgen.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // a trace for dbg's timeline (7g1b2)
    {"dbguidemo", "tests/user/dbgdemo.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // dbgdemo, as dbg's window debugs it (7g1b3)
    {"libvxui.so", "lib/vxui/libvxui.c", IN_BOOTFS, nullptr, false, &font, VXUI_LIB_FLAGS, true, LINK_SHARED,
     nullptr}, // vxui as the SDK's shared object (ADR-0056, 7g2a)
    {"libimage.so", "tests/user/imagetest_lib.c", IN_TESTS, nullptr, false, nullptr, nullptr, true,
     LINK_SHARED, nullptr}, // imagetest's code image (7g2a)
    {"libimagetls.so", "tests/user/imagetest_lib.c", IN_TESTS, nullptr, false, nullptr, IMAGE_TLS, true,
     LINK_SHARED, nullptr}, // one with TLS, refused
    {"libimageneeds.so", "tests/user/imagetest_lib.c", IN_TESTS, nullptr, false, nullptr, IMAGE_NEEDS_FLAGS,
     true, LINK_SHARED, IMAGE_NEEDS}, // one needing an image, refused
    {"imagetest", "tests/user/imagetest.c", IN_TESTS, nullptr, false, nullptr, nullptr, true, LINK_DYNAMIC,
     nullptr}, // libvx level 2's calls (7g2a)
    {"libreloada.so", "tests/user/reload_app.c", IN_TESTS, nullptr, false, nullptr, VXUI_APP_FLAGS, true,
     LINK_SHARED, RELOAD_NEEDS}, // hot reload's image A (7g2b)
    {"libreloadb.so", "tests/user/reload_app.c", IN_TESTS, nullptr, false, nullptr, RELOAD_B, true,
     LINK_SHARED, RELOAD_NEEDS}, // and B
    {"reloadhost", "tests/user/reloadhost.c", IN_TESTS, nullptr, false, nullptr, VXUI_APP_FLAGS, true,
     LINK_DYNAMIC, RELOAD_NEEDS}, // the host
    {"libreplaya.so", "tests/user/replay_app.c", IN_TESTS, nullptr, false, nullptr, VXUI_APP_FLAGS, true,
     LINK_SHARED, RELOAD_NEEDS}, // looped playback's image A (7g2c)
    {"libreplayb.so", "tests/user/replay_app.c", IN_TESTS, nullptr, false, nullptr, REPLAY_B, true,
     LINK_SHARED, RELOAD_NEEDS}, // and B
    {"pixelsdyn", "tests/user/pixelsdyn.c", IN_TESTS, nullptr, false, nullptr, VXUI_APP_FLAGS, true,
     LINK_DYNAMIC, PIXELSDYN_NEEDS}, // 03's pixels as an SDK app on libvxui.so (7g2a)
    {"prompttest", "tests/user/prompttest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // the trusted prompt (7d2d)
    {"wmtest", "tests/user/wmtest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // windows under wm (7d2c)
    {"textest", "tests/user/textest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // text: keymaps, compose, repeat, the IME (7d2b)
    {"decortest", "tests/user/decortest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // winsrv's decorations (7d2a)
    {"routetest", "tests/user/routetest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // input routed to windows (7d1c)
    {"wintest", "tests/user/wintest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // windows and the frame protocol (7d1b)
    {"disptest", "tests/user/disptest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // the display engine protocol (7b3)
    {"buftest", "tests/user/buftest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // vx-buffer between processes (7b2)
    {"fbtest", "tests/user/fbtest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // the boot framebuffer, write-combining (7b1c)
    {"pmutest", "tests/user/pmutest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // a task's hardware counters (7a3b1)
    {"libvxtest", "tests/user/libvxtest.c", IN_TESTS, nullptr, false, nullptr, nullptr, true, LINK_DYNAMIC,
     nullptr}, // native since 6e4e: the behaviour suite, with vxapitest
    {"vxapitest", "tests/user/vxapitest.c", IN_TESTS, nullptr, false, nullptr, nullptr, true, LINK_DYNAMIC,
     nullptr}, // libvx v0's public API, <vx.h> (6e4b)
    {"vxctest", "tests/user/vxctest.c", IN_TESTS, nullptr, false, nullptr, nullptr, true, LINK_DYNAMIC,
     nullptr},
    {"vxcxxtest", "tests/user/vxcxxtest.cpp", IN_TESTS, nullptr, false, nullptr, nullptr, true, LINK_DYNAMIC,
     nullptr},
    {"procfs", "servers/procfs/procfs.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"nsd", "servers/nsd/nsd.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"tmpfs", "servers/tmpfs/tmpfs.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"nullfs", "servers/nullfs/nullfs.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"srvfs", "servers/srvfs/srvfs.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"envd", "servers/envd/envd.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"relay", "servers/relay/relay.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"sysfs", "servers/sysfs/sysfs.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"ptyd", "servers/ptyd/ptyd.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"plumber", "servers/plumber/plumber.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // 7g3b
    {"devmgr", "servers/devmgr/devmgr.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"netd", "servers/netd/netd.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"rc", "cmd/rc.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"poweroff", "cmd/poweroff.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"install", "cmd/install.c", IN_BOOTFS, nullptr, false, &monocypher, MONOCYPHER_USE_FLAGS, false,
     LINK_STATIC, nullptr},
    {"ls", "cmd/ls.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"term", "cmd/term.c", IN_BOOTFS, nullptr, false, &font, VXUI_FLAGS, false, LINK_STATIC,
     nullptr}, // the terminal (7f1)
    {"cat", "cmd/cat.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"srv", "cmd/srv.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"echo", "cmd/echo.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"pwd", "cmd/pwd.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"ps", "cmd/ps.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"trace", "cmd/trace.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"ns", "cmd/ns.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"tail", "cmd/tail.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"plumb", "cmd/plumb.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // 7g3b
    {"ping", "cmd/ping.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"cs", "cmd/cs.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"dbg", "cmd/dbg.c", IN_BOOTFS, nullptr, false, &font, VXUI_FLAGS, false, LINK_STATIC,
     nullptr}, // its timeline a vxui window (7g1b2)
    {"man", "cmd/man.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"lookman", "cmd/lookman.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"sig", "cmd/sig.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"drv-uart-16550", "drivers/drv-uart-16550/uart.c", IN_BOOTFS, "x86_64", false, nullptr, nullptr, false,
     LINK_STATIC, nullptr},
    {"drv-rtc-cmos", "drivers/drv-rtc-cmos/rtc.c", IN_BOOTFS, "x86_64", false, nullptr, nullptr, false,
     LINK_STATIC, nullptr},
    {"drv-uart-pl011", "drivers/drv-uart-pl011/uart.c", IN_BOOTFS, "aarch64", false, nullptr, nullptr, false,
     LINK_STATIC, nullptr},
    {"drv-virtio-net", "drivers/drv-virtio-net/net.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false,
     LINK_STATIC, nullptr},
    {"winsrv", "servers/winsrv/winsrv.c", IN_BOOTFS, nullptr, false, &font, FONT_USE_FLAGS, false,
     LINK_STATIC, nullptr}, // the window server (7d1), drawing text (7e1)
    {"displayd", "servers/displayd/displayd.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false,
     LINK_STATIC, nullptr}, // the display coordinator (7b3)
    {"drv-virtio-input", "drivers/drv-virtio-input/input.c", IN_BOOTFS, nullptr, false, nullptr, nullptr,
     false, LINK_STATIC, nullptr}, // keyboards, tablets, mice (7c1)
    {"inputd", "servers/inputd/inputd.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // the input devices, gathered (7c1)
    {"drv-virtio-gpu", "drivers/drv-virtio-gpu/gpu.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false,
     LINK_STATIC, nullptr}, // virtio-gpu 2D, a display back end (7b4)
    {"drv-simplefb", "drivers/drv-simplefb/simplefb.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false,
     LINK_STATIC, nullptr}, // the firmware's framebuffer, a display back end (7b3)
    {"drv-virtio-blk", "drivers/drv-virtio-blk/blk.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false,
     LINK_STATIC, nullptr},
    {"drv-nvme", "drivers/drv-nvme/nvme.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"blktest", "tests/user/blktest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"partd", "servers/partd/partd.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"fsd", "servers/fsd/fsd.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"dosfs", "servers/dosfs/dosfs.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"isofs", "servers/isofs/isofs.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"distd", "servers/distd/distd.c", IN_BOOTFS, nullptr, false, &monocypher, MONOCYPHER_USE_FLAGS, false,
     LINK_STATIC, nullptr},
    {"ctest", "tests/posix/ctest.c", IN_TESTS, nullptr, true, nullptr, nullptr, false, LINK_STATIC, nullptr},
    {"ctestfsd", "tests/posix/ctest.c", IN_TESTS, nullptr, true, nullptr, nullptr, false, LINK_STATIC,
     nullptr}, // ctest again, with /tmp on fsd
    {"sbasetest", "tests/posix/sbasetest.c", IN_TESTS, nullptr, true, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"maptest", "tests/posix/maptest.c", IN_TESTS, nullptr, true, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"powercut", "tests/posix/powercut.c", IN_TESTS, nullptr, true, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"dbgdemo", "tests/user/dbgdemo.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"dbgthreads", "tests/user/dbgthreads.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"schedtest", "tests/user/schedtest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"cdtest", "tests/user/cdtest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_STATIC,
     nullptr},
    {"ld-vx", "cmd/ld-vx.c", IN_BOOTFS, nullptr, false, nullptr, nullptr, false, LINK_LOADER, nullptr},
    // Shared libraries before what links them: build_user_programs links them first.
    {"libdltestb.so", "tests/user/dltest_b.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_SHARED,
     nullptr},
    {"libdltesta.so", "tests/user/dltest_a.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_SHARED,
     DLTEST_A_NEEDS},
    {"dltest", "tests/user/dltest.c", IN_TESTS, nullptr, false, nullptr, nullptr, false, LINK_DYNAMIC,
     DLTEST_NEEDS},
    // C++ exceptions (6f2a): a native C++ library, and the program that links it.
    {"libvxcxxexc.so", "tests/user/vxcxxexc_lib.cpp", IN_TESTS, nullptr, false, nullptr, nullptr, true,
     LINK_SHARED, nullptr},
    {"vxcxxexc", "tests/user/vxcxxexc.cpp", IN_TESTS, nullptr, false, nullptr, nullptr, true, LINK_DYNAMIC,
     VXCXXEXC_NEEDS},
    // and statically, the library's code its own: the unwind tables found
    // through the program's headers, not the loader's list.
    {"vxcxxexcs", "tests/user/vxcxxexc.cpp", IN_TESTS, nullptr, false, nullptr, VXCXXEXC_STATIC, true,
     LINK_STATIC, nullptr},
};

// Where a program goes in bootfs: boot/bin, or lib/ for the loader and
// shared libraries (ADR-0047).
static const char *bootfs_path(const program *p) {
  return p->link == LINK_LOADER || p->link == LINK_SHARED ? fmt("lib/%s", p->name)
                                                          : fmt("boot/bin/%s", p->name);
}

static bool program_for(const program *p, const arch *a) { return !p->arch || strcmp(p->arch, a->name) == 0; }

// Test programs built outside this tree, in swift-on-vectra's, until
// ADR-0034's first gate brings the Swift toolchain here (M6 step 6e3): a
// scenario that names one in `with=` takes it from that tree's
// tests/out/TRIPLE/NAME, which its tests/build.sh makes.
static const char *const EXTERNAL_PROGRAMS[] = {"swifta", "swiftb", "swiftfnd", "swiftcompat"};
// And the libraries they are tested against, in lib/ when a scenario names
// them: Compat's version 2, which swiftcompat, built against version 1,
// runs against (6f3e, ADR-0048).
static const char *const EXTERNAL_LIBRARIES[][2] = {{"libCompat.so", "compat-v2/libCompat.so"}};
static constexpr int EXTERNAL_PROGRAM_COUNT = sizeof EXTERNAL_PROGRAMS / sizeof EXTERNAL_PROGRAMS[0];
// The Swift runtime's shared libraries, and FoundationEssentials's, which
// the system ships in /lib (6f3a, ADR-0048).
static const char *const SWIFT_LIBRARIES[] = {"libswiftCore.so",
                                              "libswift_Concurrency.so",
                                              "libswiftSynchronization.so",
                                              "libswift_StringProcessing.so",
                                              "libswift_RegexParser.so",
                                              "libswiftRegexBuilder.so",
                                              "libswiftObservation.so",
                                              "libswiftSwiftOnoneSupport.so",
                                              "libswiftVectraOSLibc.so",
                                              "libFoundationEssentials.so"};

static bool external_program(const char *name) { // or library
  for (int i = 0; i < EXTERNAL_PROGRAM_COUNT; i++)
    if (strcmp(EXTERNAL_PROGRAMS[i], name) == 0) return true;
  for (size_t i = 0; i < sizeof EXTERNAL_LIBRARIES / sizeof EXTERNAL_LIBRARIES[0]; i++)
    if (strcmp(EXTERNAL_LIBRARIES[i][0], name) == 0) return true;
  return false;
}

// swift-on-vectra's tree: $VECTRA_SWIFT_ON_VECTRA, or beside this one.
static const char *swift_on_vectra(void) {
  const char *from = getenv("VECTRA_SWIFT_ON_VECTRA");
  return from ? from : fmt("%s/../../lang/swift-on-vectra", root);
}
static constexpr int USER_PROGRAM_COUNT = sizeof USER_PROGRAMS / sizeof USER_PROGRAMS[0];

// Every user program for an architecture: compiled in parallel, then linked
// in parallel. Each is its own unity build, so nothing is shared between them.
// A native port's archive, for an architecture (build_native_ports makes it).
static const char *native_port_archive(const port *p, const arch *a) {
  return fmt("%s/out/%s/%s/lib%s.a", root, p->name, a->name, p->name);
}

// The same, position-independent, for a shared library to link.
static const char *native_port_pic_archive(const port *p, const arch *a) {
  return fmt("%s/out/%s/%s-pic/lib%s.a", root, p->name, a->name, p->name);
}

// Native ports (ACPICA, Monocypher): compiled once per architecture and
// cached, as musl is, into an archive the programs that use them link.
static bool build_native_ports(const arch *a) {
  port *const ports[] = {&acpica, &monocypher, &font};
  for (size_t i = 0; i < sizeof ports / sizeof *ports; i++) {
    static file_list files;
    files = (file_list){};
    add_words(&files, vx_ndb_get(&ports[i]->head, "sources"));
    const char **objs = alloc((size_t)files.count * sizeof *objs);
    if (!build_cached(ports[i], a, &files, objs, nullptr)) return false;
    const char *lib = native_port_archive(ports[i], a);
    if (!archive(lib, fmt("%s/out/%s/%s", root, ports[i]->name, a->name), objs, files.count)) return false;
  }
  // The font port again, position-independent, for libvxui.so (ADR-0056).
  static file_list files;
  files = (file_list){};
  add_words(&files, vx_ndb_get(&font.head, "sources"));
  const char **objs = alloc((size_t)files.count * sizeof *objs);
  return build_cached_as(&font, a, &files, objs, pic_flag, "pic") &&
         archive(native_port_pic_archive(&font, a), fmt("%s/out/%s/%s-pic", root, font.name, a->name), objs,
                 files.count);
}

// Usage from pages (12 §7, M6 step 6a3): a program whose page has a usage
// fence is compiled with -include out/gen/usage/NAME.h, which defines
// VX_USAGE from the fence, so the message and the page cannot differ.
// Several synopsis lines are one message, each after the first under the
// first's command, as Plan 9's are. nullptr: no page, or a page without one.
// A program's page: its own file, or a page that names it (man(1) names man,
// lookman and sig).
static const char *usage_page(const program *p) {
  static const int sects[] = {1, 8, 4, 3};
  for (size_t k = 0; k < sizeof sects / sizeof sects[0]; k++) {
    const char *path = fmt("man/%d/%s", sects[k], p->name);
    if (exists(path)) return path;
  }
  vx_str want = {p->name, strlen(p->name)};
  for (size_t k = 0; k < sizeof sects / sizeof sects[0]; k++) {
    DIR *d = opendir(fmt("man/%d", sects[k]));
    for (struct dirent *e; d && (e = readdir(d));) {
      if (e->d_name[0] == '.') continue;
      const char *path = fmt("man/%d/%s", sects[k], e->d_name);
      static vx_guide g;
      if (!vx_guide_open(&g, read_file(path))) continue;
      vx_str names = g.h.names, name;
      while (vx_guide_item_next(&names, &name))
        if (name.len == want.len && memcmp(name.ptr, want.ptr, want.len) == 0) {
          closedir(d);
          return path;
        }
    }
    if (d) closedir(d);
  }
  return nullptr;
}

// usage_flags's other words: for each first word of the fence's lines that is
// not the program's name and is a C name, [[maybe_unused]] VX_USAGE_word, its
// lines joined as VX_USAGE's are.
static char *realloc_words(char *c, size_t *n, vx_str fence, const char *name) {
  // Each line is in one word's declaration, escaped (at most twice its bytes)
  // and joined ("\\n" and seven spaces); each word costs its declaration's
  // some 70 bytes and its name: so 3 bytes a fence byte and 96 a line, with
  // room over (the Odin port's finding: a fence of short words overran 6x).
  size_t lines = 1;
  for (size_t i = 0; i < fence.len; i++) lines += fence.ptr[i] == '\n';
  char *out = alloc(*n + fence.len * 3 + lines * 96 + 256);
  memcpy(out, c, *n);
  size_t nlen = strlen(name), m = *n;
  for (size_t at = 0; at < fence.len;) { // each line whose word has not been done
    size_t end = at, w = at;
    while (end < fence.len && fence.ptr[end] != '\n') end++;
    while (w < end && fence.ptr[w] != ' ') w++;
    bool cname = w > at && !(fence.ptr[at] >= '0' && fence.ptr[at] <= '9');
    for (size_t q = at; q < w && cname; q++) {
      char ch = fence.ptr[q];
      cname = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_';
    }
    bool done = false;
    for (size_t prev = 0; prev < at && cname && !done;) { // an earlier line of the same word: done then
      size_t pe = prev, pw = prev;
      while (pe < fence.len && fence.ptr[pe] != '\n') pe++;
      while (pw < pe && fence.ptr[pw] != ' ') pw++;
      done = pw - prev == w - at && memcmp(fence.ptr + prev, fence.ptr + at, w - at) == 0;
      prev = pe + 1;
    }
    if (cname && !done && !(w - at == nlen && memcmp(fence.ptr + at, name, nlen) == 0)) {
      m += (size_t)sprintf(out + m,
                           "[[maybe_unused]] static const char VX_USAGE_%.*s[] = \"usage: ", (int)(w - at),
                           fence.ptr + at);
      bool first = true;
      for (size_t l = at; l < fence.len;) {
        size_t le = l, lw = l;
        while (le < fence.len && fence.ptr[le] != '\n') le++;
        while (lw < le && fence.ptr[lw] != ' ') lw++;
        if (lw - l == w - at && memcmp(fence.ptr + l, fence.ptr + at, w - at) == 0) {
          if (!first) m += (size_t)sprintf(out + m, "\\n       ");
          first = false;
          for (size_t q = l; q < le; q++) {
            if (fence.ptr[q] == '"' || fence.ptr[q] == '\\') out[m++] = '\\';
            out[m++] = fence.ptr[q];
          }
        }
        l = le + 1;
      }
      m += (size_t)sprintf(out + m, "\";\n");
    }
    at = end + 1;
  }
  *n = m;
  return out;
}

static const char *const *usage_flags(const program *p) {
  static const char *const *made[USER_PROGRAM_COUNT];
  static bool done[USER_PROGRAM_COUNT];
  int i = (int)(p - USER_PROGRAMS);
  if (done[i]) return made[i];
  done[i] = true;
  const char *path = usage_page(p);
  if (!path) return nullptr;
  static vx_guide g;
  vx_str page = read_file(path);
  if (!vx_guide_open(&g, page)) return nullptr; // the manual's check says why
  vx_guide_block b;
  vx_guide_kind k;
  while ((k = vx_guide_next(&g, &b)) > VX_GUIDE_END &&
         !(k == VX_GUIDE_FENCE && b.fence.len == 5 && !memcmp(b.fence.ptr, "usage", 5)));
  if (k != VX_GUIDE_FENCE) return nullptr;
  char *c = alloc(b.text.len * 4 + 256);
  size_t nlen = strlen(p->name), lines = 0;
  size_t n = (size_t)sprintf(c,
                             "// Made by ./build from %s's usage fence (docs/12 §7). Not to be "
                             "edited.\n#pragma once\nstatic const char VX_USAGE[] = \"usage: ",
                             path);
  for (size_t at = 0; at < b.text.len;) { // the lines that start with the program's name
    size_t end = at;
    while (end < b.text.len && b.text.ptr[end] != '\n') end++;
    bool mine = end - at >= nlen && memcmp(b.text.ptr + at, p->name, nlen) == 0 &&
                (end - at == nlen || b.text.ptr[at + nlen] == ' ');
    if (mine && lines++) n += (size_t)sprintf(c + n, "\\n       ");
    for (size_t q = at; mine && q < end; q++) {
      if (b.text.ptr[q] == '"' || b.text.ptr[q] == '\\') c[n++] = '\\';
      c[n++] = b.text.ptr[q];
    }
    at = end + 1;
  }
  if (!lines) return nullptr; // the fence has no line for it: the check says so
  n += (size_t)sprintf(c + n, "\";\n");
  // Lines for other words (rc(1)'s builtins: bind, mount, unmount): each word
  // its own VX_USAGE_word, for the program that has those as builtins.
  c = realloc_words(c, &n, b.text, p->name);
  const char *h = fmt("out/gen/usage/%s.h", p->name);
  mkdirs("out/gen/usage");
  vx_str old = exists(h) ? read_file(h) : (vx_str){};
  bool same = old.ptr && old.len == n && memcmp(old.ptr, c, n) == 0;
  if (!same) write_file(h, (vx_str){c, n}); // rewritten only when changed
  const char **f = alloc(3 * sizeof *f);
  f[0] = "-include", f[1] = h, f[2] = nullptr;
  return made[i] = f;
}

// --- The native target's sysroot (ADR-0033, M6 step 6e2b) ---
//
// out/ARCH/MODE/vectraos/: llvm-libc's headers and libc.a and libm.a, taken
// from swift-on-vectra's build at the tree recorded in
// lib/vx-rt/sysroot/llvm-libc.ndb; vx-rt's start file crt1.o (start.c alone)
// and libvx.a (libvx.c: vx-rt, vx-ns and the C library's hooks);
// compiler-rt's builtins, vectra-musl's; the ABI's headers as <vx/...>; and
// at its root the configuration file Fedora's clang compiles with and the
// response files ld.lld links with. A machine without the C library builds
// without the sysroot, and without the programs that need it.

static void copy_tree(const char *from, const char *to);
static void copy_file(const char *from, const char *to);
static void probe_sysroot(const arch *a, const char *s, const char *bin, bool cxx);
static bool tree_sha256(const char *dir, char out[65]);

// --- libvx's ABI levels (ADR-0004 items 5 and 8, M6 step 6e4e) ---

static int strcmp_ptrs(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

// A shared object's exports: its defined global and weak dynamic symbols at
// default visibility, sorted, one to a line.
static vx_str elf_exports(const char *path) {
  vx_str f = read_file(path);
  const Elf64_Ehdr *eh = (const Elf64_Ehdr *)f.ptr;
  if (f.len < sizeof *eh || memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 ||
      eh->e_ident[EI_CLASS] != ELFCLASS64 || eh->e_shoff > f.len ||
      eh->e_shnum > (f.len - eh->e_shoff) / sizeof(Elf64_Shdr))
    die("%s: not an ELF64 shared object", path);
  const Elf64_Shdr *sh = (const Elf64_Shdr *)(f.ptr + eh->e_shoff);
  static const char *names[16384];
  size_t n = 0, bytes = 0;
  for (int i = 0; i < eh->e_shnum; i++) {
    if (sh[i].sh_type != SHT_DYNSYM || sh[i].sh_link >= eh->e_shnum) continue;
    const Elf64_Shdr *str = &sh[sh[i].sh_link];
    if (sh[i].sh_offset > f.len || sh[i].sh_size > f.len - sh[i].sh_offset || str->sh_offset > f.len ||
        str->sh_size > f.len - str->sh_offset)
      die("%s: its symbol table runs past its end", path);
    const Elf64_Sym *sym = (const Elf64_Sym *)(f.ptr + sh[i].sh_offset);
    for (size_t k = 1; k < sh[i].sh_size / sizeof *sym; k++) {
      uint8_t bind = ELF64_ST_BIND(sym[k].st_info);
      if ((bind != STB_GLOBAL && bind != STB_WEAK) || sym[k].st_shndx == SHN_UNDEF ||
          ELF64_ST_VISIBILITY(sym[k].st_other) != STV_DEFAULT || sym[k].st_name >= str->sh_size)
        continue;
      if (n == sizeof names / sizeof names[0]) die("%s: more exports than build.c holds", path);
      names[n] = f.ptr + str->sh_offset + sym[k].st_name;
      bytes += strlen(names[n++]) + 1;
    }
  }
  qsort(names, n, sizeof names[0], strcmp_ptrs);
  char *out = alloc(bytes + 1), *at = out;
  for (size_t i = 0; i < n; i++) at += sprintf(at, "%s\n", names[i]);
  return (vx_str){out, (size_t)(at - out)};
}

// The level abi.h names (VX_ABI_LEVEL): 0, the draft, until the first freeze.
static int abi_level(void) {
  vx_str h = read_file("abi/vx/abi.h");
  const char *d = strstr(h.ptr, "#define VX_ABI_LEVEL ");
  if (!d) die("abi/vx/abi.h has no VX_ABI_LEVEL");
  char *end;
  long n = strtol(d + strlen("#define VX_ABI_LEVEL "), &end, 10);
  if (end == d + strlen("#define VX_ABI_LEVEL ") || n < 0 || n > 1000)
    die("abi/vx/abi.h: VX_ABI_LEVEL is no level");
  return (int)n;
}

// Whether every line of want is a line of have (both sorted lists).
static bool lines_within(vx_str want, vx_str have, const char **missing) {
  for (size_t at = 0; at < want.len;) {
    size_t e = at;
    while (e < want.len && want.ptr[e] != '\n') e++;
    vx_str line = {want.ptr + at, e - at};
    bool found = false;
    for (size_t h = 0; h < have.len && !found;) {
      size_t f = h;
      while (f < have.len && have.ptr[f] != '\n') f++;
      found = f - h == line.len && memcmp(have.ptr + h, line.ptr, line.len) == 0;
      h = f + 1;
    }
    if (!found && line.len) {
      *missing = str_dup(line);
      return false;
    }
    at = e + 1;
  }
  return true;
}

// libvx.so's exports, written beside it (usr/lib/libvx.symbols) and, once a
// level is frozen (abi/levels/N.symbols, sorted), held to it: a symbol it
// lacks breaks every program built for the level, and a new one belongs to
// the next level, with VX_TARGET_ABI around its declaration. A draft level
// (no list of its own yet, ADR-0056) holds every symbol of the level below.
static bool check_libvx_exports(const arch *a, const char *lib) {
  vx_str now = elf_exports(fmt("%s/libvx.so", lib));
  write_file(fmt("%s/libvx.symbols", lib), now);
  const char *frozen = fmt("abi/levels/%d.symbols", abi_level());
  if (!exists(frozen)) { // the draft: a superset of the level below
    const char *below = fmt("abi/levels/%d.symbols", abi_level() - 1), *missing = "";
    if (!exists(below) || lines_within(read_file(below), now, &missing)) return true;
    fprintf(stderr, "  ABI   %s: libvx.so lacks %s, which %s has\n", a->name, missing, below);
    return false;
  }
  vx_str want = read_file(frozen);
  if (want.len == now.len && memcmp(want.ptr, now.ptr, now.len) == 0) return true;
  fprintf(stderr, "  ABI   %s: libvx.so's exports are not %s's (%s/libvx.symbols holds them):\n", a->name,
          frozen, lib);
  cmd d = {};
  cmd_addv(&d, (const char *const[]){"/usr/bin/diff", "-u", frozen, fmt("%s/libvx.symbols", lib), nullptr});
  run(&d);
  return false;
}

// The behaviour suite (ADR-0004 item 8): native programs against libvx.so,
// and the manifests and scenarios that say what they expect, each from the
// level that added it. A level's hash is over the path and bytes of each file
// of it and the levels below, in this order.
static const struct {
  int level;
  const char *path;
} BEHAVIOUR_SUITE[] = {
    {1, "tests/user/vxapitest.c"},
    {1, "tests/user/vxapitest.ndb"},
    {1, "tests/qemu/vxapi.ndb"},
    {1, "tests/user/libvxtest.c"},
    {1, "tests/user/libvxtest.ndb"},
    {1, "tests/qemu/libvx.ndb"},
    {2, "tests/user/imagetest.c"}, // code images (ADR-0056)
    {2, "tests/user/imagetest.h"},
    {2, "tests/user/imagetest_lib.c"},
    {2, "tests/user/imagetest.ndb"},
    {2, "tests/qemu/image.ndb"},
    {},
};

static void hex(char *out, const uint8_t *p, size_t n); // below

static void behaviour_hash(int level, char out[65]) {
  vx_sha256 h = vx_sha256_begin();
  for (size_t i = 0; BEHAVIOUR_SUITE[i].path; i++) {
    if (BEHAVIOUR_SUITE[i].level > level) continue;
    const char *f = BEHAVIOUR_SUITE[i].path;
    vx_str data = read_file(f);
    vx_sha256_add(&h, f, strlen(f) + 1);
    vx_sha256_add(&h, data.ptr, data.len);
  }
  uint8_t digest[32];
  vx_sha256_end(&h, digest);
  hex(out, digest, 32);
}

// Whether the suite may ship as it is: unchanged from the frozen level's
// (abi/levels/N.behaviour), or its change named in docs/release-notes.md
// ("behaviour-suite: HASH" and why), since a changed expectation changes what
// programs built for the level may rely on. A draft level (ADR-0056) holds
// the level below's part of the suite to that level's hash; *level and hash
// say which was compared.
static bool behaviour_allowed(int *level, char hash[65]) {
  *level = abi_level();
  const char *frozen = fmt("abi/levels/%d.behaviour", *level);
  if (!exists(frozen)) frozen = fmt("abi/levels/%d.behaviour", --*level);
  if (!exists(frozen)) return true; // nothing frozen
  behaviour_hash(*level, hash);
  vx_str want = read_file(frozen);
  if (want.len >= 64 && memcmp(want.ptr, hash, 64) == 0) return true;
  vx_str notes = exists("docs/release-notes.md") ? read_file("docs/release-notes.md") : (vx_str){"", 0};
  const char *line = fmt("behaviour-suite: %s", hash);
  return memmem(notes.ptr, notes.len, line, strlen(line)) != nullptr;
}

static const char *sysroot_dir(const arch *a, bool release) {
  return fmt("out/%s/%s/vectraos", a->name, release ? "release" : "debug");
}

static const char *sysroot_triple(const arch *a) { return fmt("%s-unknown-vectraos", a->name); }

// The tree hash recorded for triple, or "" if none is.
static const char *sysroot_recorded(const char *triple, const char *key) {
  vx_str rec = read_file("lib/vx-rt/sysroot/llvm-libc.ndb");
  const char *at = strstr(rec.ptr, fmt("triple=%s ", triple));
  const char *next = at ? strstr(at + 7, "triple=") : nullptr; // this triple's record only
  const char *hash = at ? strstr(at, fmt("%s=", key)) : nullptr;
  if (hash && next && hash > next) hash = nullptr;
  return hash ? fmt("%.64s", hash + strlen(key) + 1) : "";
}

// libc++ and libc++abi from build_cxx.sh's runtime sysroot into s, at the
// recorded tree (6e2d2): whether there were any.
static bool sysroot_cxx(const arch *a, const char *s, const char *from) {
  const char *triple = sysroot_triple(a), *cxx = fmt("%s/toolchain/out/sysroot/%s", from, triple);
  if (!exists(fmt("%s/usr/lib/libc++.a", cxx))) {
    fprintf(stderr, "  SYSROOT %s: no C++, no libc++ in %s\n", a->name, cxx);
    return false;
  }
  char tree[65];
  const char *want = sysroot_recorded(triple, "cxx.sha256");
  if (!tree_sha256(cxx, tree) || strcmp(tree, want) != 0)
    die("%s: tree %s, but lib/vx-rt/sysroot/llvm-libc.ndb records cxx.sha256=%s: record the build to take it",
        cxx, tree, *want ? want : "none");
  copy_tree(fmt("%s/usr/include/c++", cxx), fmt("%s/usr/include/c++", s));
  copy_file(fmt("%s/usr/lib/libc++.a", cxx), fmt("%s/usr/lib/libc++.a", s));
  copy_file(fmt("%s/usr/lib/libc++abi.a", cxx), fmt("%s/usr/lib/libc++abi.a", s));
  // Shared (6f1c2, decided 2026-10-08): linked under their plain names, loaded
  // from /lib under their sonames, libc++.so.1 and libc++abi.so.1.
  copy_file(fmt("%s/usr/lib/libc++.so.1.0", cxx), fmt("%s/usr/lib/libc++.so", s));
  copy_file(fmt("%s/usr/lib/libc++abi.so.1.0", cxx), fmt("%s/usr/lib/libc++abi.so", s));
  // LLVM's libunwind, for C++ exceptions (6f2a), likewise.
  copy_file(fmt("%s/usr/lib/libunwind.a", cxx), fmt("%s/usr/lib/libunwind.a", s));
  copy_file(fmt("%s/usr/lib/libunwind.so.1.0", cxx), fmt("%s/usr/lib/libunwind.so", s));
  static const char *const UNWIND_HEADERS[] = {"unwind.h", "unwind_itanium.h", "unwind_arm_ehabi.h",
                                               "libunwind.h", "__libunwind_config.h"};
  for (size_t i = 0; i < sizeof UNWIND_HEADERS / sizeof UNWIND_HEADERS[0]; i++) // <unwind.h> and its parts
    copy_file(fmt("%s/usr/include/%s", cxx, UNWIND_HEADERS[i]),
              fmt("%s/usr/include/%s", s, UNWIND_HEADERS[i]));
  copy_file("lib/vx-rt/sysroot/vectraos-clang++.cfg", fmt("%s/%s-clang++.cfg", s, triple));
  copy_file("lib/vx-rt/sysroot/link-tail-c++.rsp", fmt("%s/link-tail-c++.rsp", s));
  return true;
}

// Whether the sysroot was made: false, with a note, when there is no C
// library to take; a C library other than the recorded one stops the build.
static bool build_sysroot(const arch *a, bool release) {
  const char *s = sysroot_dir(a, release), *triple = sysroot_triple(a);
  const char *from = swift_on_vectra();
  const char *libc = fmt("%s/toolchain/out/libc/%s", from, triple);
  if (!exists(fmt("%s/lib/%s/libc.a", libc, triple))) {
    fprintf(stderr, "  SYSROOT %s skipped: no llvm-libc in %s\n", a->name, libc);
    return false;
  }
  char tree[65];
  const char *want = sysroot_recorded(triple, "tree.sha256");
  if (!tree_sha256(libc, tree) || strcmp(tree, want) != 0)
    die("%s: tree %s, but lib/vx-rt/sysroot/llvm-libc.ndb records %s: record the build to take it", libc,
        tree, *want ? want : "none");
  fprintf(stderr, "  SYSROOT %s\n", a->name);
  mkdirs(fmt("%s/usr/lib", s));
  copy_tree(fmt("%s/include", libc), fmt("%s/usr/include", s));
  copy_tree("abi/vx", fmt("%s/usr/include/vx", s));
  copy_file("abi/vx.h", fmt("%s/usr/include/vx.h", s)); // all of libvx's public headers (ADR-0004)
  copy_file(fmt("%s/lib/%s/libc.a", libc, triple), fmt("%s/usr/lib/libc.a", s));
  copy_file(fmt("%s/lib/%s/libm.a", libc, triple), fmt("%s/usr/lib/libm.a", s));
  copy_file(fmt("%s/libclang_rt.builtins.a", vectra_musl_lib(a, release)),
            fmt("%s/usr/lib/libclang_rt.builtins.a", s));
  copy_file("lib/vx-rt/sysroot/vectraos.cfg", fmt("%s/%s.cfg", s, triple));
  copy_file("lib/vx-rt/sysroot/link-head.rsp", fmt("%s/link-head.rsp", s));
  copy_file("lib/vx-rt/sysroot/link-tail.rsp", fmt("%s/link-tail.rsp", s));
  bool cxx = sysroot_cxx(a, s, from);
  // ISO C alone: a program asking for POSIX is refused when it compiles (6e2c1).
  const char *posix = fmt("%s/posix-probe.c", s);
  static const char POSIX_PROBE[] = "#define _POSIX_C_SOURCE 200809L\n#include <stdio.h>\n";
  write_file(posix, (vx_str){POSIX_PROBE, sizeof POSIX_PROBE - 1});
  if (run_capture_fd((const char *const[]){CLANG, fmt("--config-system-dir=%s/%s", root, s),
                                           fmt("--target=%s", triple), "-fsyntax-only", posix, nullptr},
                     2))
    die("the %s sysroot compiles a program defining _POSIX_C_SOURCE, which its C library must refuse",
        a->name);
  const char *taken = fmt("triple=%s tree.sha256=%s from=%s\n", triple, tree, libc);
  write_file(fmt("%s/llvm-libc", s), (vx_str){taken, strlen(taken)}); // which build it took (ADR-0033)
  // crt1.o, libvx.a, and libvx.so (6f1b1, ADR-0047: what a dynamic program
  // links, -fPIC with initial-exec TLS), as a first-party program is compiled.
  static const char *const SRC[3] = {"lib/vx-rt/start.c", "lib/vx-rt/libvx.c", "lib/vx-rt/libvx.c"};
  const char *obj[3] = {fmt("%s/usr/lib/crt1.o", s), fmt("%s/libvx.o", s), fmt("%s/libvx.pic.o", s)};
  cmd cc[3];
  cmd *ccs[3];
  for (int i = 0; i < 3; i++) {
    cc[i] = (cmd){};
    cmd_add(&cc[i], CLANG);
    cmd_addv(&cc[i], a->user_flags);
    cmd_addv(&cc[i], HOUSE_FLAGS);
    cmd_addv(&cc[i], USER_FLAGS);
    cmd_addv(&cc[i], release ? RELEASE_FLAGS : DEBUG_FLAGS);
    cmd_add(&cc[i], fmt("-ffile-prefix-map=%s=/src", root));
    if (i == 0) cmd_add(&cc[i], "-DVX_RT_CRT1"); // with the native vx_main
    // No unwind tables (6f2a, ADR-0033 §2a): an exception that would unwind
    // through libvx's frames finds none, and ends in std::terminate.
    cmd_addv(&cc[i], (const char *const[]){"-fno-unwind-tables", "-fno-asynchronous-unwind-tables", nullptr});
    if (i == 2)
      cmd_addv(&cc[i], (const char *const[]){"-fPIC", "-ftls-model=initial-exec", "-DVX_RT_SHARED", nullptr});
    cmd_addv(&cc[i], (const char *const[]){"-c", SRC[i], "-o", obj[i], nullptr});
    ccs[i] = &cc[i];
  }
  if (!run_parallel(ccs, 3)) die("cannot compile the %s sysroot's crt1.o and libvx", a->name);
  cmd ar = {};
  cmd_addv(&ar, (const char *const[]){LLVM_AR, "rcsD", fmt("%s/usr/lib/libvx.a", s), obj[1], nullptr});
  if (exists(fmt("%s/usr/lib/libvx.a", s))) unlink(fmt("%s/usr/lib/libvx.a", s));
  if (!run(&ar)) die("cannot make the %s sysroot's libvx.a", a->name);
  // The C library it calls into (memcpy, exit and the rest) is the program's:
  // bound when the loader starts it. The builtins it calls (aarch64's long
  // double conversions, for %Lf) are its own, not exported.
  cmd so = {};
  cmd_addv(&so, (const char *const[]){LLD,
                                      "-shared",
                                      "-soname",
                                      "libvx.so.1", // level 1's (ADR-0004 item 8): a program needs libvx.so.1
                                      "-nostdlib",
                                      "--build-id=sha1",
                                      "-z",
                                      "max-page-size=0x1000",
                                      "-z",
                                      "noexecstack",
                                      "-z",
                                      "now",
                                      "-z",
                                      "relro",
                                      "--hash-style=both",
                                      "-o",
                                      fmt("%s/usr/lib/libvx.so", s),
                                      obj[2],
                                      fmt("%s/usr/lib/libclang_rt.builtins.a", s),
                                      nullptr});
  if (!run(&so)) die("cannot make the %s sysroot's libvx.so", a->name);
  if (!check_libvx_exports(a, fmt("%s/usr/lib", s))) die("libvx.so's exports changed from a frozen level");
  // libc.so (6f1c1, decided 2026-10-08: the C library shared, ADR-0033 §3):
  // llvm-libc's archives whole, built -fPIC with initial-exec TLS, and the
  // builtins they call, not exported. The hooks it calls are libvx.so's,
  // bound when the loader starts a program, which links both. libm.so is a
  // script naming it, so -lm finds the same library.
  const char *lib = fmt("%s/usr/lib", s);
  cmd lc = {};
  cmd_addv(&lc, (const char *const[]){LLD,
                                      "-shared",
                                      "-soname",
                                      "libc.so",
                                      "-nostdlib",
                                      "--build-id=sha1",
                                      "--eh-frame-hdr",
                                      "-z",
                                      "max-page-size=0x1000",
                                      "-z",
                                      "noexecstack",
                                      "-z",
                                      "now",
                                      "-z",
                                      "relro",
                                      "--hash-style=both",
                                      "--exclude-libs",
                                      "libclang_rt.builtins.a",
                                      "-o",
                                      fmt("%s/libc.so", lib),
                                      "--whole-archive",
                                      fmt("%s/libc.a", lib),
                                      fmt("%s/libm.a", lib),
                                      "--no-whole-archive",
                                      fmt("%s/libclang_rt.builtins.a", lib),
                                      nullptr});
  if (!run(&lc)) die("cannot make the %s sysroot's libc.so", a->name);
  static const char LIBM[] = "/* llvm-libc's libm is in libc.so (6f1c1) */\nINPUT(-lc)\n";
  write_file(fmt("%s/libm.so", lib), (vx_str){LIBM, sizeof LIBM - 1});
  // The two compilers agree, or it stops: once the sysroot is whole, since
  // clang's Vectra toolchain links crt1.o only when it is there (a fresh
  // sysroot, a first release build, had none at the probe).
  probe_sysroot(a, s, fmt("%s/toolchain/out/bin", from), cxx);
  return true;
}

// --- The sysroot checked against the Swift toolchain's clang (6e2b2) ---
//
// The patched clang (LLVM patches 0002 and 0003) knows the target; Fedora's
// clang compiles for it with the configuration file and links with the
// response files. ADR-0033 §3: the two must agree, or the sysroot is
// refused. A probe is compiled by both and these compared: the predefined
// macros, but for those an LLVM version brings; the code generation the
// configuration sets, with and without -g; and the link line, the response
// files' against the patched driver's.

// Macros that come from the compilers' LLVM versions, not their configuration.
static const char *const PROBE_VERSION_MACROS[] = {"__clang_major__",
                                                   "__clang_minor__",
                                                   "__clang_patchlevel__",
                                                   "__clang_version__",
                                                   "__VERSION__",
                                                   "__MEMORY_SCOPE_CLUSTR",
                                                   "__ARM_PREFETCH_RANGE",
                                                   "__HAVE_FUNCTION_MULTI_VERSIONING",
                                                   "__cpp_modules",
                                                   "__cpp_trivial_relocatability",
                                                   nullptr};

// What the driver gives cc1 that the configuration file decides.
static const char *const PROBE_CC1_FLAGS[] = {"-mframe-pointer=",
                                              "-funwind-tables=",
                                              "-debug-info-kind=",
                                              "-dwarf-version=",
                                              "-std=",
                                              "-fmath-errno",
                                              "-pic-level",
                                              "-pic-is-pie",
                                              nullptr};

typedef struct {
  const char *item[1024];
  int count;
} probe_list;

static int probe_by_string(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void probe_add(probe_list *l, const char *s) {
  if (l->count == 1024) die("the probe's output is too long");
  l->item[l->count++] = s;
}

// A list on one line, its items joined by spaces.
static const char *probe_join(const probe_list *l) {
  const char *s = "";
  for (int i = 0; i < l->count; i++) s = fmt("%s%s%s", s, i ? " " : "", l->item[i]);
  return s;
}

// The two lists, which must be equal, as sets when sorted, else in order:
// what differs ("- Fedora's", "+ Swift's"), or nullptr.
static const char *probe_diff(probe_list *a, probe_list *b, bool sorted) {
  if (!sorted) {
    bool same = a->count == b->count;
    for (int i = 0; same && i < a->count; i++) same = strcmp(a->item[i], b->item[i]) == 0;
    return same ? nullptr : fmt("\n    - %s\n    + %s", probe_join(a), probe_join(b));
  }
  qsort(a->item, (size_t)a->count, sizeof a->item[0], probe_by_string);
  qsort(b->item, (size_t)b->count, sizeof b->item[0], probe_by_string);
  const char *diff = nullptr;
  int i = 0, j = 0;
  while (i < a->count || j < b->count) {
    int c = 0;
    if (i == a->count)
      c = 1;
    else if (j == b->count)
      c = -1;
    else
      c = strcmp(a->item[i], b->item[j]);
    if (c < 0) diff = fmt("%s\n    - %s", diff ? diff : "", a->item[i++]);
    if (c > 0) diff = fmt("%s\n    + %s", diff ? diff : "", b->item[j++]);
    if (!c) i++, j++;
  }
  return diff;
}

// out's lines that define macros not in PROBE_VERSION_MACROS.
static void probe_macros(char *out, probe_list *l) {
  for (char *line = strtok(out, "\n"); line; line = strtok(nullptr, "\n")) {
    bool version = false;
    for (int i = 0; PROBE_VERSION_MACROS[i] && !version; i++) {
      size_t n = strlen(PROBE_VERSION_MACROS[i]);
      version = strncmp(line + 8, PROBE_VERSION_MACROS[i], n) == 0 && line[8 + n] == ' ';
    }
    if (!version) probe_add(l, line);
  }
}

// A -### line's arguments, unquoted, from the first line holding `tool`,
// the program's own path left out.
static void probe_args(char *out, const char *tool, probe_list *l) {
  char *line = out ? strstr(out, tool) : nullptr;
  if (!line) die("the probe's driver printed no %s line", tool);
  while (line > out && line[-1] != '\n') line--;
  char *end = strchr(line, '\n');
  if (end) *end = 0;
  bool program = true;
  while (line && *line) {
    char *q = strchr(line, '"'), *r = q ? strchr(q + 1, '"') : nullptr;
    if (!r) break;
    *r = 0;
    if (!program) probe_add(l, q + 1);
    program = false;
    line = r + 1;
  }
}

// The cc1 flags of PROBE_CC1_FLAGS among args, with mrelocation-model's value.
static void probe_cc1(const probe_list *args, probe_list *l) {
  for (int i = 0; i < args->count; i++) {
    if (strcmp(args->item[i], "-mrelocation-model") == 0 && i + 1 < args->count)
      probe_add(l, fmt("-mrelocation-model=%s", args->item[i + 1]));
    for (int k = 0; PROBE_CC1_FLAGS[k]; k++)
      if (strncmp(args->item[i], PROBE_CC1_FLAGS[k], strlen(PROBE_CC1_FLAGS[k])) == 0)
        probe_add(l, args->item[i]);
  }
}

// A link line in a canonical form: its options sorted (an -L as the
// directory it names), then its inputs in order (crt1.o however named).
static void probe_link(const probe_list *args, const char *s, probe_list *opts, probe_list *ins) {
  for (int i = 0; i < args->count; i++) {
    const char *a = args->item[i];
    bool pair = !strcmp(a, "-z") || !strcmp(a, "-e") || !strcmp(a, "-o");
    if (pair && i + 1 < args->count) {
      if (strcmp(a, "-o") != 0) probe_add(opts, fmt("%s %s", a, args->item[i + 1]));
      i++;
    } else if (!strncmp(a, "-L", 2)) {
      probe_add(opts, a[2] == '=' ? fmt("-L%s%s", s, a + 3) : a);
    } else if (!strcmp(a, "-l:crt1.o") || (strlen(a) > 7 && !strcmp(a + strlen(a) - 7, "/crt1.o"))) {
      probe_add(ins, "crt1.o");
    } else if (strlen(a) > 2 && !strcmp(a + strlen(a) - 2, ".o")) {
      probe_add(ins, "the program's object"); // a temporary file's name, from the driver
    } else if (a[0] == '-' && strcmp(a, "--start-group") != 0 && strcmp(a, "--end-group") != 0 &&
               strncmp(a, "-l", 2) != 0) {
      probe_add(opts, a);
    } else {
      probe_add(ins, a);
    }
  }
}

// The words of a response file, as ld.lld reads them (no quoting in ours).
static void probe_rsp(const char *path, probe_list *l) {
  vx_str file = read_file(path);
  char *text = fmt("%.*s", (int)file.len, file.ptr);
  for (char *w = strtok(text, " \t\n"); w; w = strtok(nullptr, " \t\n")) probe_add(l, w);
}

static void probe_fail(const arch *a, const char *what, const char *diff) {
  if (diff)
    die("the %s sysroot: Fedora's clang and the Swift toolchain's disagree on %s (ADR-0033 §3):%s", a->name,
        what, diff);
}

// Compares the two compilers on the sysroot s, if the Swift toolchain's clang is there.
// One language's round: Fedora's driver with the configuration file against
// the patched one, on a probe in that language.
typedef struct {
  const char *name, *fedora, *swift, *x, *source, *tail;
} probe_lang;

static void probe_round(const arch *a, const char *s, const probe_lang *l) {
  const char *abs = fmt("%s/%s", root, s), *triple = sysroot_triple(a), *src = fmt("%s/%s", abs, l->source);
  const char *cfg = fmt("--config-system-dir=%s", abs), *target = fmt("--target=%s", triple);
  const char *sys = fmt("--sysroot=%s", abs);
  write_file(src, (vx_str){"int main(void) { return 0; }\n", 29});
  probe_list m1 = {}, m2 = {};
  probe_macros(run_capture((const char *const[]){l->fedora, cfg, target, "-dM", "-E", "-x", l->x, "/dev/null",
                                                 nullptr}),
               &m1);
  probe_macros(run_capture((const char *const[]){l->swift, target, sys, "-dM", "-E", "-x", l->x, "/dev/null",
                                                 nullptr}),
               &m2);
  probe_fail(a, fmt("%s's predefined macros", l->name), probe_diff(&m1, &m2, true));
  for (int g = 0; g < 2; g++) {
    const char *debug = g ? "-g" : "-g0";
    probe_list a1 = {}, a2 = {}, f1 = {}, f2 = {};
    probe_args(
        run_capture_fd((const char *const[]){l->fedora, cfg, target, debug, "-###", "-c", src, nullptr}, 2),
        "-cc1", &a1);
    probe_args(
        run_capture_fd((const char *const[]){l->swift, target, sys, debug, "-###", "-c", src, nullptr}, 2),
        "-cc1", &a2);
    probe_cc1(&a1, &f1);
    probe_cc1(&a2, &f2);
    probe_fail(a, fmt("%s's code generation%s", l->name, g ? " with -g" : ""), probe_diff(&f1, &f2, true));
  }
  probe_list l1 = {}, l2 = {}, o1 = {}, o2 = {}, i1 = {}, i2 = {};
  probe_add(&l1, sys);
  probe_rsp(fmt("%s/link-head.rsp", s), &l1);
  probe_add(&l1, "probe.o");
  probe_rsp(fmt("%s/%s", s, l->tail), &l1);
  probe_args(
      run_capture_fd((const char *const[]){l->swift, target, sys, "-###", src, "-o", "probe", nullptr}, 2),
      "ld.lld", &l2);
  probe_link(&l1, abs, &o1, &i1);
  probe_link(&l2, abs, &o2, &i2);
  probe_fail(a, fmt("%s's link options", l->name), probe_diff(&o1, &o2, true));
  probe_fail(a, fmt("%s's link inputs", l->name), probe_diff(&i1, &i2, false));
}

// Compares the two compilers on the sysroot s, for C and, if it has libc++,
// C++, where the Swift toolchain's patched clang is in bin.
static void probe_sysroot(const arch *a, const char *s, const char *bin, bool cxx) {
  const char *swift = fmt("%s/clang", bin);
  if (!exists(swift)) {
    fprintf(stderr, "  PROBE   %s skipped: no %s\n", a->name, swift);
    return;
  }
  probe_round(a, s, &(probe_lang){"C", CLANG, swift, "c", "probe.c", "link-tail.rsp"});
  if (cxx)
    probe_round(
        a, s, &(probe_lang){"C++", CLANGXX, fmt("%s/clang++", bin), "c++", "probe.cpp", "link-tail-c++.rsp"});
  fprintf(stderr, "  PROBE   %s: the two compilers agree%s\n", a->name, cxx ? ", for C and C++" : "");
}

// A program of ISO C against the sysroot: compiled by Fedora's clang with
// the configuration file, linked by ld.lld with the response files, as
// ADR-0033 §3 has a C program built for the target.
static bool native_cxx(const program *p) {
  size_t n = strlen(p->source);
  return n > 4 && strcmp(p->source + n - 4, ".cpp") == 0;
}

static void native_program(const arch *a, bool release, const program *p, const char *obj, cmd *cc, cmd *ld) {
  const char *s = sysroot_dir(a, release);
  bool cxx = native_cxx(p); // a test of the C++ runtime (6e2d2): first-party code is C23
  *cc = (cmd){};
  cmd_addv(cc, (const char *const[]){cxx ? CLANGXX : CLANG, fmt("--config-system-dir=%s", s),
                                     fmt("--target=%s", sysroot_triple(a)), cxx ? "-std=c++23" : "-std=c23",
                                     "-Wall", "-Wextra", "-Werror", nullptr});
  cmd_addv(cc, release ? RELEASE_FLAGS : DEBUG_FLAGS);
  if (p->lib_flags) cmd_addv(cc, p->lib_flags);
  if (p->link == LINK_SHARED)
    cmd_addv(cc, (const char *const[]){"-fPIC", "-ftls-model=initial-exec", nullptr});
  cmd_addv(cc, (const char *const[]){"-c", p->source, "-o", obj, nullptr});
  const char *dir = fmt("out/%s/%s", a->name, release ? "release" : "debug");
  *ld = (cmd){};
  cmd_addv(ld, (const char *const[]){LLD, fmt("--sysroot=%s", s), nullptr});
  if (p->link == LINK_SHARED) // a library of the target (6f2a): its own name, needing the C and C++ libraries
    cmd_addv(ld, (const char *const[]){"-shared", "-soname", p->name, "--build-id=sha1", "--eh-frame-hdr",
                                       "-z", "max-page-size=0x1000", "-z", "noexecstack", "-z", "now", "-z",
                                       "relro", "--hash-style=both", "-L=/usr/lib", obj, nullptr});
  else if (p->link == LINK_STATIC) // a static program: the archives (native(7))
    cmd_addv(ld, (const char *const[]){"-static", fmt("@%s/link-head.rsp", s), "--no-dynamic-linker", obj,
                                       nullptr});
  else
    cmd_addv(ld, (const char *const[]){fmt("@%s/link-head.rsp", s), obj, nullptr});
  for (const char *const *need = p->needs; need && *need; need++) cmd_add(ld, fmt("%s/%s", dir, *need));
  if (p->link == LINK_SHARED && p->lib) // libvxui.so's fonts: its own, not exported
    cmd_addv(ld, (const char *const[]){native_port_pic_archive(p->lib, a), "--exclude-libs=ALL", nullptr});
  if (p->link == LINK_SHARED && p->lib)
    cmd_addv(ld, (const char *const[]){"-lvx", "-lm", nullptr}); // needing libvx.so: calls it, holds no copy
  if (p->link == LINK_SHARED)
    cmd_addv(ld, cxx ? (const char *const[]){"-lc++", "-lc++abi", "-lunwind", "-lc", nullptr}
                     : (const char *const[]){"-lc", nullptr});
  else
    cmd_add(ld, fmt("@%s/link-tail%s.rsp", s, cxx ? "-c++" : ""));
  cmd_addv(ld, (const char *const[]){"-o", fmt("%s/%s", dir, p->name), nullptr});
}

static bool sysroot_made[2][2]; // [arch][release]: build_sysroot made it this run

static bool build_user_programs(const arch *a, bool release) {
  const char *dir = fmt("out/%s/%s", a->name, release ? "release" : "debug");
  static cmd cc[USER_PROGRAM_COUNT], ld[USER_PROGRAM_COUNT];
  cmd *ccs[USER_PROGRAM_COUNT], *lds[USER_PROGRAM_COUNT];
  static bool is_shared[USER_PROGRAM_COUNT];
  int n = 0;
  for (int i = 0; i < USER_PROGRAM_COUNT; i++) {
    const program *p = &USER_PROGRAMS[i];
    if (!program_for(p, a)) continue;
    const char *obj = fmt("%s/%s.o", dir, p->name);
    if (p->native && !sysroot_made[a == &ARCHES[0] ? 0 : 1][release]) continue; // no C library here
    if (p->native && native_cxx(p) && !exists(fmt("%s/usr/lib/libc++.a", sysroot_dir(a, release))))
      continue; // no C++ runtime here
    fprintf(stderr, "  CC    %-7s %s\n", p->name, a->name);
    if (p->native) {
      native_program(a, release, p, obj, &cc[n], &ld[n]);
      ccs[n] = &cc[n], lds[n] = &ld[n], is_shared[n] = p->link == LINK_SHARED, n++;
      continue;
    }
    cc[n] = (cmd){};
    cmd_add(&cc[n], CLANG);
    cmd_addv(&cc[n], p->posix ? posix_flags(a) : a->user_flags);
    cmd_addv(&cc[n], HOUSE_FLAGS);
    cmd_addv(&cc[n], p->posix ? POSIX_PROGRAM_FLAGS : USER_FLAGS);
    if (p->lib_flags) cmd_addv(&cc[n], p->lib_flags);
    if (p->link == LINK_SHARED)
      cmd_addv(&cc[n], (const char *const[]){"-fPIC", "-ftls-model=initial-exec", nullptr});
    if (p->link == LINK_LOADER) cmd_add(&cc[n], "-fPIE"); // its code PC-relative: linked high, past 2 GiB
    if (usage_flags(p)) cmd_addv(&cc[n], usage_flags(p));
    cmd_addv(&cc[n], release ? RELEASE_FLAGS : DEBUG_FLAGS);
    cmd_add(&cc[n], fmt("-ffile-prefix-map=%s=/src", root));
    cmd_addv(&cc[n], (const char *const[]){"-c", p->source, "-o", obj, nullptr});
    ld[n] = (cmd){};
    cmd_add(&ld[n], LLD);
    // A POSIX program is dynamic (6f1b2): musl's libc.so, its own interpreter.
    if ((p->link == LINK_STATIC && !p->posix) || p->link == LINK_LOADER)
      cmd_addv(&ld[n], (const char *const[]){"-static", "-e", "_start", nullptr});
    if (p->posix)
      cmd_addv(&ld[n], (const char *const[]){"-e", "_start", "-z", "now", "-z", "relro", "--hash-style=both",
                                             fmt("--dynamic-linker=/lib/ld-musl-%s.so.1", a->name), nullptr});
    if (p->link == LINK_LOADER) cmd_add(&ld[n], "--image-base=0xff000000000"); // below where as_map places
    if (p->link == LINK_SHARED)
      cmd_addv(&ld[n], (const char *const[]){"-shared", "-soname", p->name, nullptr});
    if (p->link == LINK_DYNAMIC)
      cmd_addv(&ld[n], (const char *const[]){"-e", "_start", "--dynamic-linker=/lib/ld-vx", nullptr});
    if (p->link == LINK_SHARED || p->link == LINK_DYNAMIC) // bound at load, RELRO, both hash tables
      cmd_addv(&ld[n], (const char *const[]){"-z", "now", "-z", "relro", "--hash-style=both", nullptr});
    cmd_addv(&ld[n], (const char *const[]){"-nostdlib", "--build-id=sha1", "-z", "max-page-size=0x1000", "-z",
                                           "noexecstack", "-o", nullptr});
    cmd_add(&ld[n], fmt("%s/%s", dir, p->name));
    for (const char *const *need = p->needs; need && *need; need++) cmd_add(&ld[n], fmt("%s/%s", dir, *need));
    const char *lib = vectra_musl_lib(a, release);
    if (p->posix) {
      cmd_add(&ld[n], fmt("%s/dcrt1.o", lib)); // musl's own crt1, which libc.so starts it in
      cmd_add(&ld[n], fmt("%s/crti.o", lib));
    }
    cmd_add(&ld[n], obj);
    if (p->lib) cmd_add(&ld[n], native_port_archive(p->lib, a));
    if (p->posix) {
      cmd_add(&ld[n], fmt("%s/libc.so", lib));
      cmd_add(&ld[n], fmt("%s/libclang_rt.builtins.a", lib));
      cmd_add(&ld[n], fmt("%s/crtn.o", lib));
    } else { // what the compiler calls itself: aarch64's long double conversions, for vx-fmt's %Lf
      cmd_add(&ld[n], fmt("%s/libclang_rt.builtins.a", lib));
    }
    ccs[n] = &cc[n];
    lds[n] = &ld[n];
    is_shared[n] = p->link == LINK_SHARED;
    n++;
  }
  // Shared libraries first: what links them reads them.
  cmd *shared[USER_PROGRAM_COUNT], *rest[USER_PROGRAM_COUNT];
  int ns = 0, nr = 0;
  for (int k = 0; k < n; k++) {
    if (is_shared[k])
      shared[ns++] = lds[k];
    else
      rest[nr++] = lds[k];
  }
  if (!run_parallel(ccs, n)) return false;
  for (int k = 0; k < ns; k++) // in the table's order: a library after those it needs
    if (!run(shared[k])) return false;
  return run_parallel(rest, nr);
}

// Vendored POSIX programs (docs/04 §3.1): a port's sources= and each
// program='s own, compiled once at the port's flags against vectra-musl and
// cached, as musl is (out/NAME/ARCH), then linked with the mode's libc into
// boot/bin, alongside the user programs, or the port's dir= under it. With
// archive=yes the shared sources are linked from an archive, so each program
// takes only what it uses. A source under ports/ is a generated file.

// Where a port's programs go, under boot/bin and the output directory: "" or "posix/".
static const char *port_bin_dir(const port *p) {
  vx_str d = vx_ndb_get(&p->head, "dir");
  return d.len ? fmt("%s/", str_dup(d)) : "";
}
static port lua, sbase;
static port *const POSIX_PORTS[] = {&lua, &sbase};
static constexpr int POSIX_PORT_COUNT = sizeof POSIX_PORTS / sizeof POSIX_PORTS[0];

// A box (box=NAME): every program in one binary, as sbase's own sbase-box
// is, each program's main renamed NAME_main on the command line (the tree is
// not edited), and a generated main choosing one by argv[0]; bootfs holds the
// box once and each program's name as a hard link to it. A program= with
// alone=yes is linked by itself all the same (sbase's make, which mkbox
// leaves out too).
static const char *box_rels[PORT_MAX_FILES * 32], *box_flags[PORT_MAX_FILES * 32];
static int box_count;

// "sha512-224sum" as an identifier: sha512_224sum.
static const char *box_ident(const char *name) {
  char *id = fmt("%s", name);
  for (char *c = id; *c; c++)
    if (*c == '-') *c = '_';
  return id;
}

static bool program_alone(const vx_ndb_record *r) { return words_has(vx_ndb_get(r, "alone"), "yes"); }

static vx_str box_file_flags(const char *rel) {
  for (int i = 0; i < box_count; i++)
    if (strcmp(box_rels[i], rel) == 0) return (vx_str){box_flags[i], strlen(box_flags[i])};
  return (vx_str){};
}

// The box's main, generated from the port's program records.
static const char *box_main(const port *p, const char *objdir, const char *box) {
  const char *path = fmt("%s/%s.c", objdir, box);
  FILE *f = fopen(path, "w");
  if (!f) die("cannot write %s", path);
  fprintf(f,
          "// Generated by build from %s/port.ndb: the %s box's main, which runs the\n"
          "// program its name (argv[0]) names, or its first argument's.\n\n"
          "#include <stdio.h>\n#include <string.h>\n\n",
          p->dir, box);
  for (int i = 0; i < p->program_count; i++)
    if (!program_alone(&p->programs[i]))
      fprintf(f, "int %s_main(int, char **);\n", box_ident(str_dup(vx_ndb_get(&p->programs[i], "program"))));
  fprintf(f,
          "\nstatic const struct {\n  const char *name;\n  int (*main)(int, char **);\n} programs[] = {\n");
  for (int i = 0; i < p->program_count; i++) {
    const char *name = str_dup(vx_ndb_get(&p->programs[i], "program"));
    if (!program_alone(&p->programs[i])) fprintf(f, "    {\"%s\", %s_main},\n", name, box_ident(name));
  }
  if (words_has(vx_ndb_get(&p->head, "box.alias"), "[")) fprintf(f, "    {\"[\", test_main},\n");
  fprintf(f,
          "};\n\n"
          "int main(int argc, char **argv) {\n"
          "  for (int shift = 0; shift < 2 && argc > 0; shift++, argc--, argv++) {\n"
          "    const char *name = strrchr(argv[0], '/') ? strrchr(argv[0], '/') + 1 : argv[0];\n"
          "    for (size_t i = 0; i < sizeof programs / sizeof programs[0]; i++)\n"
          "      if (strcmp(programs[i].name, name) == 0) return programs[i].main(argc, argv);\n"
          "  }\n"
          "  fputs(\"usage: %s program [argument ...]\\n\", stderr);\n"
          "  return 1;\n"
          "}\n",
          box);
  fclose(f);
  return path;
}

static bool build_port_programs(const arch *a, bool release) {
  const char *dir = fmt("out/%s/%s", a->name, release ? "release" : "debug"),
             *lib = vectra_musl_lib(a, release);
  for (int k = 0; k < POSIX_PORT_COUNT; k++) {
    const port *p = POSIX_PORTS[k];
    const char *box = vx_ndb_get(&p->head, "box").len ? str_dup(vx_ndb_get(&p->head, "box")) : nullptr;
    static file_list files;
    files = (file_list){};
    add_words(&files, vx_ndb_get(&p->head, "sources"));
    int shared = files.count, first[PORT_MAX_PROGRAMS] = {};
    box_count = 0;
    for (int i = 0; i < p->program_count; i++) {
      first[i] = files.count;
      add_words(&files, vx_ndb_get(&p->programs[i], "sources"));
      const char *flag = fmt("-Dmain=%s_main", box_ident(str_dup(vx_ndb_get(&p->programs[i], "program"))));
      for (int j = first[i]; box && !program_alone(&p->programs[i]) && j < files.count; j++)
        box_rels[box_count] = files.paths[j], box_flags[box_count++] = flag;
    }
    const char **objs = alloc((size_t)files.count * sizeof *objs);
    if (!build_cached(p, a, &files, objs, box ? box_file_flags : nullptr)) return false;
    const char *bin = fmt("%s/%s", dir, port_bin_dir(p)), *ar = nullptr;
    const char *objdir = fmt("%s/%s-port", dir, p->name);
    mkdirs(bin);
    mkdirs(objdir);
    if (words_has(vx_ndb_get(&p->head, "archive"), "yes")) {
      ar = fmt("%s/lib%s.a", objdir, p->name);
      if (!archive(ar, objdir, objs, shared)) return false;
    }
    static cmd ld[PORT_MAX_PROGRAMS];
    cmd *lds[PORT_MAX_PROGRAMS];
    int links = 0;
    const char *boxobj = nullptr;
    if (box) { // the generated main, at the port's flags
      cmd cc = {};
      cmd_add(&cc, CLANG);
      cmd_addv(&cc, posix_flags(a));
      cmd_add_words(&cc, vx_ndb_get(&p->head, "cflags"));
      boxobj = fmt("%s/%s.o", objdir, box);
      cmd_addv(&cc, (const char *const[]){"-c", box_main(p, objdir, box), "-o", boxobj, nullptr});
      if (!run(&cc)) return false;
    }
    // Each program by itself, or the box (i == -1) and the programs left out of it.
    for (int i = box ? -1 : 0; i < p->program_count; i++) {
      if (box && i >= 0 && !program_alone(&p->programs[i])) continue;
      const char *name = i < 0 ? box : str_dup(vx_ndb_get(&p->programs[i], "program"));
      ld[links] = (cmd){};
      cmd *c = &ld[links];
      cmd_add(c, LLD);
      cmd_addv(c,
               (const char *const[]){"-static", "-nostdlib", "--build-id=sha1", "-z", "max-page-size=0x1000",
                                     "-z", "noexecstack", "-e", "_start", "-o", fmt("%s%s", bin, name),
                                     fmt("%s/crt1.o", lib), fmt("%s/crti.o", lib), nullptr});
      if (i < 0) {
        cmd_add(c, boxobj);
        for (int j = 0; j < p->program_count; j++) {
          if (program_alone(&p->programs[j])) continue;
          int end = j + 1 == p->program_count ? files.count : first[j + 1];
          for (int m = first[j]; m < end; m++) cmd_add(c, objs[m]);
        }
      } else {
        int end = i + 1 == p->program_count ? files.count : first[i + 1];
        for (int m = first[i]; m < end; m++) cmd_add(c, objs[m]);
      }
      if (ar) cmd_add(c, ar);
      for (int j = 0; j < shared && !ar; j++) cmd_add(c, objs[j]);
      cmd_addv(c, (const char *const[]){fmt("%s/libc.a", lib), fmt("%s/libclang_rt.builtins.a", lib),
                                        fmt("%s/crtn.o", lib), nullptr});
      lds[links++] = c;
      fprintf(stderr, "  LD    %-7s %s\n", name, a->name);
    }
    if (!run_parallel(lds, links)) return false;
  }
  return true;
}

static bool build_arch(const arch *a, bool release) {
  if (!build_kernel(a, release) || !build_vectra_musl(a, release) || !build_native_ports(a)) return false;
  sysroot_made[a == &ARCHES[0] ? 0 : 1][release] = build_sysroot(a, release);
  if (!build_user_programs(a, release) || !build_port_programs(a, release)) return false;
  // libvxui.so's exports, written beside it as libvx's are (ADR-0056): held
  // to a list once frozen, with libvx's level 2.
  const char *vxui = fmt("out/%s/%s/libvxui.so", a->name, release ? "release" : "debug");
  if (exists(vxui)) write_file(fmt("%s.symbols", vxui), elf_exports(vxui));
  const vx_ndb_record *t = port_target_for(&limine, a);
  return !t || build_port_target(&limine, t);
}

static void check_toolchain(void) {
  check_version(CLANG, CLANG_VERSION);
  check_version(LLD, LLD_VERSION);
  check_version(OBJCOPY, OBJCOPY_VERSION);
  check_version(LLVM_AR, LLVM_AR_VERSION);
  if (!exists(CLANG_RESOURCE_INCLUDE))
    die("no %s: the pinned clang's headers (ADR-0001)", CLANG_RESOURCE_INCLUDE);
  port_load(&limine, "limine");
  port_load(&musl, "musl");
  port_load(&compiler_rt, "compiler-rt");
  port_load(&lua, "lua");
  port_load(&sbase, "sbase");
  port_load(&acpica, "acpica");
  port_load(&monocypher, "monocypher");
  port_load(&font, "font");
  sbase.input_hash = hash_tree(sbase.input_hash, fmt("%s/ports/sbase/generated", root));
  // musl's build also reads the back end's syscall_arch.h and the generated headers.
  musl.input_hash = hash_tree(musl.input_hash, fmt("%s/ports/musl/vx/arch", root));
  musl.input_hash = hash_tree(musl.input_hash, fmt("%s/ports/musl/generated", root));
  // The ports built against musl's headers (posix_flags) are built again when
  // they change: musl's hash, which covers its tree and the generated ones,
  // goes into theirs.
  port *against_musl[] = {&compiler_rt, &lua, &sbase};
  for (size_t i = 0; i < sizeof against_musl / sizeof against_musl[0]; i++)
    against_musl[i]->input_hash = hash_bytes(
        against_musl[i]->input_hash, (vx_str){(const char *)&musl.input_hash, sizeof musl.input_hash});
}

// Runs fn for each architecture (or only one) in parallel, one child each.
static int per_arch(const arch *only, bool release, bool (*fn)(const arch *, bool)) {
  pid_t pids[ARCH_COUNT] = {};
  for (int i = 0; i < ARCH_COUNT; i++) {
    if (only && only != &ARCHES[i]) continue;
    pids[i] = fork();
    if (pids[i] < 0) die("fork failed");
    if (pids[i] == 0) _exit(fn(&ARCHES[i], release) ? 0 : 1);
  }
  bool ok = true;
  for (int i = 0; i < ARCH_COUNT; i++)
    if (pids[i]) ok = wait_ok(pids[i]) && ok;
  return ok ? 0 : 1;
}

// --- image: a GPT disk holding one EFI system partition (docs/04 §3.2) ---

static const char MFORMAT[] = "/usr/bin/mformat";
static const char MMD[] = "/usr/bin/mmd";
static const char MCOPY[] = "/usr/bin/mcopy";
static const char MDEL[] = "/usr/bin/mdel";
static const char FSCK_FAT[] = "/usr/bin/fsck.fat"; // dosfstools: checks what dosfs and lib/vx-fat wrote
static const char SEVEN_ZIP[] = "/usr/bin/7z";      // p7zip: reads write_iso's Joliet tree

static constexpr uint64_t SECTOR = 512;
// The EFI system partition: 64 MiB, or more for an image whose files need
// it (make_image sets it: a test image with Swift's programs and their
// debugging information, 6e3c), in 32 MiB steps.
static constexpr uint64_t ESP_MIN_BYTES = 64ull << 20;
static uint64_t esp_bytes = ESP_MIN_BYTES;
static constexpr uint64_t ESP_LBA = 2048; // 1 MiB in, as partitioning tools align it
static constexpr uint32_t GPT_ENTRIES = 128;
static constexpr size_t GPT_TABLE_BYTES = (size_t)GPT_ENTRIES * 128; // 128 entries of 128 bytes

// The EFI system partition type, C12A7328-F81F-11D2-BA4B-00A0C93EC93B, as stored on disk.
static const uint8_t ESP_TYPE[16] = {
    0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b,
};

static uint32_t crc32(const uint8_t *p, size_t n) {
  uint32_t c = 0xffffffff;
  for (size_t i = 0; i < n; i++) {
    c ^= p[i];
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c;
}

static void put16(uint8_t *p, uint16_t v) {
  for (int i = 0; i < 2; i++) p[i] = (uint8_t)(v >> 8 * i);
}
static void put32(uint8_t *p, uint32_t v) {
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> 8 * i);
}
static void put64(uint8_t *p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> 8 * i);
}

// A GUID derived from the image's inputs, so one commit always gives the same disk (docs/04 §7).
static void derived_guid(uint8_t out[16], uint64_t seed, const char *what) {
  uint64_t a = hash_bytes(seed, (vx_str){what, strlen(what)});
  uint64_t b = hash_bytes(a, (vx_str){what, strlen(what)});
  put64(out, a);
  put64(out + 8, b);
  out[7] = (out[7] & 0x0f) | 0x40; // version 4 layout
  out[8] = (out[8] & 0x3f) | 0x80; // RFC 4122 variant
}

static void gpt_header(uint8_t *h, uint64_t my_lba, uint64_t alt_lba, uint64_t entries_lba, uint64_t last_lba,
                       const uint8_t disk_guid[16], uint32_t entries_crc) {
  static const uint8_t SIGNATURE[8] = {'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T'}; // no NUL
  memset(h, 0, SECTOR);
  memcpy(h, SIGNATURE, sizeof SIGNATURE);
  put32(h + 8, 0x00010000);
  put32(h + 12, 92);
  put64(h + 24, my_lba);
  put64(h + 32, alt_lba);
  put64(h + 40, 34);            // first usable LBA
  put64(h + 48, last_lba - 33); // last usable LBA
  memcpy(h + 56, disk_guid, 16);
  put64(h + 72, entries_lba);
  put32(h + 80, GPT_ENTRIES);
  put32(h + 84, 128);
  put32(h + 88, entries_crc);
  put32(h + 16, crc32(h, 92));
}

// A file's size, without reading it into the arena.
static uint64_t file_bytes(const char *path) {
  struct stat st;
  if (stat(path, &st) != 0) die("cannot stat %s", path);
  return (uint64_t)st.st_size;
}

static void pwrite_all(int fd, const void *p, size_t n, uint64_t off, const char *path) {
  if (pwrite(fd, p, n, (off_t)off) != (ssize_t)n) die("cannot write %s", path);
}

static void write_gpt_disk(const char *path, const char *esp_path, uint64_t seed) {
  uint64_t esp_sectors = esp_bytes / SECTOR;
  uint64_t total = ESP_LBA + esp_sectors + 2048;
  uint64_t last = total - 1;

  uint8_t disk_guid[16], part_guid[16];
  derived_guid(disk_guid, seed, "disk");
  derived_guid(part_guid, seed, "esp");

  uint8_t *entries = alloc(GPT_TABLE_BYTES);
  memset(entries, 0, GPT_TABLE_BYTES);
  memcpy(entries, ESP_TYPE, 16);
  memcpy(entries + 16, part_guid, 16);
  put64(entries + 32, ESP_LBA);
  put64(entries + 40, ESP_LBA + esp_sectors - 1);
  const char *name = "EFI system partition";
  for (size_t i = 0; name[i]; i++) put16(entries + 56 + 2 * i, (uint16_t)name[i]);
  uint32_t entries_crc = crc32(entries, GPT_TABLE_BYTES);

  // A protective MBR: one partition of type 0xEE covering the disk.
  uint8_t mbr[SECTOR] = {};
  uint8_t *pe = mbr + 446;
  pe[1] = 0x00;
  pe[2] = 0x02;
  pe[3] = 0x00; // CHS of LBA 1
  pe[4] = 0xee;
  pe[5] = 0xff;
  pe[6] = 0xff;
  pe[7] = 0xff;
  put32(pe + 8, 1);
  put32(pe + 12, last > 0xffffffff ? 0xffffffff : (uint32_t)last);
  mbr[510] = 0x55;
  mbr[511] = 0xaa;

  uint8_t primary[SECTOR], backup[SECTOR];
  gpt_header(primary, 1, last, 2, last, disk_guid, entries_crc);
  gpt_header(backup, last, 1, last - 32, last, disk_guid, entries_crc);

  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) die("cannot create %s", path);
  if (ftruncate(fd, (off_t)(total * SECTOR)) != 0) die("cannot size %s", path);
  pwrite_all(fd, mbr, SECTOR, 0, path);
  pwrite_all(fd, primary, SECTOR, SECTOR, path);
  pwrite_all(fd, entries, GPT_TABLE_BYTES, 2 * SECTOR, path);
  pwrite_all(fd, entries, GPT_TABLE_BYTES, (last - 32) * SECTOR, path);
  pwrite_all(fd, backup, SECTOR, last * SECTOR, path);

  int in = open(esp_path, O_RDONLY);
  if (in < 0) die("cannot read %s", esp_path);
  static char chunk[1 << 20];
  for (uint64_t off = 0; off < esp_bytes;) {
    ssize_t n = pread(in, chunk, sizeof chunk, (off_t)off);
    if (n <= 0) die("short read from %s", esp_path);
    pwrite_all(fd, chunk, (size_t)n, ESP_LBA * SECTOR + off, path);
    off += (uint64_t)n;
  }
  close(in);
  if (close(fd) != 0) die("cannot write %s", path);
}

// --- ISO 9660 with El Torito, Rock Ridge and Joliet (image --iso, M3; M5 step 8c) ---
//
// A CD image for UEFI. Its El Torito boot entry ("no emulation", platform
// EFI) is a small FAT image holding only the loader; the loader then reads
// its configuration, the kernel and the modules from the ISO 9660 tree, as
// Limine does on a CD. An MBR in the system area also names the boot image
// as a partition (type EFI), as xorriso's --efi-boot-part does: that is how
// Limine finds which volume it was booted from.
//
// Names three ways (M5 step 8c), each tree's directories its own, the
// files' bytes shared:
// - ISO 9660 level 2: upper case, [A-Z0-9_], "NAME.EXT;1", up to 30
//   characters, made unique in a directory with ~N; what Limine matches
//   case-insensitively.
// - Rock Ridge (RRIP 1991A, over SUSP) in the same records: the real name
//   (NM), POSIX mode, links, owner (PX, all root's), the time (TF), symbolic
//   links (SL). What does not fit a record's 255 bytes goes to its
//   directory's continuation area (CE), as the root's ER does.
// - Joliet (UCS-2, escape %/E, so UTF-16 here), in a supplementary volume
//   descriptor's tree: names up to 64 units, no symbolic links.
// Dates are SOURCE_DATE_EPOCH's, so the image is reproducible. El Torito's
// boot record is at sector 17, as its specification requires; the Joliet
// descriptor follows it.

static constexpr uint32_t ISO_SECTOR = 2048;
static constexpr int ISO_MAX_DIRS = 64;
static constexpr int ISO_MAX_KIDS = 256;

typedef struct iso_file {
  const char *path; // in the ISO: "boot/vx/kernel.elf"
  const char *from; // where it is on this machine; nullptr for a symbolic link
  const char *link; // a symbolic link's target
  uint64_t size;    // filled in by write_iso
} iso_file;

// Copies the file at from to offset `at` of fd, a chunk at a time.
static void copy_into(int fd, const char *path, const char *from, uint64_t at) {
  int in = open(from, O_RDONLY);
  if (in < 0) die("cannot read %s", from);
  static char chunk[1 << 20];
  for (ssize_t n; (n = read(in, chunk, sizeof chunk)) != 0; at += (uint64_t)n) {
    if (n < 0) die("cannot read %s", from);
    pwrite_all(fd, chunk, (size_t)n, at, path);
  }
  close(in);
}

static void iso_both16(uint8_t *p, uint16_t v) { // ISO 9660's both-endian fields
  p[0] = p[3] = (uint8_t)v, p[1] = p[2] = (uint8_t)(v >> 8);
}
static void iso_both32(uint8_t *p, uint32_t v) {
  put32(p, v);
  p[4] = (uint8_t)(v >> 24), p[5] = (uint8_t)(v >> 16), p[6] = (uint8_t)(v >> 8), p[7] = (uint8_t)v;
}

static void iso_put(uint8_t *p, const char *s) { // the characters, without a NUL
  for (size_t i = 0; s[i]; i++) p[i] = (uint8_t)s[i];
}

static void iso_text(uint8_t *p, size_t len, const char *s) { // a-characters, padded with spaces
  memset(p, ' ', len);
  for (size_t i = 0; i < len && s[i]; i++) p[i] = (uint8_t)s[i];
}

static void iso_text16(uint8_t *p, size_t len, const char *s) { // the same in UCS-2, big-endian (Joliet)
  for (size_t i = 0; i + 1 < len; i += 2) p[i] = 0, p[i + 1] = ' ';
  for (size_t i = 0; 2 * i + 1 < len && s[i]; i++) p[2 * i + 1] = (uint8_t)s[i];
}

// A record's 7-byte date: SOURCE_DATE_EPOCH, UTC.
static void iso_date(uint8_t *p) {
  const char *e = getenv("SOURCE_DATE_EPOCH");
  time_t t = e ? (time_t)strtoll(e, nullptr, 10) : 0;
  struct tm tm;
  gmtime_r(&t, &tm);
  p[0] = (uint8_t)tm.tm_year, p[1] = (uint8_t)(tm.tm_mon + 1), p[2] = (uint8_t)tm.tm_mday;
  p[3] = (uint8_t)tm.tm_hour, p[4] = (uint8_t)tm.tm_min, p[5] = (uint8_t)tm.tm_sec, p[6] = 0;
}

// A directory record at p, with su (system use: Rock Ridge) after its name; its length.
static size_t iso_record(uint8_t *p, uint32_t lba, uint32_t size, bool dir, const uint8_t *name,
                         size_t name_len, const uint8_t *su, size_t su_len) {
  size_t len = 33 + name_len + !(name_len & 1) + su_len; // the name padded to an even length
  len += len & 1;
  if (len > 255) die("an ISO directory record of %zu bytes", len);
  memset(p, 0, len);
  p[0] = (uint8_t)len;
  iso_both32(p + 2, lba);
  iso_both32(p + 10, size);
  iso_date(p + 18);
  p[25] = dir ? 2 : 0;
  iso_both16(p + 28, 1); // volume sequence number
  p[32] = (uint8_t)name_len;
  memcpy(p + 33, name, name_len);
  if (su_len) memcpy(p + 33 + name_len + !(name_len & 1), su, su_len);
  return len;
}

typedef struct iso_kid {
  const char *name;    // the real name: Rock Ridge's
  char iso[33];        // ISO 9660's, unique in the directory: "LIMINE.CONF;1" (30, then ";1", and a NUL)
  uint8_t joliet[128]; // UTF-16BE, up to 64 units
  size_t joliet_len;
  int dir;  // the directory's index, or -1
  int file; // the file's index, or -1; -2 the boot catalog, -3 the boot image
} iso_kid;

typedef struct iso_dir {
  const char *path; // "" for the root
  int parent;       // its index, once sorted
  iso_kid *kids;
  int nkids;
  uint32_t lba[2], size[2]; // the Rock Ridge tree's, the Joliet tree's
  uint32_t ce_lba, ce_size; // its continuation area
} iso_dir;

static int iso_dir_index(const iso_dir *dirs, int count, const char *path, size_t len) {
  for (int i = 0; i < count; i++)
    if (strlen(dirs[i].path) == len && memcmp(dirs[i].path, path, len) == 0) return i;
  return -1;
}

static int iso_depth(const char *path) {
  int d = *path ? 1 : 0;
  for (const char *p = path; *p; p++) d += *p == '/';
  return d;
}

// The ISO 9660 name for a real one, unique among the directory's first n kids.
static void iso_mangle(const char *name, bool file, const iso_kid *kids, int n, char out[33]) {
  const char *dot = file ? strrchr(name, '.') : nullptr;
  if (dot == name) dot = nullptr;
  char base[32], ext[32];
  size_t nb = 0, ne = 0;
  for (const char *p = name; *p && p != dot && nb < 30; p++) {
    char c = *p >= 'a' && *p <= 'z' ? (char)(*p - 32) : *p;
    base[nb++] = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ? c : '_';
  }
  for (const char *p = dot ? dot + 1 : ""; *p && ne < 8; p++) {
    char c = *p >= 'a' && *p <= 'z' ? (char)(*p - 32) : *p;
    ext[ne++] = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ? c : '_';
  }
  if (!nb) base[nb++] = '_';
  size_t room = file ? 30 - 1 - ne : 31; // name, dot and extension: 30 at most
  if (nb > room) nb = room;
  for (int k = 0;; k++) {
    char tail[12] = "";
    if (k) snprintf(tail, sizeof tail, "~%d", k);
    size_t keep = nb + strlen(tail) > room ? room - strlen(tail) : nb;
    if (file)
      snprintf(out, 33, "%.*s%s.%.*s;1", (int)keep, base, tail, (int)ne, ext);
    else
      snprintf(out, 33, "%.*s%s", (int)keep, base, tail);
    bool taken = false;
    for (int i = 0; i < n && !taken; i++) taken = strcmp(kids[i].iso, out) == 0;
    if (!taken) return;
  }
}

// The real name as Joliet's UTF-16BE, cut at 64 units (and never mid-pair).
static size_t iso_joliet(const char *name, uint8_t out[128]) {
  size_t n = 0;
  for (const uint8_t *p = (const uint8_t *)name; *p;) {
    uint32_t c = *p++;
    int more = (c >= 0xc0) + (c >= 0xe0) + (c >= 0xf0); // continuation bytes after the lead
    static const uint8_t lead[4] = {0x7f, 0x1f, 0x0f, 0x07};
    c &= lead[more];
    for (int k = 0; k < more && *p; k++) c = c << 6 | (*p++ & 0x3f);
    if (c >= 0x1'0000) {
      if (n + 4 > 128) break;
      uint32_t hi = 0xd800 + ((c - 0x1'0000) >> 10), lo = 0xdc00 + ((c - 0x1'0000) & 0x3ff);
      out[n++] = (uint8_t)(hi >> 8), out[n++] = (uint8_t)hi, out[n++] = (uint8_t)(lo >> 8),
      out[n++] = (uint8_t)lo;
    } else {
      if (n + 2 > 128) break;
      out[n++] = (uint8_t)(c >> 8), out[n++] = (uint8_t)c;
    }
  }
  return n;
}

static int iso_by_name(const void *a, const void *b) {
  return strcmp(((const iso_kid *)a)->iso, ((const iso_kid *)b)->iso);
}

static int iso_by_joliet(const void *a, const void *b) {
  const iso_kid *x = a, *y = b;
  size_t n = x->joliet_len < y->joliet_len ? x->joliet_len : y->joliet_len;
  int c = memcmp(x->joliet, y->joliet, n);
  return c ? c : (x->joliet_len > y->joliet_len) - (x->joliet_len < y->joliet_len);
}

// Rock Ridge's entries for a record: built whole, then split between the
// record and the directory's continuation area.
typedef struct iso_su {
  uint8_t buf[2048];
  size_t len, ends[64]; // each entry's end
  int n;
} iso_su;

static void iso_su_add(iso_su *s, const char sig[2], const uint8_t *data, size_t len) {
  if (s->len + 4 + len > sizeof s->buf || s->n == 64 || 4 + len > 255)
    die("an ISO entry's Rock Ridge is too long");
  uint8_t *p = s->buf + s->len;
  p[0] = (uint8_t)sig[0], p[1] = (uint8_t)sig[1], p[2] = (uint8_t)(4 + len), p[3] = 1;
  memcpy(p + 4, data, len);
  s->len += 4 + len;
  s->ends[s->n++] = s->len;
}

// The entries for one record: the root's "." gets SP and ER; every record
// PX and TF; a named one NM (in parts of 250 at most), a link SL.
static void iso_su_for(iso_su *s, bool root_dot, uint32_t mode, uint32_t links, const char *name,
                       const char *link) {
  s->len = 0, s->n = 0;
  if (root_dot) {
    iso_su_add(s, "SP", (const uint8_t[]){0xbe, 0xef, 0}, 3);
    static const char
        id[] = "RRIP_1991A",
        des[] = "THE ROCK RIDGE INTERCHANGE PROTOCOL PROVIDES SUPPORT FOR POSIX FILE SYSTEM SEMANTICS",
        src[] = "PLEASE CONTACT DISC PUBLISHER FOR SPECIFICATION SOURCE.  SEE PUBLISHER IDENTIFIER "
                "IN PRIMARY VOLUME DESCRIPTOR FOR CONTACT INFORMATION.";
    uint8_t er[4 + sizeof id + sizeof des + sizeof src];
    er[0] = sizeof id - 1, er[1] = sizeof des - 1, er[2] = sizeof src - 1, er[3] = 1;
    memcpy(er + 4, id, sizeof id - 1);
    memcpy(er + 4 + sizeof id - 1, des, sizeof des - 1);
    memcpy(er + 4 + sizeof id - 1 + sizeof des - 1, src, sizeof src - 1);
    iso_su_add(s, "ER", er, 4 + sizeof id + sizeof des + sizeof src - 3);
  }
  uint8_t px[32] = {};
  iso_both32(px, mode), iso_both32(px + 8, links); // uid and gid 0
  iso_su_add(s, "PX", px, sizeof px);
  uint8_t tf[8] = {0x02}; // the modification time
  iso_date(tf + 1);
  iso_su_add(s, "TF", tf, sizeof tf);
  for (size_t len = name ? strlen(name) : 0, at = 0; at < len;) {
    size_t part = len - at > 250 ? 250 : len - at;
    uint8_t nm[251];
    nm[0] = at + part < len ? 1 : 0; // CONTINUE
    memcpy(nm + 1, name + at, part);
    iso_su_add(s, "NM", nm, 1 + part);
    at += part;
  }
  if (link) {
    uint8_t sl[251] = {0};
    size_t n = 1;
    const char *p = link;
    if (*p == '/') sl[n++] = 0x08, sl[n++] = 0, p++; // ROOT
    while (*p) {
      size_t c = strcspn(p, "/");
      if (n + 2 + c > sizeof sl) die("a symbolic link's target is too long for the ISO");
      bool cur = c == 1 && p[0] == '.', up = c == 2 && p[0] == '.' && p[1] == '.';
      sl[n++] = (uint8_t)((cur ? 0x02 : 0) | (up ? 0x04 : 0)); // CURRENT, PARENT
      sl[n++] = cur || up ? 0 : (uint8_t)c;
      if (!cur && !up) memcpy(sl + n, p, c), n += c;
      p += c + (p[c] == '/');
    }
    iso_su_add(s, "SL", sl, n);
  }
}

// What of su fits a record with name_len bytes of name, and the rest: into
// ce (the directory's continuation area, ce_at bytes used, at ce_lba), with
// a CE entry pointing at it.
static size_t iso_su_place(const iso_su *s, size_t name_len, uint8_t out[255], uint8_t *ce, uint32_t *ce_at,
                           uint32_t ce_lba) {
  size_t room = 255 - (33 + name_len + !(name_len & 1)) - 1, used = 0;
  int i = 0;
  for (size_t start = 0; i < s->n; start = s->ends[i++]) {
    size_t len = s->ends[i] - start;
    if (used + len + (i + 1 < s->n ? 28 : 0) > room) break;
    memcpy(out + used, s->buf + start, len);
    used += len;
  }
  if (i == s->n) return used;
  size_t from = i ? s->ends[i - 1] : 0, rest = s->len - from;
  if (rest > ISO_SECTOR) die("an ISO entry's continuation is too long");
  if (*ce_at % ISO_SECTOR + rest > ISO_SECTOR) *ce_at = (*ce_at + ISO_SECTOR - 1) / ISO_SECTOR * ISO_SECTOR;
  if (ce) memcpy(ce + *ce_at, s->buf + from, rest);
  uint8_t *c = out + used;
  c[0] = 'C', c[1] = 'E', c[2] = 28, c[3] = 1;
  iso_both32(c + 4, ce_lba + *ce_at / ISO_SECTOR);
  iso_both32(c + 12, *ce_at % ISO_SECTOR);
  iso_both32(c + 20, (uint32_t)rest);
  *ce_at += (uint32_t)rest;
  return used + 28;
}

// The extent and size each kid's record names.
typedef struct iso_where {
  const iso_dir *dirs;
  const iso_file *files;
  const uint32_t *file_lba;
  uint32_t catalog, boot_lba, boot_len;
} iso_where;

// A directory's records for tree t (0: ISO 9660 with Rock Ridge, 1:
// Joliet) into d (nullptr: only measured); its size, a whole number of
// sectors. Rock Ridge's overflow goes to ce (nullptr: measured into
// dir->ce_size).
static uint32_t iso_dir_records(iso_dir *dirs, int i, int t, const iso_where *w, uint8_t *d, uint8_t *ce) {
  iso_dir *dir = &dirs[i];
  qsort(dir->kids, (size_t)dir->nkids, sizeof *dir->kids, t ? iso_by_joliet : iso_by_name);
  static uint8_t scratch[255];
  uint32_t ce_at = 0;
  size_t at = 0;
  for (int k = -2; k < dir->nkids; k++) {
    uint8_t name[128], su[255];
    size_t name_len, su_len = 0;
    uint32_t lba, size;
    bool isdir;
    iso_su s;
    if (k < 0) { // "." and ".."
      const iso_dir *x = k == -2 ? dir : &dirs[dir->parent];
      name[0] = k == -2 ? 0 : 1, name_len = 1, lba = x->lba[t], size = x->size[t], isdir = true;
      if (!t) iso_su_for(&s, i == 0 && k == -2, 040555, 2, nullptr, nullptr);
    } else {
      const iso_kid *kid = &dir->kids[k];
      if (t && kid->file >= 0 && w->files[kid->file].link) continue; // Joliet has no links
      if (t)
        memcpy(name, kid->joliet, kid->joliet_len), name_len = kid->joliet_len;
      else
        memcpy(name, kid->iso, strlen(kid->iso)), name_len = strlen(kid->iso);
      isdir = kid->dir >= 0;
      uint32_t mode = 0100444;
      if (isdir)
        lba = dirs[kid->dir].lba[t], size = dirs[kid->dir].size[t], mode = 040555;
      else if (kid->file == -2)
        lba = w->catalog, size = ISO_SECTOR;
      else if (kid->file == -3)
        lba = w->boot_lba, size = w->boot_len;
      else if (w->files[kid->file].link)
        lba = 0, size = 0, mode = 0120777;
      else
        lba = w->file_lba ? w->file_lba[kid->file] : 0, size = (uint32_t)w->files[kid->file].size;
      if (!t)
        iso_su_for(&s, false, mode, isdir ? 2 : 1, kid->name,
                   kid->file >= 0 ? w->files[kid->file].link : nullptr);
    }
    if (!t) su_len = iso_su_place(&s, name_len, su, ce, &ce_at, dir->ce_lba);
    size_t len = iso_record(scratch, lba, size, isdir, name, name_len, su, su_len);
    if (at % ISO_SECTOR + len > ISO_SECTOR) at = (at + ISO_SECTOR - 1) / ISO_SECTOR * ISO_SECTOR;
    if (d) memcpy(d + at, scratch, len);
    at += len;
  }
  if (!t && !ce) dir->ce_size = (ce_at + ISO_SECTOR - 1) / ISO_SECTOR * ISO_SECTOR;
  return (uint32_t)((at + ISO_SECTOR - 1) / ISO_SECTOR * ISO_SECTOR);
}

// A path table (little-endian, or big) for tree t; its size.
static size_t iso_path_table(const iso_dir *dirs, int ndirs, int t, bool big, uint8_t *p) {
  size_t size = 0;
  for (int i = 0; i < ndirs; i++) {
    uint8_t name[128];
    size_t nlen = 1;
    name[0] = 0;
    if (i) {
      const iso_kid *self = nullptr;
      for (int k = 0; k < dirs[dirs[i].parent].nkids && !self; k++)
        if (dirs[dirs[i].parent].kids[k].dir == i) self = &dirs[dirs[i].parent].kids[k];
      if (t)
        memcpy(name, self->joliet, self->joliet_len), nlen = self->joliet_len;
      else
        memcpy(name, self->iso, strlen(self->iso)), nlen = strlen(self->iso);
    }
    if (p) {
      uint8_t *e = p + size;
      uint32_t lba = dirs[i].lba[t];
      uint16_t parent = (uint16_t)(dirs[i].parent + 1);
      e[0] = (uint8_t)nlen, e[1] = 0;
      if (big) {
        e[2] = (uint8_t)(lba >> 24), e[3] = (uint8_t)(lba >> 16), e[4] = (uint8_t)(lba >> 8),
        e[5] = (uint8_t)lba;
        e[6] = (uint8_t)(parent >> 8), e[7] = (uint8_t)parent;
      } else {
        put32(e + 2, lba), put16(e + 6, parent);
      }
      memcpy(e + 8, name, nlen);
    }
    size += 8 + nlen + (nlen & 1);
  }
  return size;
}

static uint32_t iso_sectors(uint64_t bytes) { return (uint32_t)((bytes + ISO_SECTOR - 1) / ISO_SECTOR); }

static void iso_volume(uint8_t *v, int type, uint32_t total, size_t ptsize, uint32_t path_l, uint32_t path_m,
                       const iso_dir *top, int t) {
  v[0] = (uint8_t)type;
  iso_put(v + 1, "CD001");
  v[6] = 1;
  void (*text)(uint8_t *, size_t, const char *) = t ? iso_text16 : iso_text;
  text(v + 8, 32, "");
  text(v + 40, 32, "VECTRAOS");
  if (t) v[88] = '%', v[89] = '/', v[90] = 'E'; // Joliet, UCS-2 level 3
  iso_both32(v + 80, total);
  iso_both16(v + 120, 1);
  iso_both16(v + 124, 1);
  iso_both16(v + 128, ISO_SECTOR);
  iso_both32(v + 132, (uint32_t)ptsize);
  put32(v + 140, path_l);
  v[148] = (uint8_t)(path_m >> 24), v[149] = (uint8_t)(path_m >> 16), v[150] = (uint8_t)(path_m >> 8),
  v[151] = (uint8_t)path_m; // big-endian
  iso_record(v + 156, top->lba[t], top->size[t], true, (const uint8_t[]){0}, 1, nullptr, 0);
  text(v + 190, (size_t)128 * 4, "");
  text(v + 574, 128, "VECTRAOS BUILD");
  text(v + 702, (size_t)37 * 3, "");
  for (size_t d = 0; d < 4; d++) memset(v + 813 + 17 * d, '0', 16); // dates: none
  v[881] = 1;
}

static void write_iso(const char *path, const char *boot_image, iso_file *files, int count,
                      uint32_t disk_id) {
  // The directories: each file's, and theirs, by depth then path, so a
  // parent comes before its children (the path tables' order).
  static iso_dir dirs[ISO_MAX_DIRS];
  memset(dirs, 0, sizeof dirs);
  dirs[0].path = "";
  int ndirs = 1;
  for (int f = 0; f < count; f++)
    for (const char *p = files[f].path; (p = strchr(p, '/')); p++) {
      size_t len = (size_t)(p - files[f].path);
      if (iso_dir_index(dirs, ndirs, files[f].path, len) >= 0) continue;
      if (ndirs == ISO_MAX_DIRS) die("too many directories for the ISO");
      dirs[ndirs++] = (iso_dir){.path = fmt("%.*s", (int)len, files[f].path)};
    }
  for (int i = 1; i < ndirs; i++) // insertion sort: few directories
    for (int k = i; k > 1; k--) {
      int dk = iso_depth(dirs[k].path), dp = iso_depth(dirs[k - 1].path);
      if (dk > dp || (dk == dp && strcmp(dirs[k].path, dirs[k - 1].path) >= 0)) break;
      iso_dir t = dirs[k];
      dirs[k] = dirs[k - 1];
      dirs[k - 1] = t;
    }
  for (int i = 1; i < ndirs; i++) {
    const char *slash = strrchr(dirs[i].path, '/');
    dirs[i].parent = slash ? iso_dir_index(dirs, ndirs, dirs[i].path, (size_t)(slash - dirs[i].path)) : 0;
  }

  // Each directory's kids, their names made three ways.
  for (int i = 0; i < ndirs; i++) {
    dirs[i].kids = alloc(ISO_MAX_KIDS * sizeof *dirs[i].kids);
    size_t plen = strlen(dirs[i].path);
    for (int k = 1; k < ndirs + count + 2; k++) {
      iso_kid kid = {.dir = -1, .file = -1};
      if (k < ndirs) {
        if (dirs[k].parent != i) continue;
        kid.name = dirs[k].path + (plen ? plen + 1 : 0), kid.dir = k;
      } else if (k < ndirs + count) {
        int f = k - ndirs;
        const char *slash = strrchr(files[f].path, '/');
        size_t dlen = slash ? (size_t)(slash - files[f].path) : 0;
        if (dlen != plen || memcmp(files[f].path, dirs[i].path, plen) != 0) continue;
        kid.name = slash ? slash + 1 : files[f].path, kid.file = f;
      } else { // the boot pieces, in the root
        if (i) continue;
        bool cat = k == ndirs + count;
        kid.name = cat ? "boot.catalog" : "efiboot.img", kid.file = cat ? -2 : -3;
      }
      if (dirs[i].nkids == ISO_MAX_KIDS) die("too many entries in an ISO directory");
      iso_mangle(kid.name, kid.dir < 0, dirs[i].kids, dirs[i].nkids, kid.iso);
      kid.joliet_len = iso_joliet(kid.name, kid.joliet);
      dirs[i].kids[dirs[i].nkids++] = kid;
    }
  }

  // Sizes, then the layout: descriptors (El Torito's at 17), path tables,
  // directories, continuation areas, the boot catalog, the boot image, the files.
  struct stat st;
  if (stat(boot_image, &st) != 0) die("cannot stat %s", boot_image);
  uint32_t boot_len = (uint32_t)st.st_size;
  for (int f = 0; f < count; f++) {
    if (files[f].link) continue;
    if (stat(files[f].from, &st) != 0) die("cannot stat %s", files[f].from);
    files[f].size = (uint64_t)st.st_size;
  }
  iso_where w = {.dirs = dirs, .files = files, .boot_len = boot_len};
  for (int t = 0; t < 2; t++)
    for (int i = 0; i < ndirs; i++) dirs[i].size[t] = iso_dir_records(dirs, i, t, &w, nullptr, nullptr);
  enum : uint32_t { PVD = 16, BOOT_RECORD, SVD, TERMINATOR, PATHS };
  size_t ptsize[2] = {iso_path_table(dirs, ndirs, 0, false, nullptr),
                      iso_path_table(dirs, ndirs, 1, false, nullptr)};
  uint32_t lba = PATHS, path_lba[2][2];
  for (int t = 0; t < 2; t++)
    for (int b = 0; b < 2; b++) path_lba[t][b] = lba, lba += iso_sectors(ptsize[t]);
  for (int t = 0; t < 2; t++)
    for (int i = 0; i < ndirs; i++) dirs[i].lba[t] = lba, lba += dirs[i].size[t] / ISO_SECTOR;
  for (int i = 0; i < ndirs; i++) dirs[i].ce_lba = lba, lba += dirs[i].ce_size / ISO_SECTOR;
  w.catalog = lba++, w.boot_lba = lba;
  lba += iso_sectors(boot_len);
  uint32_t *file_lba = alloc((size_t)count * sizeof *file_lba);
  for (int f = 0; f < count; f++) {
    file_lba[f] = files[f].link ? 0 : lba;
    lba += files[f].link ? 0 : iso_sectors(files[f].size);
  }
  w.file_lba = file_lba;
  uint32_t total = lba;
  uint8_t *img = alloc((size_t)w.boot_lba * ISO_SECTOR); // the metadata; the rest is written in place
  memset(img, 0, (size_t)w.boot_lba * ISO_SECTOR);

  for (int t = 0; t < 2; t++) {
    iso_path_table(dirs, ndirs, t, false, img + (size_t)path_lba[t][0] * ISO_SECTOR);
    iso_path_table(dirs, ndirs, t, true, img + (size_t)path_lba[t][1] * ISO_SECTOR);
    for (int i = 0; i < ndirs; i++)
      iso_dir_records(dirs, i, t, &w, img + (size_t)dirs[i].lba[t] * ISO_SECTOR,
                      t ? nullptr : img + (size_t)dirs[i].ce_lba * ISO_SECTOR);
  }
  iso_volume(img + (size_t)PVD * ISO_SECTOR, 1, total, ptsize[0], path_lba[0][0], path_lba[0][1], &dirs[0],
             0);
  iso_volume(img + (size_t)SVD * ISO_SECTOR, 2, total, ptsize[1], path_lba[1][0], path_lba[1][1], &dirs[0],
             1);

  uint8_t *br = img + (size_t)BOOT_RECORD * ISO_SECTOR; // El Torito's boot record
  iso_put(br + 1, "CD001");
  br[6] = 1;
  iso_put(br + 7, "EL TORITO SPECIFICATION");
  put32(br + 71, w.catalog);

  uint8_t *term = img + (size_t)TERMINATOR * ISO_SECTOR;
  term[0] = 255;
  iso_put(term + 1, "CD001");
  term[6] = 1;

  uint8_t *cat = img + (size_t)w.catalog * ISO_SECTOR;
  cat[0] = 1;    // the validation entry
  cat[1] = 0xef; // EFI
  cat[30] = 0x55, cat[31] = 0xaa;
  uint16_t sum = 0;
  for (int i = 0; i < 32; i += 2) sum = (uint16_t)(sum + (cat[i] | cat[i + 1] << 8));
  put16(cat + 28, (uint16_t)-sum); // the words sum to 0
  cat[32] = 0x88;                  // bootable, no emulation
  uint64_t count512 = ((uint64_t)boot_len + 511) / 512;
  if (count512 > 0xffff) die("the ISO's boot image is too big for its catalog entry");
  put16(cat + 38, (uint16_t)count512);
  put32(cat + 40, w.boot_lba);

  // The MBR: one partition, the boot image, in 512-byte sectors.
  put32(img + 0x1b8, disk_id);
  uint8_t *pe = img + 446;
  pe[4] = 0xef;
  put32(pe + 8, w.boot_lba * (ISO_SECTOR / 512));
  put32(pe + 12, (uint32_t)count512);
  img[510] = 0x55, img[511] = 0xaa;

  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || ftruncate(fd, (off_t)total * ISO_SECTOR) != 0) die("cannot create %s", path);
  pwrite_all(fd, img, (size_t)w.boot_lba * ISO_SECTOR, 0, path);
  copy_into(fd, path, boot_image, (uint64_t)w.boot_lba * ISO_SECTOR);
  for (int f = 0; f < count; f++)
    if (!files[f].link) copy_into(fd, path, files[f].from, (uint64_t)file_lba[f] * ISO_SECTOR);
  if (close(fd) != 0) die("cannot write %s", path);
}

static void make_test_iso(const char *path); // the isofs tests' ISO, made by write_iso
static bool build_vxstore(void);             // host/vxstore, for releases and install media
static bool check_man(void);                 // the manual's pass, which writes the index the image holds
static const char VXSTORE[] = "out/host/vxstore";
static vx_str str_of(const char *s) { return (vx_str){s, strlen(s)}; }
static constexpr int VX_STORE_HEX_LEN = 67; // "b2:" and 64 hex: lib/vx-store's names

static const char *out_dir(const arch *a, bool release) {
  return fmt("out/%s/%s", a->name, release ? "release" : "debug");
}

static const char *image_path(const arch *a, bool release) {
  return fmt("%s/vectra-%s.img", out_dir(a, release), a->name);
}

static bool mtools(const char *tool, const char *esp, const char *const *args) {
  cmd c = {};
  cmd_add(&c, tool);
  cmd_add(&c, "-i");
  cmd_add(&c, esp);
  cmd_addv(&c, args);
  return run(&c);
}

// The directories every boot image has: mount points for the namespace (02 §5;
// /src, where dbg finds sources, 05 §4, a test image binding its own there)
// and bootfs's own. In order, parents first.
static constexpr int BOOTFS_MAX_FILES = 512;
static const char *const BOOTFS_DIRS[] = {"adm",
                                          "bin",
                                          "boot",
                                          "boot/bin",
                                          "boot/bin/posix",
                                          "boot/share",
                                          "boot/share/misc",
                                          "boot/drv",
                                          "boot/svc",
                                          "boot/tests",

                                          "cfg",
                                          "dev",
                                          "dist",
                                          "home",
                                          "lib",
                                          "lib/ns",
                                          "lib/font",
                                          "lib/wm",
                                          "lib/plumb",
                                          "mnt",
                                          "mnt/plumb",
                                          "n",
                                          "net",
                                          "proc",
                                          "src",
                                          "srv",
                                          "sys",
                                          "tmp",
                                          "wsys",
                                          "wsys/outputs"};

// Whether `name` is in the comma-separated list `with`.
static bool listed(const char *with, const char *name) {
  size_t n = strlen(name);
  for (const char *p = with; *p;) {
    const char *end = strchr(p, ',');
    size_t len = end ? (size_t)(end - p) : strlen(p);
    if (len == n && memcmp(p, name, n) == 0) return true;
    p += len + (end != nullptr);
  }
  return false;
}

// mkbootfs (04 §3.4): packs the boot image's tree into a ustar archive, the
// bootfs.tar module. The directories, boot/bin with each program that lives
// in bootfs, boot/svc with the service manifests from boot/svc/*.ndb,
// boot/drv with the driver manifests from boot/drv/*.ndb, lib/ns with the
// namespace templates, namespace(6) files, from boot/lib/ns/ (ADR-0009),
// lib/wm with the window manager's Lua and keys from boot/lib/wm/, lib/plumb
// with the plumber's rules from boot/lib/plumb/ (7g3b), and
// lib/font with the system's fonts, Inter's (ADR-0054).
// `with` adds test programs and their manifests (tests/user/NAME.ndb), and
// script tests (a manifest, and tests/user/NAME.lua in boot/tests). The
// archive is deterministic: fixed order, no times or owners.
// A slot for one more file in the image: more than it holds is an error,
// never a file left out (a test's manifest missing shows only as a timeout).
static void bootfs_room(int count) {
  if (count >= BOOTFS_MAX_FILES) die("bootfs: more than %d files; raise BOOTFS_MAX_FILES", BOOTFS_MAX_FILES);
}

static bool make_bootfs(const arch *a, bool release, const char *with, const char *out) {
  static file_list manifests;
  manifests = (file_list){};
  port tree = {.src = root};
  collect(&manifests, &tree, (vx_str){"boot/svc", 8}, ".ndb");
  collect(&manifests, &tree, (vx_str){"boot/drv", 8}, ".ndb");
  collect(&manifests, &tree, (vx_str){"boot/lib/ns", 11}, "");
  collect(&manifests, &tree, (vx_str){"boot/lib/wm", 11},
          ""); // the window manager, wm.lua and its keys (7d2c)
  collect(&manifests, &tree, (vx_str){"boot/lib/plumb", 14}, ""); // the plumber's rules (7g3b)

  // Programs, then the system's manifests, then the tests': svcd starts
  // services in this order, so a test's run after what it tests.
  static vx_str files[BOOTFS_MAX_FILES];
  static const char *paths[BOOTFS_MAX_FILES];
  static const char *links[BOOTFS_MAX_FILES]; // a hard link's target, for a box's names
  memset(links, 0, sizeof links);
  int count = 0;
  size_t total = 0;
  for (int i = 0; i < USER_PROGRAM_COUNT; i++) {
    const program *p = &USER_PROGRAMS[i];
    if (p->where == IN_MODULE || (p->where == IN_TESTS && !listed(with, p->name)) || !program_for(p, a))
      continue;
    if (p->native && !exists(fmt("%s/%s", out_dir(a, release), p->name)))
      die("%s needs the native target's sysroot, which needs llvm-libc (lib/vx-rt/sysroot/llvm-libc.ndb)",
          p->name);
    bootfs_room(count);
    files[count] = read_file(fmt("%s/%s", out_dir(a, release), p->name));
    paths[count++] = bootfs_path(p);
  }
  bool swift = !*with; // the whole system ships the Swift runtime; a test's image when it runs Swift
  for (size_t i = 0; i < sizeof EXTERNAL_LIBRARIES / sizeof EXTERNAL_LIBRARIES[0]; i++) {
    if (!listed(with, EXTERNAL_LIBRARIES[i][0])) continue;
    const char *from =
        fmt("%s/tests/out/%s/%s", swift_on_vectra(), sysroot_triple(a), EXTERNAL_LIBRARIES[i][1]);
    if (!exists(from)) die("%s: not built; run swift-on-vectra's tests/build.sh", from);
    bootfs_room(count);
    files[count] = read_file(from);
    paths[count++] = fmt("lib/%s", EXTERNAL_LIBRARIES[i][0]);
  }
  for (int i = 0; i < EXTERNAL_PROGRAM_COUNT; i++) { // built in swift-on-vectra's tree
    const char *name = EXTERNAL_PROGRAMS[i];
    if (!listed(with, name)) continue;
    swift = true;
    const char *from = fmt("%s/tests/out/%s/%s", swift_on_vectra(), sysroot_triple(a), name);
    if (!exists(from)) die("%s: not built; run swift-on-vectra's tests/build.sh", from);
    bootfs_room(count);
    files[count] = read_file(from);
    paths[count++] = fmt("boot/bin/%s", name);
    if (exists(fmt("tests/user/%s.ndb", name))) {
      bootfs_room(count);
      files[count] = read_file(fmt("tests/user/%s.ndb", name));
      paths[count++] = fmt("boot/svc/%s.ndb", name);
    }
  }
  // The Swift runtime and FoundationEssentials, the system's shared
  // libraries (6f3a, ADR-0048): from swift-on-vectra's SDK until ADR-0034's
  // first gate brings the toolchain here, when it has been built.
  const char *swift_lib =
      fmt("%s/toolchain/out/sdk/%s/usr/lib/swift/vectraos", swift_on_vectra(), sysroot_triple(a));
  for (size_t i = 0; swift && i < sizeof SWIFT_LIBRARIES / sizeof SWIFT_LIBRARIES[0]; i++) {
    const char *so = fmt("%s/%s", swift_lib, SWIFT_LIBRARIES[i]);
    if (!exists(so)) {
      if (*with)
        die("%s: not built; run swift-on-vectra's toolchain/build_stdlib.sh and build_foundation.sh", so);
      break; // no Swift toolchain here: a system without it
    }
    bootfs_room(count);
    files[count] = read_file(so);
    paths[count++] = fmt("lib/%s", SWIFT_LIBRARIES[i]);
  }
  // libc.so, musl's, the interpreter of dynamic POSIX programs (6f1b2).
  const char *musl_so = fmt("%s/libc.so", vectra_musl_lib(a, release));
  if (exists(musl_so)) {
    bootfs_room(count);
    files[count] = read_file(musl_so);
    paths[count++] = fmt("lib/ld-musl-%s.so.1", a->name);
  }
  // The native C and C++ libraries, shared (6f1c1, 6f1c2, 6f2a), by their sonames.
  static const char *const NATIVE_LIBS[][2] = {{"libc.so", "lib/libc.so"},
                                               {"libc++.so", "lib/libc++.so.1"},
                                               {"libc++abi.so", "lib/libc++abi.so.1"},
                                               {"libunwind.so", "lib/libunwind.so.1"}};
  for (size_t i = 0; i < sizeof NATIVE_LIBS / sizeof NATIVE_LIBS[0]; i++) {
    const char *so = fmt("%s/usr/lib/%s", sysroot_dir(a, release), NATIVE_LIBS[i][0]);
    if (!exists(so)) continue;
    bootfs_room(count);
    files[count] = read_file(so);
    paths[count++] = NATIVE_LIBS[i][1];
  }
  // libvx.so, which native programs link dynamically (6f1b1, ADR-0047), when
  // this architecture has the native target's sysroot: by its soname,
  // libvx.so.1 since level 1's freeze (6e4f), which programs name.
  const char *libvx_so = fmt("%s/usr/lib/libvx.so", sysroot_dir(a, release));
  if (exists(libvx_so)) {
    bootfs_room(count);
    files[count] = read_file(libvx_so);
    paths[count++] = "lib/libvx.so.1";
  }
  for (int k = 0; k < POSIX_PORT_COUNT; k++) { // vendored POSIX programs: each, or a box and its names
    const port *p = POSIX_PORTS[k];
    const char *sub = port_bin_dir(p), *box = nullptr;
    if (vx_ndb_get(&p->head, "box").len) {
      box = fmt("boot/bin/%s%s", sub, str_dup(vx_ndb_get(&p->head, "box")));
      bootfs_room(count);
      files[count] = read_file(fmt("%s/%s%s", out_dir(a, release), sub, box + 9 + strlen(sub)));
      paths[count++] = box;
    }
    int names = p->program_count + (words_has(vx_ndb_get(&p->head, "box.alias"), "[") ? 1 : 0);
    for (int i = 0; i < names; i++) {
      const char *name = i < p->program_count ? str_dup(vx_ndb_get(&p->programs[i], "program")) : "[";
      bootfs_room(count);
      paths[count] = fmt("boot/bin/%s%s", sub, name);
      if (box && (i == p->program_count || !program_alone(&p->programs[i]))) {
        files[count] = (vx_str){};
        links[count++] = box;
      } else {
        files[count++] = read_file(fmt("%s/%s%s", out_dir(a, release), sub, name));
      }
    }
  }
  for (int k = 0; k < POSIX_PORT_COUNT; k++) { // install=FROM:TO, a file of the tree at /boot/TO
    vx_str in = vx_ndb_get(&POSIX_PORTS[k]->head, "install");
    for (size_t i = 0; i < in.len;) {
      size_t start = i, colon = 0;
      while (i < in.len && in.ptr[i] != ' ') colon = in.ptr[i] == ':' ? i : colon, i++;
      if (colon > start) {
        bootfs_room(count);
        files[count] =
            read_file(fmt("%s/%s", POSIX_PORTS[k]->src, str_dup((vx_str){in.ptr + start, colon - start})));
        paths[count++] = fmt("boot/%s", str_dup((vx_str){in.ptr + colon + 1, i - colon - 1}));
      }
      i++;
    }
  }
  // The manual (12 §5): every page at /lib/man/<sect>/<page>, and the index
  // the manual's pass writes, out/man/index/base, at /lib/man/index/base.
  check_man();
  for (int sect = 1; sect <= 8; sect++) {
    DIR *d = opendir(fmt("man/%d", sect));
    for (struct dirent *e; d && (e = readdir(d));) {
      if (e->d_name[0] == '.') continue;
      bootfs_room(count);
      files[count] = read_file(fmt("man/%d/%s", sect, e->d_name));
      paths[count++] = fmt("lib/man/%d/%s", sect, e->d_name);
    }
    if (d) closedir(d);
  }
  bootfs_room(count);
  files[count] = read_file("out/man/index/base");
  paths[count++] = "lib/man/index/base";
  bootfs_room(count); // rc's start, as 9front's (M6 step 6a6b)
  files[count] = read_file("boot/rc/lib/rcmain");
  paths[count++] = "rc/lib/rcmain";
  for (int i = 0; i < manifests.count; i++) {
    bootfs_room(count);
    files[count] = read_file(manifests.paths[i]);
    const char *path = manifests.paths[i]; // boot/lib/ns/NAME is /lib/ns/NAME in the image
    paths[count++] = strncmp(path, "boot/lib/", 9) == 0 ? path + 5 : path;
  }
  // The system's fonts, from the vendored Inter (ADR-0054), at /lib/font.
  static const char *const FONTS[] = {"Inter-Regular.ttf", "Inter-Bold.ttf"};
  for (size_t i = 0; i < sizeof FONTS / sizeof FONTS[0]; i++) {
    bootfs_room(count);
    files[count] = read_file(fmt("third_party/inter/extras/ttf/%s", FONTS[i]));
    paths[count++] = fmt("lib/font/%s", FONTS[i]);
  }
  static const char *const MONO[] = {"JetBrainsMono-Regular.ttf", "JetBrainsMono-Bold.ttf"}; // the terminal's
  for (size_t i = 0; i < sizeof MONO / sizeof MONO[0]; i++) {
    bootfs_room(count);
    files[count] = read_file(fmt("third_party/jetbrains_mono/fonts/ttf/%s", MONO[i]));
    paths[count++] = fmt("lib/font/%s", MONO[i]);
  }
  for (int i = 0; i < USER_PROGRAM_COUNT; i++) {
    if (USER_PROGRAMS[i].where != IN_TESTS || !listed(with, USER_PROGRAMS[i].name)) continue;
    if (exists(fmt("tests/user/%s.ndb", USER_PROGRAMS[i].name))) { // none: another test runs it
      bootfs_room(count);
      files[count] = read_file(fmt("tests/user/%s.ndb", USER_PROGRAMS[i].name));
      paths[count++] = fmt("boot/svc/%s.ndb", USER_PROGRAMS[i].name);
    }
    if (exists(fmt("tests/user/%s.cmds", USER_PROGRAMS[i].name))) { // a dbg script
      bootfs_room(count);
      files[count] = read_file(fmt("tests/user/%s.cmds", USER_PROGRAMS[i].name));
      paths[count++] = fmt("boot/tests/%s.cmds", USER_PROGRAMS[i].name);
    }
    // Its source, at the path its debug information names under /src (the
    // file prefix map's), for dbg's window to show (7g1b3).
    bootfs_room(count);
    files[count] = read_file(USER_PROGRAMS[i].source);
    paths[count++] = fmt("boot/src/%s", USER_PROGRAMS[i].source);
  }
  // A `with` name that is no program is a script test: its manifest runs a
  // program the image has (lua, rc, dbg), on tests/user/NAME.lua, NAME.rc or
  // NAME.cmds, at /boot/tests.
  for (const char *n = with; *n;) {
    const char *end = strchr(n, ',');
    const char *name = str_dup((vx_str){n, end ? (size_t)(end - n) : strlen(n)});
    n += strlen(name) + (end != nullptr);
    bool program = external_program(name);
    for (int i = 0; i < USER_PROGRAM_COUNT; i++)
      program = program || strcmp(USER_PROGRAMS[i].name, name) == 0;
    if (program) continue;
    bootfs_room(count);
    files[count] = read_file(fmt("tests/user/%s.ndb", name));
    paths[count++] = fmt("boot/svc/%s.ndb", name);
    static const char *const exts[] = {"lua", "rc", "cmds"}; // a Lua or an rc script, or dbg's
    for (int k = 0; k < 3; k++) {
      const char *ext = exts[k];
      if (!exists(fmt("tests/user/%s.%s", name, ext))) continue;
      bootfs_room(count);
      files[count] = read_file(fmt("tests/user/%s.%s", name, ext));
      paths[count++] = fmt("boot/tests/%s.%s", name, ext);
    }
  }
  for (int i = 0; i < count; i++) total += files[i].len + 2 * VX_TAR_BLOCK;

  vx_tar_writer w = {.cap = total + (sizeof BOOTFS_DIRS / sizeof BOOTFS_DIRS[0] + 2) * VX_TAR_BLOCK};
  w.buf = alloc(w.cap);
  for (size_t i = 0; i < sizeof BOOTFS_DIRS / sizeof BOOTFS_DIRS[0]; i++)
    vx_tar_add(&w, (vx_str){BOOTFS_DIRS[i], strlen(BOOTFS_DIRS[i])}, true, 0755, nullptr, 0);
  for (int i = 0; i < count; i++) {
    bool program = strncmp(paths[i], "boot/bin/", 9) == 0;
    if (links[i])
      vx_tar_add_link(&w, (vx_str){paths[i], strlen(paths[i])}, (vx_str){links[i], strlen(links[i])}, 0755);
    else
      vx_tar_add(&w, (vx_str){paths[i], strlen(paths[i])}, false, program ? 0755 : 0644, files[i].ptr,
                 files[i].len);
  }
  size_t len = vx_tar_end(&w);
  if (!len) die("cannot pack %s", out);
  write_file(out, (vx_str){(const char *)w.buf, len});
  return true;
}

// Writes a disk image for an architecture whose kernel and loader are built.
// A non-empty cmdline is added to the boot entry, and `with` names test
// programs for bootfs, for test scenarios.
static bool make_image_in(const arch *a, bool release, const char *image, const char *cmdline,
                          const char *with, const char *iso);

// Everything an image takes from the arena (each file it reads, the boot
// image's archive) is given back once it is written: each scenario's process
// makes one, after the image its parent made, all in one arena.
// An install medium's store (06 §8, M5 step 9c): this image's own boot files
// and bootfs as a release's base tree (so the installed system is the one
// tested, its test services included), put in a store beside the image with
// a release record, as store.tar. Its path, or nullptr.
static bool iso_installer; // the next ISO make_image makes carries store.tar

// A file copied, a chunk at a time (not through the arena: install media copy
// bootfs more than once).
static void copy_file(const char *from, const char *to) {
  int in = open(from, O_RDONLY), out = open(to, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (in < 0 || out < 0) die("cannot copy %s to %s", from, to);
  static char chunk[1 << 20];
  for (ssize_t n; (n = read(in, chunk, sizeof chunk)) != 0;) {
    if (n < 0 || write(out, chunk, (size_t)n) != n) die("cannot copy %s to %s", from, to);
  }
  close(in);
  if (close(out) != 0) die("cannot write %s", to);
}

static bool iso_media;              // and a second release, release 2, as local media (media)
static const char *iso_media_store; // that release's store directory, once made

static const char *make_install_store(const arch *a, bool release, const char *image, const char *loader,
                                      const char *loader_name, const char *kernel, const char *bootfs,
                                      uint64_t seq) {
  if (!build_vxstore()) return nullptr;
  const char *top = fmt("%s.release%llu", image, (unsigned long long)seq), *rootdir = fmt("%s/root", top),
             *store = fmt("%s/store", top);
  cmd rm = {};
  cmd_addv(&rm, (const char *const[]){"/usr/bin/rm", "-rf", top, nullptr});
  if (!run(&rm)) return nullptr;
  mkdirs(fmt("%s/boot/vx", rootdir));
  mkdirs(fmt("%s/boot/limine", rootdir));
  mkdirs(store);
  copy_file(loader, fmt("%s/boot/limine/%s", rootdir, loader_name));
  copy_file("boot/limine.conf", fmt("%s/boot/limine/limine.conf", rootdir));
  copy_file(kernel, fmt("%s/boot/vx/kernel.elf", rootdir));
  copy_file(bootfs, fmt("%s/boot/vx/bootfs.tar", rootdir));
  for (int i = 0; i < USER_PROGRAM_COUNT; i++)
    if (USER_PROGRAMS[i].where == IN_MODULE)
      copy_file(fmt("%s/%s", out_dir(a, release), USER_PROGRAMS[i].name),
                fmt("%s/boot/vx/%s", rootdir, USER_PROGRAMS[i].name));
  char *out = run_capture((const char *const[]){VXSTORE, "put", store, rootdir, bootfs, nullptr});
  if (!out || !strchr(out, ' ')) return nullptr;
  *strchr(out, ' ') = 0;
  unsigned long long n = (unsigned long long)seq;
  const char *record = fmt("%s/%llu.ndb", top, n);
  write_file(record, str_of(fmt("release=%llu name=test-%llu channel=dev commit=test vx-abi=0 unsigned\n"
                                "set=base arch=%s tree=%s\n",
                                n, n, a->name, out)));
  mkdirs(fmt("%s/records", store));
  write_file(fmt("%s/records/%llu.ndb", store, n), read_file(record));
  const char *tar = fmt("%s/store.tar", top);
  cmd t = {};
  cmd_addv(&t, (const char *const[]){VXSTORE, "tar", store, out, tar, fmt("records/%llu.ndb=%s", n, record),
                                     nullptr});
  if (seq != 1) iso_media_store = store;
  return run(&t) ? tar : nullptr;
}

static bool make_image(const arch *a, bool release, const char *image, const char *cmdline, const char *with,
                       const char *iso) {
  size_t mark = arena_used;
  bool ok = make_image_in(a, release, image, cmdline, with, iso);
  arena_used = mark;
  return ok;
}

// With iso, a CD image of the same system partition too (write_iso).
static bool make_image_in(const arch *a, bool release, const char *image, const char *cmdline,
                          const char *with, const char *iso) {
  const vx_ndb_record *t = port_target_for(&limine, a);
  if (!t) die("no Limine target for %s", a->name);
  const char *loader_name = str_dup(vx_ndb_get(t, "output"));
  const char *loader = fmt("out/limine/%s/%s", str_dup(vx_ndb_get(t, "target")), loader_name);
  const char *kernel = fmt("%s/kernel.elf", out_dir(a, release));
  const char *config = "boot/limine.conf";
  const char *esp = fmt("%s.esp", image);
  const char *bootfs = fmt("%s.bootfs.tar", image);
  if (!make_bootfs(a, release, with, bootfs)) return false;
  if (cmdline && *cmdline) {
    config = fmt("%s.conf", image);
    FILE *f = fopen(config, "w");
    if (!f) die("cannot write %s", config);
    fprintf(f, "%s    cmdline: %s\n", read_file("boot/limine.conf").ptr, cmdline);
    fclose(f);
  }

  // Everything that goes on the disk decides its GUIDs and FAT serial number.
  uint64_t seed = 0xcbf29ce484222325;
  seed = hash_bytes(seed, read_file(loader));
  seed = hash_bytes(seed, read_file(kernel));
  seed = hash_bytes(seed, read_file(config));
  seed = hash_bytes(seed, read_file(bootfs));
  for (int i = 0; i < USER_PROGRAM_COUNT; i++)
    if (USER_PROGRAMS[i].where == IN_MODULE)
      seed = hash_bytes(seed, read_file(fmt("%s/%s", out_dir(a, release), USER_PROGRAMS[i].name)));

  // Room for the files, a quarter more for FAT32's own and 4 MiB besides.
  uint64_t content = file_bytes(loader) + file_bytes(kernel) + file_bytes(config) + file_bytes(bootfs);
  for (int i = 0; i < USER_PROGRAM_COUNT; i++)
    if (USER_PROGRAMS[i].where == IN_MODULE)
      content += file_bytes(fmt("%s/%s", out_dir(a, release), USER_PROGRAMS[i].name));
  uint64_t step = 32ull << 20, need = content + content / 4 + (4ull << 20);
  esp_bytes = need <= ESP_MIN_BYTES ? ESP_MIN_BYTES : (need + step - 1) / step * step;

  int fd = open(esp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || ftruncate(fd, (off_t)esp_bytes) != 0) die("cannot create %s", esp);
  close(fd);

  fprintf(stderr, "  IMG   %s\n", image);
  const char *serial = fmt("%08x", (unsigned)(seed >> 32));
  if (!mtools(MFORMAT, esp, (const char *const[]){"-F", "-N", serial, "-v", "VECTRA", "::", nullptr}))
    return false;
  if (!mtools(
          MMD, esp,
          (const char *const[]){"::/EFI", "::/EFI/BOOT", "::/boot", "::/boot/vx", "::/boot/limine", nullptr}))
    return false;
  if (!mtools(MCOPY, esp, (const char *const[]){loader, fmt("::/EFI/BOOT/%s", loader_name), nullptr}))
    return false;
  if (!mtools(MCOPY, esp, (const char *const[]){kernel, "::/boot/vx/kernel.elf", nullptr})) return false;
  if (!mtools(MCOPY, esp, (const char *const[]){bootfs, "::/boot/vx/bootfs.tar", nullptr})) return false;
  for (int i = 0; i < USER_PROGRAM_COUNT; i++) { // the root task's candidates
    if (USER_PROGRAMS[i].where != IN_MODULE) continue;
    const char *program = fmt("%s/%s", out_dir(a, release), USER_PROGRAMS[i].name);
    if (!mtools(MCOPY, esp,
                (const char *const[]){program, fmt("::/boot/vx/%s", USER_PROGRAMS[i].name), nullptr}))
      return false;
  }
  if (!mtools(MCOPY, esp, (const char *const[]){config, "::/boot/limine/limine.conf", nullptr})) return false;
  write_gpt_disk(image, esp, seed);
  if (iso) { // the loader alone in a small FAT image; everything else in the ISO's own tree
    fprintf(stderr, "  ISO   %s\n", iso);
    const char *efiboot = fmt("%s.efiboot", image);
    int efd = open(efiboot, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (efd < 0 || ftruncate(efd, 4 << 20) != 0) die("cannot create %s", efiboot);
    close(efd);
    if (!mtools(MFORMAT, efiboot, (const char *const[]){"-N", serial, "-v", "VECTRA", "::", nullptr}) ||
        !mtools(MMD, efiboot, (const char *const[]){"::/EFI", "::/EFI/BOOT", nullptr}) ||
        !mtools(MCOPY, efiboot, (const char *const[]){loader, fmt("::/EFI/BOOT/%s", loader_name), nullptr}))
      return false;
    iso_file files[16];
    int nf = 0;
    const char *iso_config = config;
    if (iso_installer) { // an install medium: the release's objects too, and a command line that says so
      const char *store = make_install_store(a, release, image, loader, loader_name, kernel, bootfs, 1);
      if (!store) return false;
      if (iso_media) { // release 2: the same, and a marker in its bootfs (tests/user/release2.ndb)
        const char *bootfs2 = fmt("%s.bootfs2.tar", image);
        size_t mark = arena_used; // what bootfs2 takes in the arena is on disk after: let it go
        bool ok2 = make_bootfs(a, release, fmt("%s%srelease2", with, *with ? "," : ""), bootfs2) &&
                   make_install_store(a, release, image, loader, loader_name, kernel, bootfs2, 2);
        static char media_path[4096];
        snprintf(media_path, sizeof media_path, "%s", ok2 && iso_media_store ? iso_media_store : "");
        arena_used = mark;
        iso_media_store = media_path[0] ? media_path : nullptr;
        if (!ok2) return false;
      }
      files[nf++] = (iso_file){.path = "boot/vx/store.tar", .from = store};
      iso_config = fmt("%s.iso.conf", image);
      FILE *f = fopen(iso_config, "w");
      if (!f) die("cannot write %s", iso_config);
      fprintf(f, "%s    module_path: boot():/boot/vx/store.tar\n    cmdline: vx.live%s%s\n",
              read_file("boot/limine.conf").ptr, cmdline && *cmdline ? " " : "", cmdline ? cmdline : "");
      fclose(f);
    }
    files[nf++] = (iso_file){.path = "boot/vx/kernel.elf", .from = kernel};
    files[nf++] = (iso_file){.path = "boot/vx/bootfs.tar", .from = bootfs};
    files[nf++] = (iso_file){.path = "boot/limine/limine.conf", .from = iso_config};
    for (int i = 0; i < USER_PROGRAM_COUNT && nf < 16; i++)
      if (USER_PROGRAMS[i].where == IN_MODULE)
        files[nf++] = (iso_file){.path = fmt("boot/vx/%s", USER_PROGRAMS[i].name),
                                 .from = fmt("%s/%s", out_dir(a, release), USER_PROGRAMS[i].name)};
    write_iso(iso, efiboot, files, nf, (uint32_t)seed);
    unlink(efiboot);
  }
  unlink(esp);
  unlink(bootfs);
  return true;
}

static bool want_iso; // image --iso

static bool build_image(const arch *a, bool release) {
  const char *iso = want_iso ? fmt("%s/vectra-%s.iso", out_dir(a, release), a->name) : nullptr;
  return build_arch(a, release) && make_image(a, release, image_path(a, release), nullptr, "", iso);
}

// --- Releases (docs/06 §3.1, §4; M5 step 9a) ---

// host/vxstore, built for this machine, with lib/vx-store and Monocypher
// (its own objects, no sanitizers, as host/vxfs is built). Rebuilt when a
// source changes.

static bool build_vxstore(void) {
  static const char *const SOURCES[] = {"host/vxstore/main.c",
                                        "lib/vx-store/store.c",
                                        "lib/vx-tar/tar.c",
                                        "lib/vx-ndb/ndb.c",
                                        "third_party/monocypher/src/monocypher.c",
                                        "third_party/monocypher/src/optional/monocypher-ed25519.c"};
  struct stat out, src;
  bool stale = stat(VXSTORE, &out) != 0;
  for (size_t i = 0; !stale && i < sizeof SOURCES / sizeof SOURCES[0]; i++)
    stale = stat(SOURCES[i], &src) != 0 || newer(&src, &out);
  if (!stale) return true;
  mkdirs("out/host");
  fprintf(stderr, "  CC    vxstore host\n");
  const char *objs[2] = {"out/host/vxstore-monocypher.o", "out/host/vxstore-monocypher-ed25519.o"};
  for (int i = 0; i < 2; i++) {
    cmd mc = {};
    cmd_addv(&mc, (const char *const[]){CLANG, "-std=c99", "-O2", "-w", "-Ithird_party/monocypher/src", "-c",
                                        "-o", objs[i], SOURCES[4 + i], nullptr});
    if (!run(&mc)) return false;
  }
  cmd cc = {};
  cmd_add(&cc, CLANG);
  cmd_addv(&cc, (const char *const[]){"-std=c23", "-O2", "-g", "-Wall", "-Wextra", "-Werror", "-isystem",
                                      "third_party/monocypher/src", "-isystem",
                                      "third_party/monocypher/src/optional", "-o", VXSTORE,
                                      "host/vxstore/main.c", objs[0], objs[1], nullptr});
  return run(&cc);
}

// An architecture's base tree (06 §3.1): what a boot slot holds (the
// kernel, bootfs.tar, the root task's modules, Limine's loader and
// configuration) under boot/, and bootfs's own files beside them, which
// distd serves. Put into the store; its hash, and the bytes under it.
static bool release_tree(const arch *a, const char *store, char tree[VX_STORE_HEX_LEN + 1], uint64_t *bytes) {
  if (!build_arch(a, true)) return false;
  const char *top = fmt("out/release/%s", a->name), *rootdir = fmt("%s/root", top);
  cmd rm = {};
  cmd_addv(&rm, (const char *const[]){"/usr/bin/rm", "-rf", rootdir, nullptr});
  if (!run(&rm)) return false;
  mkdirs(fmt("%s/boot/vx", rootdir));
  mkdirs(fmt("%s/boot/limine", rootdir));
  const char *bootfs = fmt("%s/boot/vx/bootfs.tar", rootdir);
  if (!make_bootfs(a, true, "", bootfs)) return false;
  const vx_ndb_record *t = port_target_for(&limine, a);
  if (!t) die("no Limine target for %s", a->name);
  const char *loader_name = str_dup(vx_ndb_get(t, "output"));
  write_file(fmt("%s/boot/limine/%s", rootdir, loader_name),
             read_file(fmt("out/limine/%s/%s", str_dup(vx_ndb_get(t, "target")), loader_name)));
  write_file(fmt("%s/boot/limine/limine.conf", rootdir), read_file("boot/limine.conf"));
  write_file(fmt("%s/boot/vx/kernel.elf", rootdir), read_file(fmt("%s/kernel.elf", out_dir(a, true))));
  for (int i = 0; i < USER_PROGRAM_COUNT; i++)
    if (USER_PROGRAMS[i].where == IN_MODULE) {
      const char *to = fmt("%s/boot/vx/%s", rootdir, USER_PROGRAMS[i].name);
      write_file(to, read_file(fmt("%s/%s", out_dir(a, true), USER_PROGRAMS[i].name)));
      chmod(to, 0755);
    }
  chmod(fmt("%s/boot/vx/kernel.elf", rootdir), 0755);
  char *out = run_capture((const char *const[]){VXSTORE, "put", store, rootdir, bootfs, nullptr});
  // "b2:<64 hex> BYTES"
  char *space = out ? strchr(out, ' ') : nullptr;
  if (!space || space - out != VX_STORE_HEX_LEN) return false;
  memcpy(tree, out, VX_STORE_HEX_LEN);
  tree[VX_STORE_HEX_LEN] = 0;
  char *end;
  *bytes = strtoull(space + 1, &end, 10);
  if (end == space + 1) return false;
  cmd tar = {};
  cmd_addv(&tar, (const char *const[]){VXSTORE, "tar", store, tree, fmt("out/release/store-%s.tar", a->name),
                                       nullptr});
  return run(&tar);
}

// The shipped Swift libraries' modules (ADR-0048), as swift-api-digester
// names them.
static const char *const SWIFT_ABI_MODULES[] = {
    "Swift",        "_Concurrency", "Synchronization", "_StringProcessing",   "_RegexParser",
    "RegexBuilder", "Observation",  "VectraOSLibc",    "FoundationEssentials"};

// The Swift libraries' ABI for a release (6f3d, ADR-0048 item 4): each
// module's swift-api-digester dump, in out/release/swift-abi/ARCH, and the
// dumps' hash in *hash; against the baselines in abi/swift/TRIPLE, if the
// tree has them (from the freeze on), each module's ABI changes reported, in
// out/release/swift-abi/ARCH-changes.
// A break fails the release once the ABI is frozen (VX_ABI_LEVEL >= 1).
// False with nothing to dump: no Swift toolchain here.
static bool release_swift_abi(const arch *a, char hash[65], bool *broken) {
  const char *tc = fmt("%s/toolchain/out", swift_on_vectra()), *triple = sysroot_triple(a);
  const char *dig = fmt("%s/bin/swift-api-digester", tc), *sdk = fmt("%s/sdk/%s", tc, triple);
  if (!exists(dig) || !exists(fmt("%s/usr/lib/swift/vectraos/libswiftCore.so", sdk))) return false;
  const char *dir = fmt("out/release/swift-abi/%s", a->name), *base = fmt("abi/swift/%s", triple);
  const char *changes_dir = fmt("out/release/swift-abi/%s-changes", a->name);
  cmd rm = {};
  cmd_addv(&rm, (const char *const[]){"/usr/bin/rm", "-rf", dir, changes_dir, nullptr});
  if (!run(&rm)) return false;
  mkdirs(dir);
  *broken = false;
  for (size_t i = 0; i < sizeof SWIFT_ABI_MODULES / sizeof SWIFT_ABI_MODULES[0]; i++) {
    const char *m = SWIFT_ABI_MODULES[i];
    const char *const common[] = {dig,
                                  "-abi",
                                  "-module",
                                  m,
                                  "-target",
                                  triple,
                                  "-sdk",
                                  sdk,
                                  "-resource-dir",
                                  fmt("%s/usr/lib/swift", sdk),
                                  "-I",
                                  fmt("%s/usr/lib/swift/vectraos", sdk),
                                  "-module-cache-path",
                                  fmt("out/release/swift-abi/cache-%s", a->name),
                                  nullptr};
    cmd dump = {};
    cmd_addv(&dump, common);
    cmd_addv(&dump, (const char *const[]){"-dump-sdk", "-o", fmt("%s/%s.json", dir, m), nullptr});
    if (!run(&dump)) die("swift-api-digester cannot dump %s for %s", m, triple);
    const char *baseline = fmt("%s/%s.json", base, m);
    if (!exists(baseline)) continue;
    mkdirs(changes_dir);
    const char *report = fmt("%s/%s.changes", changes_dir, m);
    cmd diag = {};
    cmd_addv(&diag, common);
    cmd_addv(&diag,
             (const char *const[]){"-diagnose-sdk", "-baseline-path", baseline, "-o", report, nullptr});
    run(&diag); // it reports through the file
    // The report has a /* section */ header for each kind of change, even
    // with none: a change is any other line.
    vx_str r = exists(report) ? read_file(report) : (vx_str){};
    uint32_t changes = 0;
    for (size_t at = 0; at < r.len;) {
      size_t e = at;
      while (e < r.len && r.ptr[e] != '\n') e++;
      bool header = e - at >= 2 && r.ptr[at] == '/' && r.ptr[at + 1] == '*';
      changes += e > at && !header;
      if (e > at && !header && memmem(r.ptr + at, e - at, "has been removed", 16)) *broken = true;
      at = e + 1;
    }
    if (changes) fprintf(stderr, "  SWIFT %-8s %s: %u ABI changes, in %s\n", a->name, m, changes, report);
  }
  return tree_sha256(dir, hash);
}

// ./build release: both architectures' base trees in out/release/store,
// each one's objects as out/release/store-ARCH.tar, and the release record,
// out/release/release.ndb, unsigned until M10 (06 §5). With --verify RECORD:
// the trees built again and compared with the record's (06 §5.2).
static int cmd_release(const char *verify) {
  check_toolchain();
  if (!build_vxstore()) return 1;
  mkdirs("out/release");
  const char *store = "out/release/store";
  char *commit = run_capture((const char *const[]){"/usr/bin/git", "rev-parse", "HEAD", nullptr});
  char *count = run_capture((const char *const[]){"/usr/bin/git", "rev-list", "--count", "HEAD", nullptr});
  char *dirty = run_capture((const char *const[]){"/usr/bin/git", "status", "--porcelain", nullptr});
  if (!commit || !count) die("./build release needs git");
  commit[strcspn(commit, "\n")] = 0, count[strcspn(count, "\n")] = 0;
  bool clean = dirty && !*dirty;
  static char text[4096];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  vx_ndb_put(&w, "release", (vx_str){count, strlen(count)});
  const char *name = fmt("dev-%s", count);
  vx_ndb_put(&w, "name", (vx_str){name, strlen(name)});
  vx_ndb_put(&w, "channel", VX_STR("dev"));
  const char *c = clean ? commit : fmt("%s+dirty", commit);
  vx_ndb_put(&w, "commit", (vx_str){c, strlen(c)});
  const char *level = fmt("%d", abi_level()); // 0, a draft, until ADR-0004 freezes level 1
  vx_ndb_put(&w, "vx-abi", (vx_str){level, strlen(level)});
  char behaviour[65];
  char held[65];
  int held_level = 0;
  // first: a release it refuses is refused before minutes of building
  if (!behaviour_allowed(&held_level, held))
    die("the behaviour suite changed from abi/levels/%d.behaviour: docs/release-notes.md must name it "
        "(\"behaviour-suite: %s\") and say what programs may now see (ADR-0004 item 8)",
        held_level, held);
  behaviour_hash(abi_level(), behaviour);
  fprintf(stderr, "  ABI   vx-abi %d, behaviour suite %.16s…\n", abi_level(), behaviour);
  vx_ndb_put(&w, "behaviour", (vx_str){behaviour, 64});
  vx_ndb_flag(&w, "unsigned");
  vx_ndb_end(&w);
  vx_str record = verify ? read_file(verify) : (vx_str){};
  int mismatches = 0;
  for (int i = 0; i < ARCH_COUNT; i++) {
    char tree[VX_STORE_HEX_LEN + 1];
    uint64_t bytes = 0;
    if (!release_tree(&ARCHES[i], store, tree, &bytes)) return 1;
    fprintf(stderr, "  TREE  %-8s %s (%llu bytes)\n", ARCHES[i].name, tree, (unsigned long long)bytes);
    vx_ndb_put(&w, "set", VX_STR("base"));
    vx_ndb_put(&w, "arch", (vx_str){ARCHES[i].name, strlen(ARCHES[i].name)});
    vx_ndb_put(&w, "tree", (vx_str){tree, strlen(tree)});
    vx_ndb_put_u64(&w, "size", bytes);
    vx_ndb_end(&w);
    if (verify) {
      const char *want = fmt("arch=%s tree=%s ", ARCHES[i].name, tree);
      bool same = memmem(record.ptr, record.len, want, strlen(want)) != nullptr;
      fprintf(stderr, "  VERIFY %-8s %s\n", ARCHES[i].name,
              same ? "the record's tree" : "NOT the record's tree");
      mismatches += !same;
    }
  }
  for (int i = 0; i < ARCH_COUNT && !verify; i++) { // the Swift libraries' ABI (6f3d)
    char hash[65];
    bool broken = false;
    if (!release_swift_abi(&ARCHES[i], hash, &broken)) continue;
    fprintf(stderr, "  SWIFT %-8s ABI %.16s… (out/release/swift-abi/%s)\n", ARCHES[i].name, hash,
            ARCHES[i].name);
    vx_ndb_put(&w, "swift-abi", (vx_str){hash, 64});
    vx_ndb_put(&w, "arch", (vx_str){ARCHES[i].name, strlen(ARCHES[i].name)});
    vx_ndb_end(&w);
    if (broken && VX_ABI_LEVEL >= 1)
      die("the Swift libraries' ABI broke against abi/swift (ADR-0048 item 4)");
    if (broken)
      fprintf(stderr, "  SWIFT %-8s ABI broken against abi/swift: allowed while the ABI is a draft\n",
              ARCHES[i].name);
  }
  if (w.failed) die("the release record does not fit");
  if (verify) return mismatches ? 1 : 0;
  write_file("out/release/release.ndb", (vx_str){text, w.len});
  fprintf(stderr, "  REL   out/release/release.ndb (release %s, %s, unsigned)\n", count,
          clean ? "a clean tree" : "uncommitted changes");
  return 0;
}

// --- qemu and test ---

typedef struct qemu_opts {
  bool kvm;
  bool gdb;
  bool test;         // serial on stdout, no monitor
  const char *share; // the directory vx9pserve serves at 10.0.2.100!5640
  const char *u9fs;  // the root u9fs serves at 10.0.2.101!564, and its log; or nullptr
  const char *cdrom; // boot this ISO as a CD, with no disk
  const char *disk;  // a second disk, on virtio-blk, or nullptr
  bool nvme;         // and on NVMe instead
  bool caching;      // the IOMMU in caching mode (VT-d's CAP.CM)
  const char *rtc;   // the real-time clock's starting time (QEMU's -rtc base=), or nullptr: the host's UTC
  bool persist;      // the boot disk's writes kept, even in a test (a boot after reboot: the installed disk)
  const char *qmp;   // a display (M7 step 7b1b): its screen, virtio's keyboard and tablet, QMP at this socket
  bool gpu;          // and the screen virtio-gpu's; else a framebuffer the firmware leaves (VGA, ramfb)
} qemu_opts;

// host/vx9pserve, built for this machine: the 9P server VectraOS mounts over
// TCP (M3). Rebuilt when its sources or vx-9p's change.
static const char VX9PSERVE[] = "out/host/vx9pserve";

// third_party/u9fs (ADR-0006), built for this machine: the stock 9P2000
// server the u9fs scenario tests against. As upstream left it, but for two
// constants its rune.c uses and nothing defines.
static const char U9FS[] = "out/host/u9fs";

static bool build_u9fs(void) {
  static const char *const UNITS[] = {
      "authnone",    "authrhosts", "authp9any", "convD2M",  "convM2D", "convM2S", "convS2M", "des",
      "dirmodeconv", "doprint",    "fcallconv", "oldfcall", "print",   "random",  "readn",   "remotehost",
      "rune",        "safecpy",    "strecpy",   "tokenize", "u9fs",    "utfrune"};
  struct stat out, src;
  bool stale = stat(U9FS, &out) != 0;
  for (size_t i = 0; !stale && i < sizeof UNITS / sizeof UNITS[0]; i++)
    stale = stat(fmt("third_party/u9fs/%s.c", UNITS[i]), &src) != 0 || newer(&src, &out);
  if (!stale) return true;
  mkdirs("out/host");
  fprintf(stderr, "  CC    u9fs host\n");
  cmd cc = {};
  cmd_add(&cc, CLANG);
  cmd_addv(&cc, (const char *const[]){"-std=gnu89", "-D_DEFAULT_SOURCE", "-DBit5=2", "-DRunemax=0x10FFFF",
                                      "-O2", "-g", "-w", "-Ithird_party/u9fs", "-o", U9FS, nullptr});
  for (size_t i = 0; i < sizeof UNITS / sizeof UNITS[0]; i++)
    cmd_add(&cc, fmt("third_party/u9fs/%s.c", UNITS[i]));
  return run(&cc);
}

static bool build_vx9pserve(void) {
  static const char *const SOURCES[] = {"host/vx9pserve/main.c", "host/vx9pserve/fs.c",
                                        "lib/vx-9p/codec.c",     "lib/vx-9p/server.c",
                                        "lib/vx-9p/fields.def",  "lib/vx-9p/messages.def"};
  struct stat out, src;
  bool stale = stat(VX9PSERVE, &out) != 0;
  for (size_t i = 0; !stale && i < sizeof SOURCES / sizeof SOURCES[0]; i++)
    stale = stat(SOURCES[i], &src) != 0 || newer(&src, &out);
  if (!stale) return true;
  mkdirs("out/host");
  fprintf(stderr, "  CC    vx9pserve host\n");
  cmd cc = {};
  cmd_add(&cc, CLANG);
  cmd_addv(&cc, (const char *const[]){"-std=c23", "-O2", "-g", "-Wall", "-Wextra", "-Werror", "-o", VX9PSERVE,
                                      "host/vx9pserve/main.c", nullptr});
  return run(&cc);
}

// host/vxfs, built for this machine: makes, fills and checks vx-fs volume
// images (docs/11 §7). Rebuilt when its source or the library's change.
static const char VXFS[] = "out/host/vxfs";

static bool build_vxfs(void) {
  static const char *const SOURCES[] = {"host/vxfs/main.c",  "lib/vx-fs/fs.h",   "lib/vx-fs/xxh64.c",
                                        "lib/vx-fs/blk.c",   "lib/vx-fs/tree.c", "lib/vx-fs/vol.c",
                                        "lib/vx-fs/check.c", "lib/vx-fs/file.c"};
  struct stat out, src;
  bool stale = stat(VXFS, &out) != 0;
  for (size_t i = 0; !stale && i < sizeof SOURCES / sizeof SOURCES[0]; i++)
    stale = stat(SOURCES[i], &src) != 0 || newer(&src, &out);
  if (!stale) return true;
  mkdirs("out/host");
  fprintf(stderr, "  CC    vxfs host\n");
  cmd cc = {};
  cmd_add(&cc, CLANG);
  cmd_addv(&cc, (const char *const[]){"-std=c23", "-O2", "-g", "-Wall", "-Wextra", "-Werror", "-o", VXFS,
                                      "host/vxfs/main.c", nullptr});
  return run(&cc);
}

// A volume image of `mib` MiB at `path`, with the system volume's branches
// (11 §5), each given the tree under the directory its entry names (or left
// empty), then checked: what ./build makes for tests and, later, releases.
static bool make_volume(const char *path, long mib, const char *const *trees) {
  static const char *const BRANCHES[] = {"store", "cfg", "home", "adm"};
  if (!build_vxfs()) return false;
  cmd mk = {};
  cmd_addv(&mk, (const char *const[]){VXFS, "mkfs", path, fmt("%ld", mib), nullptr});
  for (size_t i = 0; i < 4; i++) cmd_add(&mk, BRANCHES[i]);
  if (!run(&mk)) return false;
  for (size_t i = 0; i < 4; i++) {
    if (!trees[i]) continue;
    cmd put = {.log = fmt("%s.log", path)};
    cmd_addv(&put, (const char *const[]){VXFS, "put", path, BRANCHES[i], trees[i], nullptr});
    if (!run(&put)) return false;
  }
  cmd chk = {.log = fmt("%s.log", path)};
  cmd_addv(&chk, (const char *const[]){VXFS, "check", path, nullptr});
  return run(&chk);
}

// check's round trip through a volume image: docs/ put in a branch, read
// back byte for byte, a snapshot, a fork and a deletion, checked clean each
// time.
static bool check_vxfs_image(void) {
  mkdirs("out/vxfs");
  const char *img = "out/vxfs/check.img";
  const char *const trees[4] = {nullptr, nullptr, "docs", nullptr};
  bool ok = make_volume(img, 64, trees);
  static const char *const STEPS[][5] = {
      {"verify", "home", "docs"}, {"snap", "home", "home@check"}, {"fork", "home@check", "scratch"},
      {"del", "home@check"},      {"verify", "scratch", "docs"},  {"check"},
  };
  for (size_t i = 0; ok && i < sizeof STEPS / sizeof STEPS[0]; i++) {
    cmd c = {.log = "out/vxfs/check.img.log"};
    cmd_addv(&c, (const char *const[]){VXFS, STEPS[i][0], img, nullptr});
    for (size_t k = 1; k < 5 && STEPS[i][k]; k++) cmd_add(&c, STEPS[i][k]);
    ok = run(&c);
  }
  fprintf(stderr, "  VXFS  image            %s\n", ok ? "ok" : "FAIL: see out/vxfs/check.img.log");
  return ok;
}

static int remove_entry(const char *path, const struct stat *st, int type, struct FTW *ftw) {
  (void)st, (void)type, (void)ftw;
  return remove(path);
}

// nftw's callback for copy_tree: each directory and regular file under
// copy_from, made again under copy_to.
static const char *copy_from, *copy_to;

static int copy_entry(const char *path, const struct stat *st, int type, struct FTW *ftw) {
  (void)ftw;
  const char *dst = fmt("%s%s", copy_to, path + strlen(copy_from));
  if (type == FTW_D)
    mkdirs(dst);
  else if (S_ISREG(st->st_mode))
    write_file(dst, read_file(path));
  return 0;
}

// Copies the regular files and directories under from into to.
static void copy_tree(const char *from, const char *to) {
  copy_from = from, copy_to = to;
  if (nftw(from, copy_entry, 16, FTW_PHYS) != 0) die("cannot copy %s", from);
}

// A fresh copy of tests/fixtures/share for one QEMU to serve: what a guest
// writes there stays out of the repository and away from other runs.
static const char *fresh_share(const char *dir) {
  nftw(dir, remove_entry, 16, FTW_DEPTH | FTW_PHYS); // whatever the last run left
  copy_tree("tests/fixtures/share", dir);
  return dir;
}

// The same, as a root for u9fs, which chroots there: with the one user its
// lookups find (ADR-0006).
static const char *fresh_u9fs_root(const char *dir) {
  fresh_share(dir);
  mkdirs(fmt("%s/etc", dir));
  write_file(fmt("%s/etc/passwd", dir), (vx_str){"vectra:x:0:0::/:/bin/false\n", 28});
  write_file(fmt("%s/etc/group", dir), (vx_str){"vectra:x:0:\n", 12});
  return dir;
}

static void qemu_cmd(cmd *c, const arch *a, const char *image, qemu_opts o) {
  if (strcmp(a->name, "x86_64") == 0) {
    cmd_add(c, "/usr/bin/qemu-system-x86_64");
    cmd_addv(c, (const char *const[]){"-machine", "q35", nullptr});
    // VT-d, always (M5 step 6c): the kernel turns it on before any driver
    // runs. No interrupt remapping yet, which KVM's in-kernel irqchip wants off.
    // Virtio devices go through it only with iommu_platform=on (below), and
    // then their drivers must accept VIRTIO_F_ACCESS_PLATFORM.
    cmd_addv(c, (const char *const[]){"-device",
                                      o.caching ? "intel-iommu,intremap=off,caching-mode=on"
                                                : "intel-iommu,intremap=off",
                                      nullptr});
    if (o.kvm)
      cmd_addv(c, (const char *const[]){"-enable-kvm", "-cpu", "host", nullptr});
    else
      cmd_addv(c, (const char *const[]){"-cpu", "max", nullptr});
    cmd_addv(c,
             (const char *const[]){
                 "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd",
                 "-drive", "if=pflash,format=raw,unit=1,snapshot=on,file=/usr/share/edk2/ovmf/OVMF_VARS.fd",
                 nullptr});
  } else {
    cmd_add(c, "/usr/bin/qemu-system-aarch64");
    cmd_addv(
        c,
        (const char *const[]){
            "-machine", "virt,gic-version=3,iommu=smmuv3", "-cpu", "max", "-drive",
            "if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw",
            "-drive",
            "if=pflash,format=raw,unit=1,snapshot=on,file=/usr/share/edk2/aarch64/vars-template-pflash.raw",
            nullptr});
  }
  // 640 MiB: level 1's libvx scenario holds 306 MiB of heap at once, which
  // 512 left under 280 KiB of room for (7g2a, decided 2026-10-10).
  cmd_addv(c, (const char *const[]){"-m", "640M", "-smp", "4", "-display", "none", "-no-reboot", nullptr});
  if (o.qmp) { // a screen the harness reads (screendump), and input it gives (send-key)
    bool x86 = strcmp(a->name, "x86_64") == 0;
    // A framebuffer that outlives the firmware: x86's VGA (q35's own) or
    // aarch64's ramfb, which QEMU shows as it is written; virtio-gpu shows
    // nothing once the firmware's driver lets it go, until one of ours drives it.
    if (o.gpu)
      cmd_addv(
          c, (const char *const[]){"-device", "virtio-gpu-pci,disable-legacy=on,iommu_platform=on", nullptr});
    else if (!x86)
      cmd_addv(c, (const char *const[]){"-device", "ramfb", nullptr});
    if (o.gpu && x86) cmd_addv(c, (const char *const[]){"-vga", "none", nullptr});
    // The input devices, behind the IOMMU as every virtio device is: a
    // keyboard and a tablet, input0 and input1. No mouse: with one, QEMU
    // sends the buttons to it and the motion to the tablet, through two
    // drivers that may report them in either order.
    cmd_addv(c, (const char *const[]){"-device", "virtio-keyboard-pci,disable-legacy=on,iommu_platform=on",
                                      "-device", "virtio-tablet-pci,disable-legacy=on,iommu_platform=on",

                                      "-qmp", fmt("unix:%s,server=on,wait=off", o.qmp), nullptr});
  }
  if (o.rtc) cmd_addv(c, (const char *const[]){"-rtc", fmt("base=%s", o.rtc), nullptr});
  cmd_add(c, "-drive");
  if (o.cdrom) { // on virtio-scsi, which both architectures' firmware boots from
    cmd_add(c, fmt("if=none,id=cd,media=cdrom,readonly=on,file=%s", o.cdrom));
    cmd_addv(c, (const char *const[]){"-device", "virtio-scsi-pci,id=scsi,disable-legacy=on", "-device",
                                      "scsi-cd,drive=cd,bus=scsi.0", nullptr});
  } else {
    // A test never writes the image, so several can boot one image at once.
    cmd_add(c,
            fmt("if=none,id=disk,format=raw,file=%s%s", image, o.test && !o.persist ? ",snapshot=on" : ""));
    cmd_addv(c, (const char *const[]){
                    "-device", "virtio-blk-pci,drive=disk,disable-legacy=on,iommu_platform=on", nullptr});
  }
  if (o.disk) { // after the boot disk, so devmgr finds it second: /srv/disk1
    cmd_add(c, "-drive");
    cmd_add(c, fmt("if=none,id=disk1,format=raw,discard=unmap,file=%s", o.disk));
    if (o.nvme)
      cmd_addv(c, (const char *const[]){"-device", "nvme,drive=disk1,serial=vxdisk1", nullptr});
    else
      cmd_addv(c, (const char *const[]){
                      "-device", "virtio-blk-pci,drive=disk1,disable-legacy=on,iommu_platform=on", nullptr});
  }
  // QEMU's user networking: the guest is 10.0.2.15, the host 10.0.2.2 (M3).
  // Each connection to 10.0.2.100!7 gets a `cat` on the host of its own (an
  // echo server, for the tcp scenario), and each to 10.0.2.100!5640 a
  // vx9pserve serving o.share, so no host port is needed. (QEMU will not
  // forward the gateway's own address, so M3's exit test as 04 §5 gives it,
  // tcp!10.0.2.2!5640, needs `vx9pserve --listen 127.0.0.1:5640` on the host.)
  // With o.u9fs, each to 10.0.2.101!564 gets a u9fs, in a user namespace of
  // its own so that it may chroot (ADR-0006).
  cmd_add(c, "-netdev");
  const char *u9fs =
      o.u9fs ? fmt(",guestfwd=tcp:10.0.2.101:564-cmd:unshare -r %s -a none -u vectra -n -l %s.log %s", U9FS,
                   o.u9fs, o.u9fs)
             : "";
  cmd_add(
      c,
      fmt("user,id=net0,guestfwd=tcp:10.0.2.100:7-cmd:cat,guestfwd=tcp:10.0.2.100:5640-cmd:%s --stdio %s%s",
          VX9PSERVE, o.share, u9fs));
  cmd_addv(c, (const char *const[]){
                  "-device", "virtio-net-pci,netdev=net0,disable-legacy=on,iommu_platform=on", nullptr});
  if (o.test)
    cmd_addv(c, (const char *const[]){"-serial", "stdio", "-monitor", "none", nullptr});
  else
    cmd_addv(c, (const char *const[]){"-serial", "mon:stdio", nullptr});
  if (o.gdb) cmd_addv(c, (const char *const[]){"-s", "-S", nullptr});
}

// A scenario's second disk (disk=MIB), made fresh for each run: sparse
// zeros, with a signature in sector 0 so tests know it from the boot disk, and
// a GPT of two partitions, an EFI system partition of 8 MiB at 1 MiB and a
// VectraOS system volume of 32 MiB after it, each with a line naming it in its
// first sector (docs/proto/block.md §6). With `home` (volume=DIR), the system
// partition holds a vx-fs volume instead, its home branch DIR's tree.
// A test disk that is one FAT volume, no partition table (as many USB sticks
// are): FAT12, FAT16 or FAT32, made by mtools, labelled VECTRAFAT.
static const char *fat_disk(const char *path, long mib, int type) {
  unlink(path);
  cmd c = {};
  cmd_addv(&c, (const char *const[]){MFORMAT, "-C", "-i", path, "-v", "VECTRAFAT", "-T",
                                     fmt("%ld", mib << 11), "-h", "64", "-s", "32", nullptr});
  if (type == 32) cmd_add(&c, "-F");
  cmd_add(&c, "::");
  if (!run(&c)) die("cannot make the FAT test disk %s", path);
  return path;
}

// The distd tests' store branch (tests/qemu/distd.ndb): a small release made
// by host/vxstore (a file of several blocks, another never read before it is
// damaged, a nested directory, a link, a UTF-8 name), its record for both
// architectures, and beside them plain/ (not objects): the big file as it is,
// for comparing, and the store paths of the blocks the test damages.
static const char *make_test_release(const char *dir) {
  if (!build_vxstore()) die("cannot build vxstore");
  cmd rm = {};
  cmd_addv(&rm, (const char *const[]){"/usr/bin/rm", "-rf", dir, nullptr});
  if (!run(&rm)) die("cannot clear %s", dir);
  const char *src = fmt("%s.src", dir);
  cmd rm2 = {};
  cmd_addv(&rm2, (const char *const[]){"/usr/bin/rm", "-rf", src, nullptr});
  run(&rm2);
  mkdirs(fmt("%s/bin/deeper", src));
  mkdirs(fmt("%s/plain", dir));
  mkdirs(fmt("%s/records", dir));
  write_file(fmt("%s/README.txt", src), VX_STR("readme\n"));
  write_file(fmt("%s/bin/deeper/file.txt", src), VX_STR("deep\n"));
  write_file(fmt("%s/\xc3\x9cn\xc3\xaf\x63ode.txt", src), VX_STR("unicode\n"));
  static char big[300'000], other[200'000];
  for (size_t i = 0; i < sizeof big; i++) big[i] = (char)((i * 7 + i / 251) & 0xff);
  for (size_t i = 0; i < sizeof other; i++) other[i] = (char)((i * 13 + i / 509) & 0xff);
  write_file(fmt("%s/big.bin", src), (vx_str){big, sizeof big});
  write_file(fmt("%s/other.bin", src), (vx_str){other, sizeof other});
  write_file(fmt("%s/plain/big.bin", dir), (vx_str){big, sizeof big});
  if (symlink("README.txt", fmt("%s/readme-link", src)) != 0) die("cannot make the link");
  char *out = run_capture((const char *const[]){VXSTORE, "put", dir, src, nullptr});
  if (!out || !strchr(out, ' ')) die("vxstore put failed");
  *strchr(out, ' ') = 0;
  char *blocks = run_capture((const char *const[]){VXSTORE, "blocks", dir, out, "other.bin", nullptr});
  if (!blocks) die("vxstore blocks failed");
  char *second = strchr(blocks, '\n'); // other.bin's second block
  if (!second) die("other.bin has one block");
  second++;
  second[strcspn(second, "\n")] = 0;
  write_file(fmt("%s/plain/damage", dir), str_of(second));
  write_file(fmt("%s/records/1.ndb", dir),
             str_of(fmt("release=1 name=test-1 channel=dev commit=test vx-abi=0 unsigned\n"
                        "set=base arch=x86_64 tree=%s size=500021\n"
                        "set=base arch=aarch64 tree=%s size=500021\n",
                        out, out)));
  return dir;
}

static const char *test_disk(const char *path, long mib, const char *home, const char *store) {
  static const char SIGNATURE[] = "VectraOS block test disk";
  // The VectraOS system volume type, 7C6D3E1A-2B4F-4E0A-9C1D-56F2A8B90E35, as stored on disk.
  static const uint8_t SYSTEM_TYPE[16] = {0x1a, 0x3e, 0x6d, 0x7c, 0x4f, 0x2b, 0x0a, 0x4e,
                                          0x9c, 0x1d, 0x56, 0xf2, 0xa8, 0xb9, 0x0e, 0x35};
  uint64_t total = (uint64_t)mib << 11, last = total - 1;
  struct {
    const uint8_t *type;
    uint64_t first, sectors;
    const char *name, *marker;
  } parts[] = {{ESP_TYPE, 2048, 16384, "EFI system partition", "partition esp\n"},
               {SYSTEM_TYPE, 18432, 65536, "vectra", "partition vectra\n"}};
  if (total < 18432 + 65536 + 2048) die("disk=%ld is too small for the test partitions", mib);
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || ftruncate(fd, (off_t)(total * SECTOR)) != 0) die("cannot make %s", path);
  uint8_t *entries = alloc(GPT_TABLE_BYTES);
  memset(entries, 0, GPT_TABLE_BYTES);
  for (size_t i = 0; i < sizeof parts / sizeof parts[0]; i++) {
    uint8_t *e = entries + i * 128;
    memcpy(e, parts[i].type, 16);
    derived_guid(e + 16, i + 1, "test partition");
    put64(e + 32, parts[i].first);
    put64(e + 40, parts[i].first + parts[i].sectors - 1);
    for (size_t k = 0; parts[i].name[k]; k++) put16(e + 56 + 2 * k, (uint16_t)parts[i].name[k]);
    if ((home || store) && i == 1) continue;
    pwrite_all(fd, parts[i].marker, strlen(parts[i].marker), parts[i].first * SECTOR, path);
  }
  if (home || store) { // the volume, made beside the disk and copied into the partition
    const char *vol = fmt("%s.vxfs", path);
    const char *const trees[4] = {store, nullptr, home, nullptr};
    if (!make_volume(vol, (long)(parts[1].sectors * SECTOR >> 20), trees))
      die("cannot make the volume %s", vol);
    vx_str bytes = read_file(vol);
    if (bytes.len != parts[1].sectors * SECTOR) die("the volume %s is not the partition's size", vol);
    pwrite_all(fd, bytes.ptr, bytes.len, parts[1].first * SECTOR, path);
  }
  uint8_t disk_guid[16], primary[SECTOR], backup[SECTOR];
  derived_guid(disk_guid, 0, "test disk");
  uint32_t entries_crc = crc32(entries, GPT_TABLE_BYTES);
  gpt_header(primary, 1, last, 2, last, disk_guid, entries_crc);
  gpt_header(backup, last, 1, last - 32, last, disk_guid, entries_crc);
  // Sector 0: the signature in the boot code's place, and a protective MBR.
  uint8_t mbr[SECTOR] = {};
  memcpy(mbr, SIGNATURE, sizeof SIGNATURE - 1);
  uint8_t *pe = mbr + 446;
  pe[2] = 0x02, pe[4] = 0xee, pe[5] = pe[6] = pe[7] = 0xff;
  put32(pe + 8, 1);
  put32(pe + 12, last > 0xffffffff ? 0xffffffff : (uint32_t)last);
  mbr[510] = 0x55, mbr[511] = 0xaa;
  pwrite_all(fd, mbr, SECTOR, 0, path);
  pwrite_all(fd, primary, SECTOR, SECTOR, path);
  pwrite_all(fd, entries, GPT_TABLE_BYTES, 2 * SECTOR, path);
  pwrite_all(fd, entries, GPT_TABLE_BYTES, (last - 32) * SECTOR, path);
  pwrite_all(fd, backup, SECTOR, last * SECTOR, path);
  close(fd);
  return path;
}

static bool force_tcg; // test --tcg: emulate even where KVM would work, as CI runners may have to

static bool kvm_usable(const arch *a) {
  return !force_tcg && strcmp(a->name, "x86_64") == 0 && access("/dev/kvm", R_OK | W_OK) == 0;
}

// A scenario (tests/qemu/NAME.ndb): one scenario= record with a timeout in seconds
// and, optionally, a kernel cmdline= and with= (test programs to add to bootfs,
// comma-separated, from tests/user/); then expect= records, matched in order
// against serial output lines (line= records match a whole line instead of
// part of one, and prompt= records the start of any line since the last thing
// typed), and fail= records, any of which fails the test
// when a line contains it. "$arch" in a pattern stands for the architecture's
// name. send= and type= records between the expect= records are typed into
// the serial port once every expect= before them has matched; send= then
// presses return. With display=fb or display=gpu on the scenario= record,
// screen= and key= records, placed as send= is, compare the screen with a
// reference and press keys (see "The screen" below).
static constexpr int SCENARIO_MAX = 128;
static const char *scenarios[SCENARIO_MAX];
static int scenario_count;

static double now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static const char *substitute_arch(vx_str pattern, const arch *a) {
  const char *p = str_dup(pattern), *at = strstr(p, "$arch");
  if (!at) return p;
  return fmt("%.*s%s%s", (int)(at - p), p, a->name, at + 5);
}

// --- The screen (M7 step 7b1b) ---
//
// A scenario with display=fb (the framebuffer the firmware leaves, which
// QEMU shows as it is written: x86's VGA, aarch64's ramfb) or display=gpu
// (virtio-gpu, blank once the firmware lets it go) gets a virtio keyboard
// and tablet, and QEMU's QMP at a socket in its run directory. screen=REF (with tolerance=PERCENT, 1 if not given) between
// expects takes a screendump once every expect before it has matched and
// compares it with tests/qemu/screens/REF.rle (rle_encode's), retrying for a few seconds
// while the guest draws: a pixel differs if a channel is off by more than
// 48, and the screen matches if at most PERCENT of its pixels do. With no
// reference, the screen is kept as REF.rle.new (and REF.ppm.new, to look
// at) a second after its expects, the scenario goes on, and it fails at its
// end, for a person to look at and keep. key=SPEC presses
// keys, as QMP's send-key names them, joined by '-' for a chord.
// typekeys=TEXT types the text on the virtio keyboard, then return;
// click=X,Y taps the virtio tablet there (7c1), drag=X1,Y1,X2,Y2 drags with
// the left button, a coordinate a percentage of the screen ("20%"), one with
// an offset in pixels ("50%+114px"), a pixel ("430px": the screen measured by
// a screendump) or the tablet's own 0 to 32767; holdkey=SPEC,MS holds a chord while what follows
// it at the same place (a click=) is done (7d1c).

typedef struct qmp {
  int fd;
  char buf[16384];
  size_t len;
} qmp;

static bool qmp_line(qmp *q, char *out, size_t cap, double deadline) {
  for (;;) {
    char *nl = memchr(q->buf, '\n', q->len);
    if (nl) {
      size_t n = (size_t)(nl - q->buf) + 1;
      size_t k = n < cap ? n : cap - 1;
      memcpy(out, q->buf, k), out[k] = 0;
      memmove(q->buf, q->buf + n, q->len - n), q->len -= n;
      return true;
    }
    double left = deadline - now_seconds();
    struct pollfd pfd = {.fd = q->fd, .events = POLLIN};
    if (left <= 0 || poll(&pfd, 1, (int)(left * 1000) + 1) <= 0 || q->len == sizeof q->buf) return false;
    ssize_t got = read(q->fd, q->buf + q->len, sizeof q->buf - q->len);
    if (got <= 0) return false;
    q->len += (size_t)got;
  }
}

// A command and its answer: true if it returned (events before it are let go).
static char qmp_error[512]; // QMP's last error, as it said it

static bool qmp_do(qmp *q, const char *command) {
  size_t n = strlen(command);
  if (write(q->fd, command, n) != (ssize_t)n) return false;
  char line[16384];
  double deadline = now_seconds() + 10;
  while (qmp_line(q, line, sizeof line, deadline)) {
    if (strstr(line, "\"return\"")) return true;
    if (strstr(line, "\"error\"")) {
      snprintf(qmp_error, sizeof qmp_error, "%.*s", (int)strcspn(line, "\r\n"), line); // for the verdict
      return false;
    }
  }
  return false;
}

static bool qmp_open(qmp *q, const char *path) {
  struct sockaddr_un sa = {.sun_family = AF_UNIX};
  if (strlen(path) >= sizeof sa.sun_path) return false;
  strcpy(sa.sun_path, path);
  double deadline = now_seconds() + 10;
  for (;;) { // QEMU makes the socket as it starts
    q->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (q->fd >= 0 && connect(q->fd, (struct sockaddr *)&sa, sizeof sa) == 0) break;
    if (q->fd >= 0) close(q->fd);
    if (now_seconds() > deadline) return false;
    usleep(50'000);
  }
  q->len = 0;
  char line[16384];
  return qmp_line(q, line, sizeof line, deadline) && qmp_do(q, "{\"execute\":\"qmp_capabilities\"}\n");
}

typedef struct ppm {
  long w, h;
  const uint8_t *rgb; // w * h * 3
} ppm;

static bool ppm_read(vx_str text, ppm *out) {
  // P6, its numbers separated by whitespace (no comments: QEMU writes none), then 255 and one byte
  const char *p = text.ptr, *end = text.ptr + text.len;
  long v[3];
  if (text.len < 3 || p[0] != 'P' || p[1] != '6') return false;
  p += 2;
  for (int i = 0; i < 3; i++) {
    while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) p++;
    char *e;
    v[i] = strtol(p, &e, 10);
    if (e == p || v[i] <= 0) return false;
    p = e;
  }
  if (p >= end || v[2] != 255) return false;
  p++;
  if ((size_t)(end - p) < (size_t)(v[0] * v[1] * 3)) return false;
  *out = (ppm){.w = v[0], .h = v[1], .rgb = (const uint8_t *)p};
  return true;
}

// A reference as kept in tests/qemu/screens: REF.rle, "VXRLE1 W H\n" then
// runs of a pixel, each a count (1 to 65535, little-endian) and its R, G and
// B. Screens are mostly flat, so a run-length is small enough to keep in the
// repository and simple enough to need no library.
static vx_str rle_encode(const ppm *p) {
  size_t n = (size_t)(p->w * p->h), cap = 32 + n * 5, len = 0;
  char *out = alloc(cap);
  len = (size_t)snprintf(out, cap, "VXRLE1 %ld %ld\n", p->w, p->h);
  for (size_t i = 0; i < n;) {
    size_t run = 1;
    while (i + run < n && run < 65535 && !memcmp(p->rgb + (i + run) * 3, p->rgb + i * 3, 3)) run++;
    out[len++] = (char)(run & 0xff), out[len++] = (char)(run >> 8);
    memcpy(out + len, p->rgb + i * 3, 3), len += 3;
    i += run;
  }
  return (vx_str){out, len};
}

static bool rle_decode(vx_str text, ppm *out) {
  if (text.len < 8 || memcmp(text.ptr, "VXRLE1 ", 7) != 0) return false;
  char *e;
  long w = strtol(text.ptr + 7, &e, 10), h = *e == ' ' ? strtol(e + 1, &e, 10) : 0;
  if (*e != '\n' || w <= 0 || h <= 0) return false;
  size_t at = (size_t)(e + 1 - text.ptr);
  uint8_t *rgb = alloc((size_t)(w * h * 3));
  size_t px = 0, n = (size_t)(w * h);
  for (size_t i = at; i + 5 <= text.len && px < n; i += 5) {
    size_t run = (uint8_t)text.ptr[i] | (size_t)(uint8_t)text.ptr[i + 1] << 8;
    for (size_t k = 0; k < run && px < n; k++, px++) memcpy(rgb + px * 3, text.ptr + i + 2, 3);
  }
  if (px != n) return false;
  *out = (ppm){.w = w, .h = h, .rgb = rgb};
  return true;
}

// The share of pixels that differ, in hundredths of a percent; -1 if the sizes do.
static long ppm_differ(const ppm *a, const ppm *b) {
  if (a->w != b->w || a->h != b->h) return -1;
  long n = a->w * a->h, off = 0;
  for (long i = 0; i < n; i++) {
    const uint8_t *x = a->rgb + i * 3, *y = b->rgb + i * 3;
    for (int k = 0; k < 3; k++)
      if (abs((int)x[k] - (int)y[k]) > 48) {
        off++;
        break;
      }
  }
  return off * 10'000 / n;
}

// screen=REF: matched within tolerance (hundredths of a percent), retried
// for 5 s; nullptr, or why not.
// A screen with no reference, kept for a person to look at: the scenario
// goes on, and fails at its end with this.
static const char *screen_missing;

static const char *screen_check(qmp *q, const char *dump, const char *ref, long tolerance) {
  const char *ref_path = fmt("tests/qemu/screens/%s.rle", ref);
  ppm w = {}, got = {};
  bool have_ref = access(ref_path, R_OK) == 0;
  if (have_ref && !rle_decode(read_file(ref_path), &w)) return fmt("%s is no VXRLE1 screen", ref_path);
  long best = -2;
  double deadline = now_seconds() + 5;
  if (!have_ref) usleep(1'000'000); // with nothing to wait for, a second for the guest to finish drawing
  do {
    unlink(dump);
    if (!qmp_do(q, fmt("{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"%s\"}}\n", dump)))
      return "QMP's screendump failed";
    vx_str shot = read_file(dump);
    if (!ppm_read(shot, &got)) return "the screendump is no P6 PPM";
    if (!have_ref) { // kept to look at (the PPM) and to keep (the run-length)
      mkdirs("tests/qemu/screens");
      write_file(fmt("tests/qemu/screens/%s.ppm.new", ref), shot);
      write_file(fmt("%s.new", ref_path), rle_encode(&got));
      screen_missing =
          fmt("no reference %s: the screen kept as %s.new (and .ppm.new to look at), to keep if right",
              ref_path, ref_path);
      return nullptr;
    }
    best = ppm_differ(&got, &w);
    if (best >= 0 && best <= tolerance) return nullptr;
    usleep(200'000);
  } while (now_seconds() < deadline);
  write_file(fmt("%s.got", dump), read_file(dump));
  if (best == -1) return fmt("the screen is %ldx%ld, %s %ldx%ld", got.w, got.h, ref_path, w.w, w.h);
  return fmt(
      "the screen differs from %s in %ld.%02ld%% of its pixels (tolerance %ld.%02ld%%); kept as %s.got",
      ref_path, best / 100, best % 100, tolerance / 100, tolerance % 100, dump);
}

// key=SPEC: one press of the chord, its keys QMP's qcodes joined by '-'.
// Several chords, separated by spaces, are pressed in turn (typekeys=).
static bool key_chord(qmp *q, const char *spec);
static bool key_press(qmp *q, const char *spec) {
  for (const char *k = spec; *k;) {
    const char *e = strchr(k, ' ');
    size_t len = e ? (size_t)(e - k) : strlen(k);
    if (!key_chord(q, str_dup((vx_str){k, len}))) return false;
    k += len + (e != nullptr);
  }
  return true;
}

// typekeys=TEXT as chords: each character's key, shifted as the US layout
// has it, then return. The characters a shell line needs.
static const char *typed_keys(vx_str text) {
  static const char *const PUNCT[][2] = {{" ", "spc"},
                                         {"-", "minus"},
                                         {"=", "equal"},
                                         {"/", "slash"},
                                         {".", "dot"},
                                         {",", "comma"},
                                         {";", "semicolon"},
                                         {"'", "apostrophe"},
                                         {"|", "shift-backslash"},
                                         {">", "shift-dot"},
                                         {"<", "shift-comma"},
                                         {"\"", "shift-apostrophe"},
                                         {"_", "shift-minus"},
                                         {"$", "shift-4"},
                                         {"*", "shift-8"},
                                         {"&", "shift-7"},
                                         {":", "shift-semicolon"}};
  char *out = alloc(text.len * 24 + 8);
  size_t n = 0;
  for (size_t i = 0; i < text.len; i++) {
    char ch = text.ptr[i];
    const char *k = nullptr;
    if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')) {
      n += (size_t)sprintf(out + n, "%c ", ch);
      continue;
    }
    if (ch >= 'A' && ch <= 'Z') {
      n += (size_t)sprintf(out + n, "shift-%c ", ch - 'A' + 'a');
      continue;
    }
    for (size_t p = 0; p < sizeof PUNCT / sizeof PUNCT[0]; p++)
      if (PUNCT[p][0][0] == ch) k = PUNCT[p][1];
    if (!k) die("typekeys=: no key for '%c'", ch);
    n += (size_t)sprintf(out + n, "%s ", k);
  }
  sprintf(out + n, "ret");
  return out;
}

// A coordinate of click= or drag=: a percentage of the screen ("20%") or
// the tablet's own value, 0 to 32767; then *at past it and a comma.
// The guest's screen size, for coordinates in pixels: from a screendump, once
// a scenario first needs it (qmp_dump is where the dumps go).
static const char *qmp_dump;
static long screen_size[2];

static bool screen_measure(qmp *q) {
  if (screen_size[0]) return true;
  if (!qmp_do(q, fmt("{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"%s\"}}\n", qmp_dump)))
    return false;
  ppm shot;
  if (!ppm_read(read_file(qmp_dump), &shot)) return false;
  screen_size[0] = shot.w, screen_size[1] = shot.h;
  return true;
}

// A coordinate of click= or drag= on axis 0 (x) or 1 (y): a percentage of
// the screen ("20%"), a pixel ("430px"), or the tablet's own value, 0 to
// 32767; then *at past it and a comma.
static bool tablet_value(qmp *q, const char **at, long *v, int axis) {
  char *end = nullptr;
  *v = strtol(*at, &end, 10);
  if (end == *at) return false;
  if (*end == '%') {
    *v = *v * 32767 / 100, end++;
    if ((*end == '+' || *end == '-') && strchr(end, 'p')) { // 50%+114px: an offset in pixels from it
      char *e2 = nullptr;
      long px = strtol(end, &e2, 10);
      if (e2[0] != 'p' || e2[1] != 'x' || !screen_measure(q) || screen_size[axis] < 2) return false;
      *v += px * 32767 / (screen_size[axis] - 1), end = e2 + 2;
    }
  } else if (end[0] == 'p' && end[1] == 'x') {
    if (!screen_measure(q) || screen_size[axis] < 2) return false;
    long n = screen_size[axis] - 1;
    *v = (*v * 32767 + n - 1) / n; // rounded up: winsrv's scaling back, which truncates, gives the pixel
    end += 2;
  }
  if (*end == ',') end++;
  *at = end;
  return *v >= 0 && *v <= 32767;
}

static bool tablet_move(qmp *q, long x, long y) {
  return qmp_do(q, fmt("{\"execute\":\"input-send-event\",\"arguments\":{\"events\":["
                       "{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":%ld}},"
                       "{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":%ld}}]}}\n",
                       x, y));
}

static bool tablet_button(qmp *q, bool down) {
  return qmp_do(q, fmt("{\"execute\":\"input-send-event\",\"arguments\":{\"events\":["
                       "{\"type\":\"btn\",\"data\":{\"down\":%s,\"button\":\"left\"}}]}}\n",
                       down ? "true" : "false"));
}

// Each step a while after the last, for the guest to take them in turn.
static void input_pause(void) { usleep(80'000); }

// click=X,Y: the tablet to (X, Y), then the left button pressed and let go
// there. drag=X1,Y1,X2,Y2: pressed at the first, moved to the second with it
// held, and let go there. A coordinate is a percentage of the screen ("20%")
// or the tablet's own value, 0 to 32767.
static bool click(qmp *q, const char *at, bool drag) {
  long v[4];
  for (int i = 0; i < (drag ? 4 : 2); i++)
    if (!tablet_value(q, &at, &v[i], i & 1)) return false;
  if (*at) return false;
  bool ok = tablet_move(q, v[0], v[1]);
  input_pause();
  ok = ok && tablet_button(q, true);
  input_pause();
  if (drag) {
    ok = ok && tablet_move(q, v[2], v[3]);
    input_pause();
  }
  return ok && tablet_button(q, false);
}

static bool key_chord(qmp *q, const char *spec) {
  char keys[1024] = "";
  size_t n = 0;
  for (const char *k = spec; *k;) {
    const char *e = strchr(k, '-');
    size_t len = e ? (size_t)(e - k) : strlen(k);
    n += (size_t)snprintf(keys + n, sizeof keys - n, "%s{\"type\":\"qcode\",\"data\":\"%.*s\"}", n ? "," : "",
                          (int)len, k);
    k += len + (e != nullptr);
    if (n >= sizeof keys) return false;
  }
  return qmp_do(q, fmt("{\"execute\":\"send-key\",\"arguments\":{\"keys\":[%s]}}\n", keys));
}

// holdkey=SPEC,MS: the chord pressed and held MS milliseconds, while what
// follows it (a click=) is done: send-key returns at once.
static bool key_hold(qmp *q, const char *spec) {
  const char *comma = strrchr(spec, ',');
  if (!comma) return false;
  long ms = strtol(comma + 1, nullptr, 10);
  char keys[256] = "";
  size_t n = 0;
  for (const char *k = spec; k < comma;) {
    const char *e = memchr(k, '-', (size_t)(comma - k));
    size_t len = e ? (size_t)(e - k) : (size_t)(comma - k);
    n += (size_t)snprintf(keys + n, sizeof keys - n, "%s{\"type\":\"qcode\",\"data\":\"%.*s\"}", n ? "," : "",
                          (int)len, k);
    k += len + (e != nullptr);
    if (n >= sizeof keys) return false;
  }
  bool ok = qmp_do(
      q, fmt("{\"execute\":\"send-key\",\"arguments\":{\"keys\":[%s],\"hold-time\":%ld}}\n", keys, ms));
  input_pause();
  return ok;
}

static bool run_scenario(const arch *a, bool release, const char *name) {
  const char *path = fmt("tests/qemu/%s.ndb", name);
  vx_ndb_reader r = {.src = read_file(path), .scratch = alloc(16 << 10), .scratch_cap = 16 << 10};
  const char *expect[64], *fail[64];
  bool whole[64] = {};   // expect[k] came from line=: the whole line must be it
  bool prompt[64] = {};  // expect[k] came from prompt=: it has started a line since the last thing typed
  vx_str input[64] = {}; // typed once every expect before it has matched: input[k] goes before expect[k]
  // screen= and key= (7b1b), as input: done once every expect before them has matched.
  const char *screen[64] = {}, *keys_at[64] = {}, *clicks_at[64] = {}; // click= and typekeys= (7c1) too
  const char *holds_at[64] = {};                                       // holdkey= (7d1c)
  bool drags[64] = {};                                                 // clicks_at[k] is a drag=
  long tolerance[64] = {};
  bool display = false, gpu = false; // display=fb (the firmware's framebuffer) or display=gpu (virtio-gpu)
  int expect_count = 0, fail_count = 0;
  double timeout = 0;
  const char *cmdline = "", *with = "";
  bool iso = false;          // scenario=... iso: boot the ISO, as a CD
  long disk_mib = 0;         // scenario=... disk=MIB: a second disk, made fresh for the run
  bool nvme = false;         // and bus=nvme: on NVMe, not virtio-blk
  bool caching = false;      // scenario=... iommu=caching: VT-d's caching mode on
  const char *rtc = nullptr; // scenario=... rtc=2030-01-02T03:04:05: the RTC starts then
  int fat = 0;               // and fat=12|16|32: the disk= is one FAT volume, no GPT
  bool fsck = false;         // and fsck: fsck.fat -n must find that volume sound after
  bool isodisk = false;      // scenario=... isodisk: the second disk is make_test_iso's ISO
  bool installer = false;    // scenario=... installer: the ISO an install medium (implies iso)
  bool blank = false;        // and blank: the disk= is all zeros, as a new disk is
  bool media = false; // and media: release 2 on a FAT disk, the second disk of every boot after the first
  const char *only = nullptr;              // scenario=... arch=A: run on A only
  bool must_exit = false;                  // scenario=... exits: QEMU must then exit by itself (power off)
  const char *volume = nullptr;            // and volume=DIR: its system partition a volume, home DIR
  bool storetree = false;                  // and storetree: its store branch make_test_release's
  const char *host_file[8], *host_text[8]; // host=FILE text=...: in the share, once it passed
  int host_count = 0;
  // reboot: the scenario's boots, each its expects: phase k's are [phase_end[k-1], phase_end[k]). Each
  // but the last ends with QEMU exiting by itself (power off); each after the first boots from the
  // second disk, as the machine it was installed on would, with no CD.
  // again: the next boot is the same image's, with the second disk as the
  // last boot left it (cut there, as a power cut would: M5 step 11).
  int phase_end[4], nphases = 0;
  bool again[4] = {};
  for (;;) {
    vx_ndb_record rec;
    vx_ndb_result res = vx_ndb_next(&r, &rec);
    if (res == VX_NDB_END) break;
    if (res == VX_NDB_ERROR) die("%s:%zu: %s", path, r.error_line, r.error);
    if (vx_ndb_has(&rec, "scenario")) {
      const char *t = str_dup(vx_ndb_get(&rec, "timeout"));
      char *end;
      timeout = strtod(t, &end);
      if (end == t || *end) die("%s:%zu: timeout=%s is not a number of seconds", path, rec.line, t);
      cmdline = str_dup(vx_ndb_get(&rec, "cmdline"));
      with = str_dup(vx_ndb_get(&rec, "with"));
      iso = vx_ndb_has(&rec, "iso");
      if (vx_ndb_has(&rec, "disk")) {
        const char *d = str_dup(vx_ndb_get(&rec, "disk"));
        disk_mib = strtol(d, &end, 10);
        if (end == d || *end || disk_mib <= 0 || disk_mib > 4096)
          die("%s:%zu: disk=%s is not a size in MiB, up to 4096", path, rec.line, d);
      }
      if (vx_ndb_has(&rec, "volume")) volume = str_dup(vx_ndb_get(&rec, "volume"));
      storetree = vx_ndb_has(&rec, "storetree");
      if (vx_ndb_has(&rec, "arch")) only = str_dup(vx_ndb_get(&rec, "arch"));
      must_exit = vx_ndb_has(&rec, "exits");
      display = vx_ndb_has(&rec, "display");
      if (display) {
        const char *d = str_dup(vx_ndb_get(&rec, "display"));
        if (strcmp(d, "fb") != 0 && strcmp(d, "gpu") != 0)
          die("%s:%zu: display=%s is fb or gpu", path, rec.line, d);
        gpu = strcmp(d, "gpu") == 0;
      }
      if (vx_ndb_has(&rec, "rtc")) rtc = str_dup(vx_ndb_get(&rec, "rtc"));
      if (vx_ndb_has(&rec, "fat")) {
        fat = (int)strtol(str_dup(vx_ndb_get(&rec, "fat")), &end, 10);
        if (fat != 12 && fat != 16 && fat != 32) die("%s:%zu: fat= is 12, 16 or 32", path, rec.line);
      }
      fsck = vx_ndb_has(&rec, "fsck");
      isodisk = vx_ndb_has(&rec, "isodisk");
      installer = vx_ndb_has(&rec, "installer");
      iso = iso || installer;
      blank = vx_ndb_has(&rec, "blank");
      media = vx_ndb_has(&rec, "media");
      if (vx_ndb_has(&rec, "iommu")) {
        const char *m = str_dup(vx_ndb_get(&rec, "iommu"));
        if (strcmp(m, "caching") != 0) die("%s:%zu: iommu=%s: only iommu=caching", path, rec.line, m);
        caching = true;
      }
      if (vx_ndb_has(&rec, "bus")) {
        const char *b = str_dup(vx_ndb_get(&rec, "bus"));
        if (strcmp(b, "nvme") != 0 && strcmp(b, "virtio") != 0)
          die("%s:%zu: bus=%s is neither nvme nor virtio", path, rec.line, b);
        nvme = strcmp(b, "nvme") == 0;
      }
    } else if (vx_ndb_has(&rec, "reboot") || vx_ndb_has(&rec, "again")) { // another boot
      if (nphases == 3 || expect_count == 0)
        die("%s:%zu: reboot or again after an expect=, at most 3 times", path, rec.line);
      again[nphases + 1] = vx_ndb_has(&rec, "again");
      phase_end[nphases++] = expect_count;
    } else if (vx_ndb_has(&rec, "host") && host_count < 8) {
      vx_str file = vx_ndb_get(&rec, "host");
      for (size_t k = 0; k < file.len; k++)
        if (file.ptr[k] == '/' && (k + 2 < file.len && file.ptr[k + 1] == '.' && file.ptr[k + 2] == '.'))
          die("%s:%zu: host= names a file inside the run directory", path, rec.line);
      if (!file.len || file.ptr[0] == '/' || (file.len >= 2 && file.ptr[0] == '.' && file.ptr[1] == '.'))
        die("%s:%zu: host= names a file inside the run directory", path, rec.line);
      host_file[host_count] = str_dup(file);
      host_text[host_count++] = str_dup(vx_ndb_get(&rec, "text"));
    } else if ((vx_ndb_has(&rec, "expect") || vx_ndb_has(&rec, "line") || vx_ndb_has(&rec, "prompt")) &&
               expect_count < 64) {
      const char *key = "expect";
      if (vx_ndb_has(&rec, "line"))
        key = "line";
      else if (vx_ndb_has(&rec, "prompt"))
        key = "prompt";
      whole[expect_count] = strcmp(key, "line") == 0;
      prompt[expect_count] = strcmp(key, "prompt") == 0;
      expect[expect_count] = substitute_arch(vx_ndb_get(&rec, key), a);
      expect_count++;
    } else if (vx_ndb_has(&rec, "fail") && fail_count < 64) {
      fail[fail_count++] = substitute_arch(vx_ndb_get(&rec, "fail"), a);
    } else if (vx_ndb_has(&rec, "screen") && expect_count < 64) {
      if (!display) die("%s:%zu: screen= needs the scenario's display", path, rec.line);
      screen[expect_count] = substitute_arch(vx_ndb_get(&rec, "screen"), a); // a reference each: boot-$arch
      tolerance[expect_count] = 100;                                         // 1%
      if (vx_ndb_has(&rec, "tolerance")) {
        char *e;
        const char *t = str_dup(vx_ndb_get(&rec, "tolerance"));
        double pct = strtod(t, &e);
        if (e == t || *e || pct < 0 || pct > 100)
          die("%s:%zu: tolerance=%s is no percentage", path, rec.line, t);
        tolerance[expect_count] = (long)(pct * 100);
      }
    } else if ((vx_ndb_has(&rec, "key") || vx_ndb_has(&rec, "typekeys")) && expect_count < 64) {
      if (!display) die("%s:%zu: key= and typekeys= need the scenario's display", path, rec.line);
      if (keys_at[expect_count])
        die("%s:%zu: two key= or typekeys= before one expect: join them in one", path, rec.line);
      keys_at[expect_count] = vx_ndb_has(&rec, "key") ? str_dup(vx_ndb_get(&rec, "key"))
                                                      : typed_keys(vx_ndb_get(&rec, "typekeys"));
    } else if ((vx_ndb_has(&rec, "click") || vx_ndb_has(&rec, "drag")) && expect_count < 64) {
      if (!display) die("%s:%zu: click= and drag= need the scenario's display", path, rec.line);
      drags[expect_count] = vx_ndb_has(&rec, "drag");
      clicks_at[expect_count] = str_dup(vx_ndb_get(&rec, drags[expect_count] ? "drag" : "click"));
    } else if (vx_ndb_has(&rec, "holdkey") && expect_count < 64) {
      if (!display) die("%s:%zu: holdkey= needs the scenario's display", path, rec.line);
      holds_at[expect_count] = str_dup(vx_ndb_get(&rec, "holdkey"));
    } else if ((vx_ndb_has(&rec, "send") || vx_ndb_has(&rec, "type")) && expect_count < 64) {
      bool send = vx_ndb_has(&rec, "send"); // send= presses return after it; type= types exactly
      vx_str text = vx_ndb_get(&rec, send ? "send" : "type"), *in = &input[expect_count];
      in->ptr =
          fmt("%.*s%.*s%s", (int)in->len, in->ptr ? in->ptr : "", (int)text.len, text.ptr, send ? "\r" : "");
      in->len += text.len + send;
    } else {
      if (expect_count == 64 || fail_count == 64)
        die("%s:%zu: more than 64 expect= or fail= records", path, rec.line);
      die("%s:%zu: expected scenario=, expect=, line=, prompt=, fail=, send=, type=, screen=, key=, "
          "typekeys=, "
          "holdkey=, click=, drag= or host=",
          path, rec.line);
    }
  }
  if (timeout <= 0 || expect_count == 0) die("%s: needs scenario= with a timeout, and an expect=", path);
  if (nphases && phase_end[nphases - 1] == expect_count) die("%s: reboot needs an expect= after it", path);
  phase_end[nphases++] = expect_count;
  if (only && strcmp(only, a->name) != 0) { // what the other architecture lacks so far (an IOMMU, say)
    fprintf(stderr, "  TEST  %-11s %-8s skipped (%s only)\n", name, a->name, only);
    return true;
  }

  const char *image = image_path(a, release), *cdrom = nullptr;
  if (*cmdline || *with || iso) {
    image = fmt("%s/test-%s.img", out_dir(a, release), name);
    if (iso) cdrom = fmt("%s/test-%s.iso", out_dir(a, release), name);
    iso_installer = installer, iso_media = media, iso_media_store = nullptr;
    bool made = make_image(a, release, image, cmdline, with, cdrom);
    iso_installer = iso_media = false;
    if (!made) return false;
  }

  const char *log_path = fmt("%s/test-%s.log", out_dir(a, release), name);
  FILE *log = fopen(log_path, "w");
  if (!log) die("cannot write %s", log_path);

  cmd c = {};
  // What the run's servers serve, fresh: run-NAME/share for vx9pserve, run-NAME/u9fs for u9fs.
  const char *run_dir = fmt("%s/run-%s", out_dir(a, release), name);
  qmp_dump = fmt("%s/measure.ppm", run_dir), screen_size[0] = screen_size[1] = 0;
  screen_missing = nullptr;
  const char *share = fresh_share(fmt("%s/share", run_dir)), *u9fs = fresh_u9fs_root(fmt("%s/u9fs", run_dir));
  if (volume && !disk_mib) die("%s: volume= needs disk=", path);
  if ((fat || fsck) && (!disk_mib || volume)) die("%s: fat= and fsck need disk= and no volume=", path);
  if (fsck && !fat) die("%s: fsck needs fat=", path);
  if (isodisk && (disk_mib || fat)) die("%s: isodisk is the second disk: no disk= or fat=", path);
  const char *disk = nullptr;
  if (isodisk) {
    disk = fmt("%s/test.iso", run_dir);
    make_test_iso(disk);
  }
  if (blank) {
    if (!disk_mib || volume || fat || storetree) die("%s: blank needs disk= and nothing to put on it", path);
    disk = fmt("%s/disk.img", run_dir);
    int bfd = open(disk, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (bfd < 0 || ftruncate(bfd, (off_t)disk_mib << 20) != 0) die("cannot make %s", disk);
    close(bfd);
  } else if (fat) {
    disk = fat_disk(fmt("%s/disk.img", run_dir), disk_mib, fat);
  } else if (disk_mib) {
    disk = test_disk(fmt("%s/disk.img", run_dir), disk_mib, volume,
                     storetree ? make_test_release(fmt("%s/store", run_dir)) : nullptr);
  }
  const char *media_disk = nullptr; // release 2's store as files on a FAT disk, for boots after the first
  if (media) {
    if (!iso_media_store) die("%s: media needs installer", path);
    media_disk = fat_disk(fmt("%s/media.img", run_dir), 128, 32);
    cmd cp = {};
    cmd_addv(&cp, (const char *const[]){MCOPY, "-s", "-i", media_disk, fmt("%s/b2", iso_media_store),
                                        fmt("%s/records", iso_media_store), "::/", nullptr});
    if (!run(&cp)) die("%s: cannot put release 2 on the media disk", path);
  }
  const char *verdict = "ok";
  double run_start = now_seconds();
  for (int ph = 0; ph < nphases && strcmp(verdict, "ok") == 0; ph++) {
    int phase_first = ph ? phase_end[ph - 1] : 0, phase_last = phase_end[ph];
    // A boot but the last ends once its expects are met (QEMU is then stopped,
    // as a power cut would): what it wrote must have reached the disk by then.
    bool phase_exits = must_exit && ph + 1 == nphases;
    if (ph && !disk) die("%s: reboot boots the second disk, and there is none", path);
    bool second = ph && !again[ph]; // booting from the second disk
    if (ph) fprintf(log, "\n--- build: boot %d, %s ---\n", ph + 1, second ? "from the second disk" : "again");
    c = (cmd){};
    qemu_cmd(&c, a, second ? disk : image,
             (qemu_opts){.kvm = kvm_usable(a),
                         .test = true,
                         .share = share,
                         .u9fs = u9fs,
                         .cdrom = second ? nullptr : cdrom,
                         .disk = second ? media_disk : disk,
                         .persist = second,
                         .nvme = nvme,
                         .caching = caching,
                         .rtc = rtc,
                         .qmp = display ? fmt("%s/qmp.sock", run_dir) : nullptr,
                         .gpu = gpu});
    if (verbose) cmd_print(&c);
    signal(SIGPIPE, SIG_IGN); // QEMU gone: a write to it fails, rather than ending this process
    int fds[2], keys[2];      // QEMU's serial: its output, and what is typed into it
    if (pipe(fds) != 0 || pipe(keys) != 0) die("pipe failed");
    pid_t pid = fork();
    if (pid < 0) die("fork failed");
    if (pid == 0) {
      dup2(keys[0], 0);
      dup2(fds[1], 1);
      close(fds[0]);
      close(fds[1]);
      close(keys[0]);
      close(keys[1]);
      execv(c.argv[0], (char *const *)c.argv);
      _exit(127);
    }
    close(fds[1]);
    close(keys[0]);

    double start = now_seconds();
    int next = phase_first, typed = phase_first - 1; // input[typed] has been typed
    int shown = phase_first - 1;                     // screen[shown] and keys_at[shown] done
    qmp q = {.fd = -1};
    verdict = nullptr;
    if (display && !qmp_open(&q, fmt("%s/qmp.sock", run_dir))) verdict = "cannot reach QEMU's QMP";
    char line[4096];
    size_t len = 0;
    static char since[64 * 1024]; // the output since the last thing typed, for prompt=
    size_t since_len = 0;
    bool since_cut = false; // since[0] is mid-line: older output was let go
    static char buf[4096];  // read from QEMU; [pos, n) not looked at yet
    ssize_t n = 0, pos = 0;
    ssize_t stale = 0;     // bytes of buf, from pos, that came before the last typing
    bool all_seen = false; // every expect= met; with exits, QEMU's exit is what is waited for now
    while (!verdict) {
      // The screens and the input due by now, in order: every index up to
      // next, since a burst of output can match several expects at once.
      for (; shown < next &&
             !verdict;) { // even once all are seen: a burst can match the last with ones before it
        int k = ++shown;
        if (screen[k]) verdict = screen_check(&q, fmt("%s/screen.ppm", run_dir), screen[k], tolerance[k]);
        if (!verdict && keys_at[k] && !key_press(&q, keys_at[k]))
          verdict = fmt("QMP's send-key failed for %s", keys_at[k]);
        if (!verdict && holds_at[k] && !key_hold(&q, holds_at[k]))
          verdict = fmt("QMP's send-key failed for holdkey=%s", holds_at[k]);
        if (!verdict && clicks_at[k] && !click(&q, clicks_at[k], drags[k]))
          verdict = fmt("QMP's input-send-event failed for %s=%s: %s", drags[k] ? "drag" : "click",
                        clicks_at[k], qmp_error);
      }
      if (verdict) break;
      if (!all_seen && typed < next && input[next].len) {
        if (write(keys[1], input[next].ptr, input[next].len) != (ssize_t)input[next].len) {
          verdict = "cannot type into QEMU (it has exited?)"; // QEMU is still killed, and the log kept
          break;
        }
        typed = next;
        since_len = 0;
        since_cut = false;
        stale = n - pos; // read before the typing: no prompt in it answers what was typed
      }
      if (pos == n) { // all looked at: read more
        double left = timeout - (now_seconds() - start);
        if (left <= 0) {
          verdict =
              all_seen ? "QEMU did not exit (exits)" : fmt("timed out waiting for \"%s\"", expect[next]);
          break;
        }
        struct pollfd pfd = {.fd = fds[0], .events = POLLIN};
        if (poll(&pfd, 1, (int)(left * 1000) + 1) <= 0) continue;
        n = read(fds[0], buf, sizeof buf);
        pos = 0;
        if (n <= 0) {
          verdict = all_seen ? "ok" : "QEMU exited"; // with exits, the exit was the last thing waited for
          break;
        }
        fwrite(buf, 1, (size_t)n, log);
      }
      while (pos < n && !verdict) {
        char ch = buf[pos++];
        if (ch == '\r') continue;
        if (since_len == sizeof since) { // keep the newer half: a prompt is in recent output
          memmove(since, since + sizeof since / 2, sizeof since / 2);
          since_len = sizeof since / 2;
          since_cut = true;
        }
        if (stale)
          stale--; // seen for expects and failures, but not by a prompt= after the typing
        else
          since[since_len++] = ch;
        if (ch != '\n' && len < sizeof line - 1) {
          line[len++] = ch;
          continue;
        }
        if (ch != '\n') continue;
        line[len] = 0;
        len = 0;
        for (int k = 0; k < fail_count; k++)
          if (strstr(line, fail[k])) verdict = fmt("failure line: %s", line);
        if (!verdict && !all_seen && !prompt[next] &&
            (whole[next] ? strcmp(line, expect[next]) == 0 : strstr(line, expect[next]) != nullptr)) {
          next++;
          if (next == phase_last) all_seen = true, verdict = phase_exits ? nullptr : "ok";
          if (!all_seen && input[next].len && typed < next) break; // type it before what follows
        }
      }
      // A prompt has no newline after it, and may share its line with other
      // programs' output: it counts if it started any line since the last thing
      // typed.
      size_t plen = next < phase_last && prompt[next] ? strlen(expect[next]) : 0;
      for (size_t at = 0; !verdict && plen && at + plen <= since_len; at++) {
        bool line_start = at ? since[at - 1] == '\n' : !since_cut;
        if (!line_start || memcmp(since + at, expect[next], plen) != 0) continue;
        since_len = 0; // used: the next prompt= needs a prompt after this one
        since_cut = false;
        if (++next == phase_last) all_seen = true, verdict = phase_exits ? nullptr : "ok";
        break;
      }
    }
    kill(pid, SIGKILL);
    wait_ok(pid);
    close(fds[0]);
    close(keys[1]);
    if (q.fd >= 0) close(q.fd);
  }
  fclose(log);

  // What the guest was to leave on the host, in its copy of the share
  // (with or without a final newline).
  for (int k = 0; k < host_count && strcmp(verdict, "ok") == 0; k++) {
    const char *file = fmt("%s/%s", run_dir, host_file[k]);
    struct stat st;
    vx_str got = stat(file, &st) == 0 ? read_file(file) : (vx_str){"", 0};
    if (got.len && got.ptr[got.len - 1] == '\n') got.len--;
    if (got.len != strlen(host_text[k]) || memcmp(got.ptr, host_text[k], got.len) != 0)
      verdict =
          fmt("the host's %s is \"%.*s\", not \"%s\"", host_file[k], (int)got.len, got.ptr, host_text[k]);
  }

  // What the guest left on its FAT disk, checked by another implementation.
  if (fsck && strcmp(verdict, "ok") == 0) {
    cmd check = {.log = fmt("%s/fsck.log", run_dir)};
    cmd_addv(&check, (const char *const[]){FSCK_FAT, "-n", disk, nullptr});
    if (!run(&check)) verdict = fmt("fsck.fat -n found the FAT disk unsound (%s/fsck.log)", run_dir);
  }

  if (strcmp(verdict, "ok") == 0 && screen_missing) verdict = screen_missing;
  bool ok = strcmp(verdict, "ok") == 0;
  fprintf(stderr, "  TEST  %-11s %-8s %s (%.1f s)%s\n", name, a->name, ok ? "ok" : "FAIL",
          now_seconds() - run_start, ok ? "" : fmt(": %s; serial log in %s", verdict, log_path));
  return ok;
}

// Builds the image, then runs every scenario at once, each in its own QEMU.
// Runs the scenarios, a few at a time: each QEMU has 4 CPUs of its own, and
// with every architecture's scenarios at once, all at once would starve each
// other into their timeouts. Half the host's CPUs per architecture, at least 2.
static int test_slots; // scenarios at once per architecture; 0: half the host's CPUs

static bool test_arch(const arch *a, bool release) {
  if (!build_image(a, release)) return false;
  long cpus = sysconf(_SC_NPROCESSORS_ONLN);
  int slots = cpus >= 4 ? (int)(cpus / 2) : 2, running = 0;
  if (test_slots) slots = test_slots;
  pid_t pids[64] = {};
  bool ok = true;
  for (int i = 0; i < scenario_count || running > 0;) {
    if (i < scenario_count && running < slots) {
      pid_t pid = fork();
      if (pid < 0) die("fork failed");
      if (pid == 0) _exit(run_scenario(a, release, scenarios[i]) ? 0 : 2); // 1: died (die() exits 1)
      pids[i] = pid;
      running++, i++;
      continue;
    }
    int status;
    pid_t done = wait(&status);
    if (done < 0) {
      if (errno == EINTR) continue;
      die("wait failed");
    }
    running--;
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) continue;
    ok = false;
    if (WIFEXITED(status) && WEXITSTATUS(status) == 2) continue; // it failed, and said so
    for (int k = 0; k < scenario_count; k++)                     // it died before it could say anything
      if (pids[k] == done)
        fprintf(stderr, "  TEST  %-11s %-8s FAIL: the harness itself failed (see above)\n", scenarios[k],
                a->name);
  }
  return ok;
}

// Whether a scenario's record (its scenario= line) has the bare word `flag`.
static bool scenario_flag(const char *name, const char *flag) {
  vx_str text = read_file(fmt("tests/qemu/%s.ndb", name));
  const char *line = memmem(text.ptr, text.len, "\nscenario=", 10);
  if (!line) return false;
  const char *end = memchr(line + 1, '\n', text.len - (size_t)(line + 1 - text.ptr));
  size_t len = end ? (size_t)(end - line) : text.len - (size_t)(line - text.ptr);
  const char *word = fmt(" %s", flag);
  for (const char *at = line; (at = memmem(at, len - (size_t)(at - line), word, strlen(word)));) {
    at += strlen(word);
    if (at == line + len || *at == ' ') return true;
  }
  return false;
}

static int cmd_test(const arch *only, bool release) {
  if (scenario_count == 0) { // every scenario but the release gates, which run when named (install's)
    static file_list found;
    port dir = {.src = fmt("%s/tests", root)};
    collect(&found, &dir, (vx_str){"qemu", 4}, ".ndb");
    if (found.count > SCENARIO_MAX) die("more than %d scenarios in tests/qemu", SCENARIO_MAX);
    for (int i = 0; i < found.count; i++) {
      const char *base = strrchr(found.paths[i], '/') + 1;
      const char *name = fmt("%.*s", (int)(strlen(base) - 4), base);
      if (!scenario_flag(name, "release") && !scenario_flag(name, "bench"))
        scenarios[scenario_count++] = name;
    }
  }
  if (!build_vx9pserve() || !build_u9fs() || !build_vxfs())
    return 1; // once, before scenarios run in parallel
  // A scenario whose record says `alone` (install's and slots' minutes of
  // QEMU) runs after the rest, by itself, one architecture after the other:
  // beside them, under TCG, the others starve into their timeouts.
  static const char *apart[SCENARIO_MAX];
  int napart = 0, kept = 0;
  for (int i = 0; i < scenario_count; i++) {
    if (scenario_flag(scenarios[i], "alone"))
      apart[napart++] = scenarios[i];
    else
      scenarios[kept++] = scenarios[i];
  }
  scenario_count = kept;
  int st = scenario_count ? per_arch(only, release, test_arch) : 0;
  test_slots = 1;
  for (int k = 0; k < napart; k++)
    for (int i = 0; i < ARCH_COUNT; i++) {
      if (only && only != &ARCHES[i]) continue;
      scenarios[0] = apart[k], scenario_count = 1;
      if (!test_arch(&ARCHES[i], release)) st = 1;
    }
  return st;
}

static int cmd_qemu(const arch *a, bool release, qemu_opts o) {
  if (!build_image(a, release) || !build_vx9pserve()) return 1;
  struct stat st;
  o.share = "out/share"; // kept between runs, made once
  if (stat(o.share, &st) != 0) fresh_share(o.share);
  cmd c = {};
  qemu_cmd(&c, a, image_path(a, release), o);
  if (verbose) cmd_print(&c);
  fprintf(stderr, "build: starting QEMU; Ctrl-A X quits\n");
  execv(c.argv[0], (char *const *)c.argv);
  die("cannot run %s", c.argv[0]);
}

// --- vendor-check: every vendored tree matches its VENDOR.ndb record (docs/04 §3.1) ---

static const char *const VENDOR_KEYS[] = {
    // required
    "version", "upstream", "tree.sha256", "license", "adr", "reviewed.by", nullptr,
};
static const char *const VENDOR_OPTIONAL_KEYS[] = {
    "name",    "sha256",        "git.tree",       "signed.by", "port",
    "patches", "reviewed.date", "reviewed.scope", "subset",    nullptr,
};

static bool in_list(const char *const *list, vx_str key) {
  for (; *list; list++)
    if (strlen(*list) == key.len && memcmp(*list, key.ptr, key.len) == 0) return true;
  return false;
}

static void hex(char *out, const uint8_t *p, size_t n) {
  for (size_t i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", p[i]);
}

static file_list *tree_files;
static size_t tree_strip;
static bool tree_odd;

static int tree_visit(const char *path, const struct stat *st, int type, struct FTW *ftw) {
  (void)st;
  (void)ftw;
  if (type == FTW_D) return 0;
  if (type != FTW_F) {
    tree_odd = true;
    return 0;
  }
  if (tree_files->count == 4096) die("too many files in a vendored tree");
  tree_files->paths[tree_files->count++] = fmt("%s", path + tree_strip);
  return 0;
}

// The tree hash is what this gives, run inside the tree:
//   find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum
static bool tree_sha256(const char *dir, char out[65]) {
  static file_list files;
  files = (file_list){};
  tree_files = &files;
  tree_strip = strlen(dir) + 1;
  tree_odd = false;
  if (nftw(dir, tree_visit, 32, FTW_PHYS) != 0) die("cannot walk %s", dir);
  if (tree_odd) return false;
  qsort(files.paths, (size_t)files.count, sizeof files.paths[0], by_path);

  vx_sha256 tree = vx_sha256_begin();
  for (int i = 0; i < files.count; i++) {
    size_t mark = arena_used;
    vx_str data = read_file(fmt("%s/%s", dir, files.paths[i]));
    vx_sha256 h = vx_sha256_begin();
    vx_sha256_add(&h, data.ptr, data.len);
    uint8_t digest[32];
    vx_sha256_end(&h, digest);
    char line_hex[65];
    hex(line_hex, digest, 32);
    // A name with a newline (or any control byte) could forge lines of this
    // listing, which sha256sum would have escaped: such a name fails the check.
    for (const char *c = files.paths[i]; *c; c++)
      if ((unsigned char)*c < 0x20 || *c == 0x7f)
        die("%s/%s: a control character in a file name", dir, files.paths[i]);
    const char *line = fmt("%s  ./%s\n", line_hex, files.paths[i]);
    vx_sha256_add(&tree, line, strlen(line));
    arena_used = mark; // the file's bytes are not needed again
  }
  uint8_t digest[32];
  vx_sha256_end(&tree, digest);
  hex(out, digest, 32);
  return true;
}

static int cmd_vendor_check(void) {
  const char *path = "third_party/VENDOR.ndb";
  vx_ndb_reader r = {.src = read_file(path), .scratch = alloc(64 << 10), .scratch_cap = 64 << 10};
  const char *names[256];
  int count = 0;
  bool ok = true;
  for (;;) {
    vx_ndb_record rec;
    vx_ndb_result res = vx_ndb_next(&r, &rec);
    if (res == VX_NDB_END) break;
    if (res == VX_NDB_ERROR) die("%s:%zu: %s", path, r.error_line, r.error);
    if (!vx_ndb_has(&rec, "name")) die("%s:%zu: a record must start with name=", path, rec.line);
    const char *name = str_dup(vx_ndb_get(&rec, "name"));
    if (count < 256) names[count++] = name;

    // Unknown keys fail, as a verifier fails closed: `reviewed.by=A Name` without
    // quotes would otherwise pass as reviewed.by=A plus a flag called Name.
    for (int k = 0; k < rec.count; k++) {
      vx_str key = rec.tuples[k].key;
      if (!in_list(VENDOR_KEYS, key) && !in_list(VENDOR_OPTIONAL_KEYS, key)) {
        fprintf(stderr, "  VENDOR %s: unknown key %s (line %zu); quote values that hold spaces\n", name,
                str_dup(key), rec.line);
        ok = false;
      }
    }
    for (const char *const *k = VENDOR_KEYS; *k; k++)
      if (!vx_ndb_get(&rec, *k).len) {
        fprintf(stderr, "  VENDOR %s: missing %s=\n", name, *k);
        ok = false;
      }
    if (!vx_ndb_get(&rec, "sha256").len && !vx_ndb_get(&rec, "git.tree").len) { // a release, or a pinned tree
      fprintf(stderr, "  VENDOR %s: missing sha256= (or git.tree=, for an import with no release)\n", name);
      ok = false;
    }
    const char *adr = str_dup(vx_ndb_get(&rec, "adr"));
    if (*adr && !exists(adr)) {
      fprintf(stderr, "  VENDOR %s: %s does not exist\n", name, adr);
      ok = false;
    }
    vx_str port_file = vx_ndb_get(&rec, "port");
    if (port_file.len && !exists(str_dup(port_file))) {
      fprintf(stderr, "  VENDOR %s: %s does not exist\n", name, str_dup(port_file));
      ok = false;
    }

    const char *dir = fmt("third_party/%s", name);
    char got[65];
    struct stat st;
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
      fprintf(stderr, "  VENDOR %s: %s is missing\n", name, dir);
      ok = false;
    } else if (!tree_sha256(dir, got)) {
      fprintf(stderr, "  VENDOR %s: the tree holds something other than files and directories\n", name);
      ok = false;
    } else if (strcmp(got, str_dup(vx_ndb_get(&rec, "tree.sha256"))) != 0) {
      fprintf(stderr, "  VENDOR %s: the tree does not match tree.sha256 (it hashes to %s)\n", name, got);
      ok = false;
    } else {
      fprintf(stderr, "  VENDOR %s %s: tree matches\n", name, str_dup(vx_ndb_get(&rec, "version")));
    }
    if (strcmp(str_dup(vx_ndb_get(&rec, "reviewed.by")), "pending") == 0)
      fprintf(stderr, "  VENDOR %s: warning: review pending\n", name);
  }

  // Every directory under third_party/ has a record, and nothing else is
  // there but VENDOR.ndb: no files, links or other entries outside a record.
  DIR *d = opendir("third_party");
  if (!d) die("cannot read third_party/");
  for (struct dirent *e; (e = readdir(d));) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0 || strcmp(e->d_name, "VENDOR.ndb") == 0)
      continue;
    struct stat st;
    if (lstat(fmt("third_party/%s", e->d_name), &st) != 0 || !S_ISDIR(st.st_mode)) {
      fprintf(stderr, "  VENDOR third_party/%s is not a vendored tree (a directory with a record)\n",
              e->d_name);
      ok = false;
      continue;
    }
    bool found = false;
    for (int i = 0; i < count; i++) found = found || strcmp(names[i], e->d_name) == 0;
    if (!found) {
      fprintf(stderr, "  VENDOR third_party/%s has no record in %s\n", e->d_name, path);
      ok = false;
    }
  }
  closedir(d);
  return ok ? 0 : 1;
}

static int cmd_all(const arch *only, bool release) {
  if (!build_vx9pserve()) return 1;
  return per_arch(only, release, build_arch);
}

// ---------------------------------------------------------------------------
// loc: the line-count ledger (docs/04 §3.2)

typedef struct component {
  char name[96];
  long lines;
  bool vendored;
} component;

static component components[256];
static int component_count;
static long asm_lines[ARCH_COUNT];

static const char *const CODE_EXTENSIONS[] = {".c", ".h", ".S", ".s", ".ld", ".def", nullptr};

static bool is_code(const char *path) {
  const char *dot = strrchr(path, '.');
  if (!dot) return false;
  if (strncmp(dot, ".asm", 4) == 0) return true; // nasm and Limine's .asm_<arch> files
  for (const char *const *e = CODE_EXTENSIONS; *e; e++)
    if (strcmp(dot, *e) == 0) return true;
  return false;
}

static long count_lines(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return 0;
  long n = 0;
  char line[4096];
  while (fgets(line, sizeof line, f))
    if (line[strspn(line, " \t\r\n")]) n++;
  fclose(f);
  return n;
}

static component *component_for(const char *name, bool vendored) {
  for (int i = 0; i < component_count; i++)
    if (strcmp(components[i].name, name) == 0) return &components[i];
  if (component_count == 256) die("too many components");
  component *c = &components[component_count++];
  snprintf(c->name, sizeof c->name, "%s", name);
  c->vendored = vendored;
  return c;
}

// Components are the first path segment, or the first two under these directories.
static const char *const GROUPED[] = {"lib",  "servers",     "drivers", "apps",
                                      "host", "third_party", "ports",   nullptr};

// Made from a vendored tree, once, and counted with it.
static bool is_generated(const char *path) { return strncmp(path, "ports/musl/generated/", 21) == 0; }

static int loc_visit(const char *path, const struct stat *st, int type, struct FTW *ftw) {
  (void)st;
  (void)ftw;
  if (path[0] == '.' && path[1] == '/') path += 2;
  if (type == FTW_D) {
    if (!strcmp(path, "out") || !strcmp(path, ".git") || !strcmp(path, "docs")) return FTW_SKIP_SUBTREE;
    return FTW_CONTINUE;
  }
  if (type != FTW_F || !is_code(path)) return FTW_CONTINUE;

  char name[96];
  const char *slash = strchr(path, '/');
  if (!slash) {
    snprintf(name, sizeof name, "%s", strcmp(path, "build.c") == 0 ? "build" : path);
  } else {
    size_t len = (size_t)(slash - path);
    for (const char *const *g = GROUPED; *g; g++) {
      if (strlen(*g) == len && strncmp(path, *g, len) == 0) {
        const char *second = strchr(slash + 1, '/');
        if (second) len = (size_t)(second - path);
        break;
      }
    }
    snprintf(name, sizeof name, "%.*s", (int)len, path);
  }
  if (is_generated(path)) snprintf(name, sizeof name, "ports/musl/generated");

  long n = count_lines(path);
  component_for(name, strncmp(path, "third_party/", 12) == 0 || is_generated(path))->lines += n;

  const char *dot = strrchr(path, '.');
  for (int i = 0; i < ARCH_COUNT; i++) {
    char prefix[64];
    snprintf(prefix, sizeof prefix, "kernel/arch/%s/", ARCHES[i].name);
    if (strncmp(path, prefix, strlen(prefix)) == 0 && (!strcmp(dot, ".S") || !strcmp(dot, ".s")))
      asm_lines[i] += n;
  }
  return FTW_CONTINUE;
}

static int by_name(const void *a, const void *b) {
  const component *x = a, *y = b;
  if (x->vendored != y->vendored) return x->vendored - y->vendored;
  return strcmp(x->name, y->name);
}

static int count_syscalls(void) {
  FILE *f = fopen("abi/vx/syscalls.def", "r");
  if (!f) return 0;
  int n = 0;
  char line[512];
  while (fgets(line, sizeof line, f))
    if (strncmp(line, "VX_SYSCALL(", 11) == 0) n++;
  fclose(f);
  return n;
}

static int cmd_loc(void) {
  if (nftw(".", loc_visit, 32, FTW_PHYS | FTW_ACTIONRETVAL) != 0) die("cannot walk the tree");
  qsort(components, (size_t)component_count, sizeof components[0], by_name);

  long first_party = 0, vendored = 0, kernel = 0;
  for (int i = 0; i < component_count; i++) {
    const component *c = &components[i];
    printf("%-32s %8ld%s\n", c->name, c->lines, c->vendored ? "  vendored" : "");
    if (c->vendored)
      vendored += c->lines;
    else
      first_party += c->lines;
    if (strcmp(c->name, "kernel") == 0) kernel = c->lines;
  }
  printf("\n");
  for (int i = 0; i < ARCH_COUNT; i++)
    printf("%-32s %8ld\n", fmt("assembly, %s kernel", ARCHES[i].name), asm_lines[i]);
  printf("%-32s %8d\n", "syscalls", count_syscalls());
  printf("\n%-32s %8ld\n%-32s %8ld\n%-32s %8ld\n", "first-party", first_party, "vendored", vendored, "total",
         first_party + vendored);

  if (kernel > KERNEL_LOC_BUDGET) {
    fprintf(stderr, "build: the kernel is %ld lines; the budget is %d (docs/01 §1)\n", kernel,
            KERNEL_LOC_BUDGET);
    return 1;
  }
  return 0;
}

// ---------------------------------------------------------------------------

// Reproducible builds (docs/04 §7): every timestamp written into an output, such
// as the FAT entries mtools writes, is SOURCE_DATE_EPOCH. If the environment does
// not set it, it is the time of the last commit.
static void set_source_date_epoch(void) {
  if (getenv("SOURCE_DATE_EPOCH")) return;
  char *out = exists("/usr/bin/git")
                  ? run_capture((const char *const[]){"/usr/bin/git", "log", "-1", "--format=%ct", nullptr})
                  : nullptr;
  if (out) {
    out[strcspn(out, "\n")] = 0;
    if (*out) setenv("SOURCE_DATE_EPOCH", out, 1);
  }
  if (!getenv("SOURCE_DATE_EPOCH")) setenv("SOURCE_DATE_EPOCH", "315532800", 1); // 1980-01-01, FAT's epoch
}

// ---------------------------------------------------------------------------
// check: what CI's first job runs (docs/04 §4)

static const char *const HOST_TEST_FLAGS[] = {
    "-std=c23",
    "-g",
    "-O1",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wshadow",
    "-Wvla",
    "-Wimplicit-fallthrough",
    "-fsanitize=address,undefined",
    "-fno-sanitize-recover=all",
    "-fno-omit-frame-pointer", // as the house builds everything (05 §4)
    "-Wl,--build-id=sha1",     // as programs are linked: debug_test reads its own
    "-fno-pie",                // and not PIE, as programs are not: eval_test reads its own memory
    "-no-pie",                 // at the addresses its DWARF has
    nullptr,
};

// The ISO the isofs tests read (tests/host/iso_test.c, tests/qemu/isofs.ndb),
// made by write_iso with Rock Ridge and Joliet: a long name (past one
// record: a continuation area), UTF-8 (past the BMP: a surrogate pair in
// Joliet), two names differing only in case (one ISO 9660 name gets ~1), a
// deep directory, symbolic links (relative, absolute, up a level), and a
// file of many sectors.
static const char ISO_LONG_NAME[] =
    "A Long Mixed-Case Name That Goes On And On, Past What One Directory Record Can Hold, So Its Rock "
    "Ridge NM Entry Has To Continue In The Directory's Continuation Area, Which Is The Point Of It.txt";

static void make_test_iso(const char *path) {
  const char *src = fmt("%s.src", path);
  const char *dirs[] = {"deep/er/still/deeper", "dir with spaces"};
  for (size_t i = 0; i < sizeof dirs / sizeof *dirs; i++) mkdirs(fmt("%s/%s", src, dirs[i]));
  static const struct {
    const char *path, *text, *link;
  } entries[] = {
      {"README.txt", "readme\n", nullptr},
      {ISO_LONG_NAME, "long\n", nullptr},
      {"\xc3\x9cn\xc3\xaf"
       "code file.txt",
       "unicode\n", nullptr},
      {"\xf0\x9f\x98\x80 smile.txt", "smile\n", nullptr},
      {"deep/er/still/deeper/file.txt", "deep\n", nullptr},
      {"dir with spaces/same name.txt", "lower\n", nullptr},
      {"dir with spaces/Same Name.txt", "upper\n", nullptr},
      {"link-to-readme", nullptr, "README.txt"},
      {"abs-link", nullptr, "/boot/limine/limine.conf"},
      {"deep/er/up-link", nullptr, "../../dir with spaces/./same name.txt"},
  };
  iso_file files[16];
  int n = 0;
  for (size_t i = 0; i < sizeof entries / sizeof *entries; i++) {
    files[n] = (iso_file){.path = entries[i].path, .link = entries[i].link};
    if (entries[i].text) {
      files[n].from = fmt("%s/f%zu", src, i);
      write_file(files[n].from, (vx_str){entries[i].text, strlen(entries[i].text)});
    }
    n++;
  }
  static char big[300'000];
  for (size_t i = 0; i < sizeof big; i++) big[i] = (char)((i * 7 + i / 251) & 0xff);
  files[n] = (iso_file){.path = "big.bin", .from = fmt("%s/big", src)};
  write_file(files[n++].from, (vx_str){big, sizeof big});
  const char *boot = fmt("%s/boot.img", src); // El Torito needs one; nothing boots it
  static char sectors[4096];
  write_file(boot, (vx_str){sectors, sizeof sectors});
  write_iso(path, boot, files, n, 0x1234'5678);
}

// The FAT images tests/host/fat_test.c reads: out/host/fat12.img, fat16.img
// and fat32.img, each made by mtools (not by the code under test) with the
// same tree: short and long names, UTF-8 (mtools writes none past the BMP;
// fat_test patches that in), a file of many
// clusters, a directory of many entries, a nested directory, a deleted
// entry, and a file whose time is known (2001-02-03 04:05:06, written with
// TZ=UTC since FAT keeps local time).
static bool make_fat_fixtures(void) {
  const char *src = "out/host/fat-src";
  const char *dirs[] = {"A Long Directory Name", "A Long Directory Name/sub dir", "many"};
  for (size_t i = 0; i < sizeof dirs / sizeof *dirs; i++) mkdirs(fmt("%s/%s", src, dirs[i]));
  write_file(fmt("%s/SHORT.TXT", src), VX_STR("hello\n"));
  write_file(fmt("%s/lower.txt", src), VX_STR("lower\n"));
  write_file(fmt("%s/A Long Directory Name/\xc3\x9cn\xc3\xaf"
                 "code file name with spaces.txt",
                 src),
             VX_STR("unicode\n"));
  write_file(fmt("%s/A Long Directory Name/sub dir/deep.txt", src), VX_STR("deep\n"));
  write_file(fmt("%s/gone.txt", src), VX_STR("gone\n"));
  static char big[300'000];
  for (size_t i = 0; i < sizeof big; i++) big[i] = (char)((i * 7 + i / 251) & 0xff);
  write_file(fmt("%s/big.bin", src), (vx_str){big, sizeof big});
  for (int i = 0; i < 100; i++) write_file(fmt("%s/many/f%03d.txt", src, i), (vx_str){fmt("f%03d\n", i), 5});
  struct timespec when[2] = {{.tv_sec = 981'173'106}, {.tv_sec = 981'173'106}}; // 2001-02-03 04:05:06 UTC
  if (utimensat(AT_FDCWD, fmt("%s/SHORT.TXT", src), when, 0) != 0) return false;
  const char *tz = getenv("TZ");
  setenv("TZ", "UTC", 1);
  const struct {
    const char *name, *label;
    const char *const *geometry;
  } kinds[] = {
      {"fat12", "SMALL", (const char *const[]){"-T", "2880", "-h", "2", "-s", "18", nullptr}},
      {"fat16", "MIDDLE", (const char *const[]){"-T", "65536", "-h", "64", "-s", "32", nullptr}},
      {"fat32", "LARGE", (const char *const[]){"-T", "131072", "-h", "64", "-s", "32", "-F", nullptr}},
  };
  bool ok = true;
  for (size_t k = 0; ok && k < sizeof kinds / sizeof *kinds; k++) {
    const char *img = fmt("out/host/%s.img", kinds[k].name);
    unlink(img);
    cmd c = {};
    cmd_addv(&c, (const char *const[]){MFORMAT, "-C", "-i", img, "-v", kinds[k].label, nullptr});
    cmd_addv(&c, kinds[k].geometry);
    cmd_add(&c, "::");
    ok = run(&c);
    cmd cp = {};
    cmd_addv(&cp, (const char *const[]){MCOPY, "-s", "-m", "-i", img, nullptr});
    const char *top[] = {"SHORT.TXT", "lower.txt", "A Long Directory Name", "gone.txt", "big.bin", "many"};
    for (size_t i = 0; i < sizeof top / sizeof *top; i++) cmd_add(&cp, fmt("%s/%s", src, top[i]));
    cmd_add(&cp, "::/");
    ok = ok && run(&cp) && mtools(MDEL, img, (const char *const[]){"::/gone.txt", nullptr});
  }
  if (tz)
    setenv("TZ", tz, 1);
  else
    unsetenv("TZ");
  return ok;
}

// Monocypher for the host's tests and tools: its two files, each an object
// (they share static names), its own flags, the tests' sanitizers. Rebuilt
// when its sources change.
static const char *const HOST_MONOCYPHER[] = {"out/host/monocypher.o", "out/host/monocypher-ed25519.o",
                                              nullptr};

// The font port (ports/font: stb_truetype and kb_text_shape), built for
// the host's tests and tools with its own flags, under the sanitizers.
static const char *const HOST_FONT[] = {"out/host/font-stbtt.o", "out/host/font-kbts.o", nullptr};
static const char *const HOST_FONT_INCLUDES[] = {
    "-isystem", "third_party/stb_truetype", "-isystem", "third_party/kb_text_shape", "-Iports/font", nullptr};

static bool host_font(void) {
  static const char *const SRCS[] = {"ports/font/stbtt.c", "ports/font/kbts.c"};
  mkdirs("out/host");
  for (int i = 0; i < 2; i++) {
    struct stat out, src;
    if (stat(HOST_FONT[i], &out) == 0 && stat(SRCS[i], &src) == 0 && !newer(&src, &out)) continue;
    cmd cc = {};
    cmd_addv(&cc, (const char *const[]){CLANG, "-std=c11", "-O2", "-g", "-w", "-fsanitize=address,undefined",
                                        "-fno-omit-frame-pointer", "-fno-pie", nullptr});
    cmd_addv(&cc, HOST_FONT_INCLUDES);
    cmd_addv(&cc, (const char *const[]){"-c", "-o", HOST_FONT[i], SRCS[i], nullptr});
    if (!run(&cc)) return false;
  }
  return true;
}

static bool host_monocypher(void) {
  static const char *const SRCS[] = {"third_party/monocypher/src/monocypher.c",
                                     "third_party/monocypher/src/optional/monocypher-ed25519.c"};
  mkdirs("out/host");
  for (int i = 0; i < 2; i++) {
    struct stat out, src;
    if (stat(HOST_MONOCYPHER[i], &out) == 0 && stat(SRCS[i], &src) == 0 && !newer(&src, &out)) continue;
    cmd cc = {};
    cmd_addv(&cc, (const char *const[]){CLANG, "-std=c99", "-O2", "-g", "-w", "-fsanitize=address,undefined",
                                        "-fno-omit-frame-pointer", "-fno-pie", "-Ithird_party/monocypher/src",
                                        "-c", "-o", HOST_MONOCYPHER[i], SRCS[i], nullptr});
    if (!run(&cc)) return false;
  }
  return true;
}

// Each tests/host/*_test.c is one translation unit: the library it includes and
// its checks. It is built for the host under ASan and UBSan, and run.
static bool check_host_tests(void) {
  static file_list tests;
  port dir = {.src = fmt("%s/tests", root)};
  collect(&tests, &dir, (vx_str){"host", 4}, "_test.c");
  mkdirs("out/host");
  bool ok = make_fat_fixtures();
  if (!ok) fprintf(stderr, "  HOST  cannot make the FAT images\n");
  make_test_iso("out/host/test.iso");
  for (int i = 0; i < tests.count; i++) {
    const char *base = strrchr(tests.paths[i], '/') + 1;
    const char *name = fmt("%.*s", (int)(strlen(base) - 2), base);
    const char *exe = fmt("out/host/%s", name);
    cmd cc = {};
    cmd_add(&cc, CLANG);
    cmd_addv(&cc, HOST_TEST_FLAGS);
    cmd_add(&cc, "-o");
    cmd_add(&cc, exe);
    cmd_add(&cc, fmt("tests/%s", tests.paths[i]));
    // A test that says "// host-links: monocypher" links Monocypher, built for
    // the host with its own flags (ADR-0032), not the house's; "// host-links:
    // font", the font port (stb_truetype and kb_text_shape) and -lm.
    vx_str text = read_file(fmt("tests/%s", tests.paths[i]));
    if (memmem(text.ptr, text.len, "// host-links: font", 19)) {
      if (!host_font()) ok = false;
      cmd_addv(&cc, HOST_FONT_INCLUDES);
      cmd_addv(&cc, HOST_FONT);
      cmd_add(&cc, "-lm");
    }
    if (memmem(text.ptr, text.len, "// host-links: monocypher", 25)) {
      if (!host_monocypher()) ok = false;
      cmd_addv(&cc, (const char *const[]){"-isystem", "third_party/monocypher/src", "-isystem",
                                          "third_party/monocypher/src/optional", nullptr});
      cmd_addv(&cc, HOST_MONOCYPHER);
    }
    cmd run_test = {};
    cmd_add(&run_test, exe);
    bool passed = run(&cc) && run(&run_test);
    fprintf(stderr, "  HOST  %-16s %s\n", name, passed ? "ok" : "FAIL");
    ok = ok && passed;
  }
  // What fat_test wrote, checked by another implementation.
  static const char *const written[] = {"fat12-written", "fat16-written", "fat32-written", "fat32-formatted"};
  for (size_t i = 0; i < sizeof written / sizeof *written; i++) {
    const char *k = written[i];
    const char *img = fmt("out/host/%s.img", k);
    cmd fsck = {.log = fmt("out/host/%s-fsck.log", k)};
    cmd_addv(&fsck, (const char *const[]){FSCK_FAT, "-n", img, nullptr});
    bool clean = exists(img) && run(&fsck);
    fprintf(stderr, "  FSCK  %-16s %s\n", k, clean ? "ok" : "FAIL");
    ok = ok && clean;
  }
  // write_iso's Joliet tree, read by another implementation.
  cmd list = {.log = "out/host/test-iso-7z.log"};
  cmd_addv(&list, (const char *const[]){SEVEN_ZIP, "l", "-slt", "out/host/test.iso", nullptr});
  bool listed = run(&list);
  vx_str got = listed ? read_file("out/host/test-iso-7z.log") : (vx_str){"", 0};
  static const char *const want[] = {
      "Path = \xf0\x9f\x98\x80 smile.txt\n",
      "Path = \xc3\x9cn\xc3\xaf\x63ode file.txt\n",
      "Path = dir with spaces/Same Name.txt\n",
      "Path = dir with spaces/same name.txt\n",
      "Path = deep/er/still/deeper/file.txt\n",
      "Path = A Long Mixed-Case Name That Goes On And On, Past What One Direct\n"};
  for (size_t i = 0; i < sizeof want / sizeof *want && listed; i++)
    listed = memmem(got.ptr, got.len, want[i], strlen(want[i])) != nullptr;
  fprintf(stderr, "  7Z    test.iso         %s\n", listed ? "ok" : "FAIL (out/host/test-iso-7z.log)");
  return ok && listed;
}

// Each tests/fuzz/*_fuzz.c is a libFuzzer target, built under ASan and UBSan.
// It replays its seeds (tests/fuzz/corpus/NAME), then fuzzes for a few
// seconds into out/fuzz/NAME, which persists, so each check starts where the
// last one stopped. A crash is written to out/fuzz/ and fails the check; the
// fuzzer's own output goes to out/fuzz/NAME.log.
static constexpr int FUZZ_SECONDS = 10;

static bool check_fuzz(void) {
  static file_list targets;
  port dir = {.src = fmt("%s/tests", root)};
  collect(&targets, &dir, (vx_str){"fuzz", 4}, "_fuzz.c");
  bool ok = true;
  for (int i = 0; i < targets.count; i++) {
    const char *base = strrchr(targets.paths[i], '/') + 1;
    const char *name = fmt("%.*s", (int)(strlen(base) - 7), base);
    const char *exe = fmt("out/fuzz/%s_fuzz", name);
    const char *corpus = fmt("out/fuzz/%s", name);
    mkdirs(corpus);
    cmd cc = {};
    cmd_add(&cc, CLANG);
    cmd_addv(&cc, HOST_TEST_FLAGS);
    cmd_addv(&cc, (const char *const[]){"-fsanitize=fuzzer", "-o", exe, nullptr});
    cmd_add(&cc, fmt("tests/%s", targets.paths[i]));
    vx_str text = read_file(fmt("tests/%s", targets.paths[i]));
    if (memmem(text.ptr, text.len, "// host-links: monocypher", 25)) { // as the host tests do
      if (!host_monocypher()) ok = false;
      cmd_addv(&cc, (const char *const[]){"-isystem", "third_party/monocypher/src", "-isystem",
                                          "third_party/monocypher/src/optional", nullptr});
      cmd_addv(&cc, HOST_MONOCYPHER);
    }
    cmd fuzz = {.log = fmt("out/fuzz/%s.log", name)};
    cmd_add(&fuzz, exe);
    cmd_add(&fuzz, fmt("-max_total_time=%d", FUZZ_SECONDS));
    cmd_addv(&fuzz, (const char *const[]){"-max_len=4096", "-print_final_stats=0", nullptr});
    // A crash is kept in the corpus, named for its target, so every later check replays it until fixed.
    cmd_add(&fuzz, fmt("-artifact_prefix=%s/crash-", corpus));
    cmd_add(&fuzz, corpus);
    cmd_add(&fuzz, fmt("tests/fuzz/corpus/%s", name));
    bool passed = run(&cc) && run(&fuzz);
    fprintf(stderr, "  FUZZ  %-16s %s\n", name, passed ? "ok" : fmt("FAIL: see %s", fuzz.log));
    ok = ok && passed;
  }
  return ok;
}

// Every translation unit of the OS tree, with the flags it is built with.
typedef struct unit {
  const char *name, *source;
  const char *const *flags[5];
} unit;

static const char *const HOST_C23[] = {"-std=c23", nullptr};

static constexpr int MAX_UNITS = 512;

// The next free slot in a units array of MAX_UNITS.
static int unit_slot(int *n) {
  if (*n == MAX_UNITS) die("more than %d units to check: raise MAX_UNITS", MAX_UNITS);
  return (*n)++;
}

static int os_units(unit *units, bool with_host_tests) {
  int n = 0;
  for (int i = 0; i < ARCH_COUNT; i++) {
    units[unit_slot(&n)] = (unit){
        fmt("kernel %s", ARCHES[i].name), "kernel/kernel.c", {ARCHES[i].flags, HOUSE_FLAGS, KERNEL_FLAGS}};
    for (int k = 0; k < USER_PROGRAM_COUNT; k++) {
      const program *p = &USER_PROGRAMS[k];
      if (!program_for(p, &ARCHES[i])) continue;
      if (p->native) { // ISO C against the debug sysroot, if this machine has one (6e2b2)
        const char *sys = fmt("%s/%s", root, sysroot_dir(&ARCHES[i], false));
        bool cxx = native_cxx(p);
        if (!exists(fmt("%s/usr/lib/%s", sys, cxx ? "libc++.a" : "libc.a"))) continue;
        size_t nlf = 0;
        while (p->lib_flags && p->lib_flags[nlf]) nlf++;
        const char **f = alloc((5 + nlf) * sizeof *f);
        f[0] = fmt("--config-system-dir=%s", sys), f[1] = fmt("--target=%s", sysroot_triple(&ARCHES[i]));
        f[2] = cxx ? "-std=c++23" : "-std=c23";
        int nf = 3;
        if (cxx) f[nf++] = "-stdlib=libc++"; // the C++ file's, which clang does not read
        for (size_t l = 0; l < nlf; l++) f[nf++] = p->lib_flags[l];
        f[nf] = nullptr;
        static const char *const CXX_HOUSE[] = {"-Wall", "-Wextra", "-Werror", "-Wshadow", "-g", nullptr};
        units[unit_slot(&n)] =
            (unit){fmt("%s %s", p->name, ARCHES[i].name), p->source, {f, cxx ? CXX_HOUSE : HOUSE_FLAGS}};
        continue;
      }
      unit *u = &units[unit_slot(&n)];
      *u = (unit){fmt("%s %s", p->name, ARCHES[i].name), p->source, {}};
      u->flags[0] = p->posix ? posix_flags(&ARCHES[i]) : ARCHES[i].user_flags;
      u->flags[1] = HOUSE_FLAGS;
      u->flags[2] = p->posix ? POSIX_PROGRAM_FLAGS : USER_FLAGS;
      u->flags[3] = p->lib_flags;
      u->flags[4] = usage_flags(p);
    }
    units[unit_slot(&n)] = (unit){fmt("libc-vx %s", ARCHES[i].name),
                                  "ports/musl/vx/backend.c",
                                  {posix_flags(&ARCHES[i]), HOUSE_FLAGS, POSIX_BACKEND_FLAGS}};
    units[unit_slot(&n)] = (unit){fmt("libvx %s", ARCHES[i].name),
                                  "lib/vx-rt/libvx.c",
                                  {ARCHES[i].user_flags, HOUSE_FLAGS, USER_FLAGS}};
    units[unit_slot(&n)] = (unit){fmt("crt1 %s", ARCHES[i].name),
                                  "ports/musl/vx/crt1.c",
                                  {posix_flags(&ARCHES[i]), HOUSE_FLAGS, POSIX_BACKEND_FLAGS}};
  }
  units[unit_slot(&n)] = (unit){"build", "build.c", {HOST_C23}};
  if (with_host_tests) {
    static file_list tests;
    tests = (file_list){};
    port dir = {.src = fmt("%s/tests", root)};
    collect(&tests, &dir, (vx_str){"host", 4}, "_test.c");
    collect(&tests, &dir, (vx_str){"fuzz", 4}, "_fuzz.c");
    for (int i = 0; i < tests.count; i++)
      units[unit_slot(&n)] = (unit){tests.paths[i] + 5,
                                    fmt("tests/%s", tests.paths[i]),
                                    {HOST_C23, MONOCYPHER_USE_FLAGS, HOST_FONT_INCLUDES}};
  }
  return n;
}

// Runs one tool over each unit, one at a time so each report reads whole: the
// command `before`, the unit's flags, `after`, then the source. A tool that
// takes its source first, with the compiler flags after a separator (clang-tidy
// and `--`), passes that separator instead.
// ./build check [STAGE ...] [UNIT ...]: the stages named (all without one)
// and, for the analyzer and tidy, the units named (all without one), so a
// fix to one file is checked in seconds rather than the whole tree's minutes.
static const char *const CHECK_STAGES[] = {"man",    "host", "fuzz", "vxfs", "vendor",
                                           "format", "sa",   "tidy", "time", nullptr};
static const char *check_args[64];
static int check_arg_count;

static bool check_is_stage(const char *w) {
  for (int i = 0; CHECK_STAGES[i]; i++)
    if (strcmp(w, CHECK_STAGES[i]) == 0) return true;
  return false;
}

// Whether the words name this stage, or no stage at all.
static bool check_wants(const char *stage) {
  bool any = false;
  for (int i = 0; i < check_arg_count; i++) {
    if (!check_is_stage(check_args[i])) continue;
    if (strcmp(check_args[i], stage) == 0) return true;
    any = true;
  }
  return !any;
}

static bool check_is_arch(const char *w) {
  for (int a = 0; a < ARCH_COUNT; a++)
    if (strcmp(w, ARCHES[a].name) == 0) return true;
  return false;
}

// Whether the words name this unit ("rc x86_64": its program, and its
// architecture if one is named), or no program at all.
static bool check_wants_unit(const char *name) {
  size_t prog = strcspn(name, " ");
  bool any_prog = false, prog_ok = false, any_arch = false, arch_ok = false;
  for (int i = 0; i < check_arg_count; i++) {
    const char *w = check_args[i];
    if (check_is_stage(w)) continue;
    if (check_is_arch(w)) {
      any_arch = true;
      arch_ok = arch_ok || strcmp(name + prog + (name[prog] == ' '), w) == 0;
    } else {
      any_prog = true;
      prog_ok = prog_ok || (strlen(w) == prog && memcmp(w, name, prog) == 0);
    }
  }
  return (!any_prog || prog_ok) && (!any_arch || arch_ok);
}

static int check_units_run; // how many units check_units ran: a filter that matches none fails

static bool check_units(const char *tag, bool with_host_tests, const char *const *before,
                        const char *const *after, const char *separator) {
  static unit units[MAX_UNITS];
  int n = os_units(units, with_host_tests);
  bool ok = true;
  for (int i = 0; i < n; i++) {
    if (!check_wants_unit(units[i].name)) continue;
    check_units_run++;
    cmd c = {};
    cmd_addv(&c, before);
    if (separator) {
      cmd_add(&c, units[i].source);
      cmd_add(&c, separator);
    }
    for (int f = 0; f < 5; f++)
      if (units[i].flags[f]) cmd_addv(&c, units[i].flags[f]);
    cmd_addv(&c, after);
    if (!separator) cmd_add(&c, units[i].source);
    bool passed = run(&c);
    fprintf(stderr, "  %-5s %-16s %s\n", tag, units[i].name, passed ? "ok" : "FAIL");
    ok = ok && passed;
  }
  return ok;
}

// The clang static analyzer, with each finding an error.
static bool check_analyzer(void) {
  static const char *const BEFORE[] = {CLANG, nullptr};
  static const char *const AFTER[] = {
      "--analyze", "--analyzer-output", "text", "-Xclang", "-analyzer-werror", "-o", "/dev/null", nullptr,
  };
  return check_units("SA", false, BEFORE, AFTER, nullptr);
}

// clang-tidy with the house checks (.clang-tidy), each finding an error.
static bool check_tidy(void) {
  check_version(CLANG_TIDY, CLANG_TIDY_VERSION);
  static const char *const BEFORE[] = {CLANG_TIDY, "--quiet", nullptr};
  static const char *const AFTER[] = {nullptr};
  return check_units("TIDY", true, BEFORE, AFTER, "--");
}

// The house format (.clang-format, 04 §1.1) over every first-party C file.
// Vendored code keeps its upstream format.
static const char *const FORMATTED_DIRS[] = {
    "abi",        "kernel",     "lib",          "servers", "drivers",       "cmd",         "tests/host",
    "tests/fuzz", "tests/user", "tests/kernel", "host",    "ports/musl/vx", "tests/posix", nullptr};

static bool check_format(void) {
  check_version(CLANG_FORMAT, CLANG_FORMAT_VERSION);
  static file_list files;
  files = (file_list){};
  port tree = {.src = root};
  for (const char *const *d = FORMATTED_DIRS; *d; d++) {
    collect(&files, &tree, (vx_str){*d, strlen(*d)}, ".c");
    collect(&files, &tree, (vx_str){*d, strlen(*d)}, ".h");
  }
  cmd c = {};
  cmd_add(&c, CLANG_FORMAT);
  cmd_addv(&c, (const char *const[]){"--dry-run", "--Werror", "build.c", nullptr});
  for (int i = 0; i < files.count; i++) cmd_add(&c, files.paths[i]);
  bool ok = run(&c);
  fprintf(stderr, "  FMT   %d files %s\n", files.count + 1, ok ? "ok" : "FAIL: run clang-format -i on them");
  return ok;
}

// The build-time budget (04 §3.2): a clean build of the kernel under 1 s, and of
// all first-party code under 10 s. Every first-party build is clean (no
// incremental state), so this times the ordinary build steps.
static bool check_build_time(void) {
  double total = 0, worst_kernel = 0;
  bool ok = true;
  for (int i = 0; i < ARCH_COUNT; i++) {
    double t0 = now_seconds();
    ok = build_kernel(&ARCHES[i], false) && ok;
    double t = now_seconds() - t0;
    if (t > worst_kernel) worst_kernel = t;
    total += t;
    t0 = now_seconds();
    ok = build_user_programs(&ARCHES[i], false) && ok;
    total += now_seconds() - t0;
  }
  bool in_budget = worst_kernel < 1.0 && total < 10.0;
  fprintf(stderr, "  TIME  kernel %.2f s (budget 1 s), all first-party %.2f s (budget 10 s) %s\n",
          worst_kernel, total, in_budget ? "ok" : "OVER BUDGET");
  return ok && in_budget;
}

// ---------------------------------------------------------------------------
// The manual's check (docs/12 §5, §7; M6 step 6a2): every page parses and
// keeps the house rules; the index, out/man/index/base, is written from the
// pages and every link resolves through it; and everything the inventory
// lists has a page, or a record in man/missing, the ledger that only
// shrinks, never both.

// What must have a page: kind and name, and the sections a page may be in.
typedef struct man_item {
  const char *kind, *name;
  uint16_t sects; // 1 << N for each section N allowed
  bool listed;    // in man/missing
} man_item;

typedef struct man_entry {        // the index: one per name a page documents, and per node
  const char *name, *page, *node; // node: the node's id, for a node's entry
  const char *about;              // the page's summary, or the node's title
  const char *keys;               // the page's or the node's keys=, for lookman
  int sect;
} man_entry;

static man_item man_items[2048];
static int man_nitems;
static man_entry man_index[4096];
static int man_nindex, man_errors;

// Sections as bits of man_item's mask.
static constexpr uint16_t MAN_SECT_1 = 1u << 1;
static constexpr uint16_t MAN_SECT_2 = 1u << 2;
static constexpr uint16_t MAN_SECT_3 = 1u << 3;
static constexpr uint16_t MAN_SECT_4 = 1u << 4;
static constexpr uint16_t MAN_SECT_5 = 1u << 5;
static constexpr uint16_t MAN_SECT_6 = 1u << 6;
static constexpr uint16_t MAN_SECT_8 = 1u << 8;

// The formats with a section 6 page, each named for its page, and the key
// table of each ndb format with keys of its own (12 §7): its page defines
// exactly those keys, each in the node the table gives.
typedef struct man_format {
  const char *name, *keys;
} man_format;
static const man_format MAN_FORMATS[] = {
    {"ndb", nullptr},
    {"guide", nullptr},
    {"namespace", nullptr},
    {"svc", "servers/svcd/svc.def"},
    {"driver", "servers/devmgr/driver.def"},
    {"users", nullptr},
    {"utf", nullptr},
    {"vxfs", nullptr},
    {"store", "lib/vx-store/store.def"},
    {"release", "lib/vx-store/release.def"},
    {"slots", "lib/vx-slots/slots.def"},
};
// Plan 9's headings, in Plan 9's order (12 §8).
static const char *const MAN_ORDER[] = {"SYNOPSIS", "DESCRIPTION", "EXAMPLES", "FILES",
                                        "SEE ALSO", "DIAGNOSTICS", "BUGS"};

static void man_error(const char *where, size_t line, const char *what) {
  if (line)
    fprintf(stderr, "  MAN   %s:%zu: %s\n", where, line, what);
  else
    fprintf(stderr, "  MAN   %s: %s\n", where, what);
  man_errors++;
}

static void man_need(const char *kind, const char *name, uint16_t sects) {
  for (int i = 0; i < man_nitems; i++) // a native program and sbase's of one name: one page covers both
    if (strcmp(man_items[i].kind, kind) == 0 && strcmp(man_items[i].name, name) == 0 &&
        (man_items[i].sects & sects)) {
      man_items[i].sects &= sects; // the sections both allow
      return;
    }
  if (man_nitems == (int)(sizeof man_items / sizeof man_items[0])) die("the manual's inventory is full");
  man_items[man_nitems++] = (man_item){.kind = kind, .name = name, .sects = sects};
}

// Every name in a .def file's NAME(... lines, the name being the first argument.
static void man_need_def(const char *path, const char *macro, const char *kind, uint16_t sects) {
  vx_str text = read_file(path);
  size_t m = strlen(macro);
  for (size_t i = 0; i + m < text.len; i++) {
    if ((i && text.ptr[i - 1] != '\n') || memcmp(text.ptr + i, macro, m) != 0 || text.ptr[i + m] != '(')
      continue;
    size_t a = i + m + 1, b = a;
    while (b < text.len && text.ptr[b] != ',' && text.ptr[b] != ')') b++;
    man_need(kind, str_dup((vx_str){text.ptr + a, b - a}), sects);
  }
}

static void man_inventory(void) {
  for (int i = 0; i < USER_PROGRAM_COUNT; i++) {
    const program *p = &USER_PROGRAMS[i];
    if (strncmp(p->source, "tests/", 6) == 0) continue; // a test is not a program anyone runs
    if (strncmp(p->source, "servers/", 8) == 0)
      man_need("server", p->name, MAN_SECT_4 | MAN_SECT_8);
    else if (strncmp(p->source, "drivers/", 8) == 0)
      man_need("driver", p->name, MAN_SECT_3);
    else if (p->link == LINK_SHARED) // a library: its interface's page names it (libvxui.so in vxui(2))
      man_need("library", p->name, MAN_SECT_2);
    else
      man_need("program", p->name, MAN_SECT_1 | MAN_SECT_8);
  }
  for (int k = 0; k < POSIX_PORT_COUNT; k++)
    for (int i = 0; i < POSIX_PORTS[k]->program_count; i++)
      man_need("program", str_dup(vx_ndb_get(&POSIX_PORTS[k]->programs[i], "program")), MAN_SECT_1);
  DIR *d = opendir("host");
  for (struct dirent *e; d && (e = readdir(d));)
    if (e->d_name[0] != '.')
      man_need("program", str_dup((vx_str){e->d_name, strlen(e->d_name)}), MAN_SECT_1 | MAN_SECT_8);
  if (d) closedir(d);
  man_need("program", "build", MAN_SECT_1 | MAN_SECT_8);
  man_need_def("abi/vx/syscalls.def", "VX_SYSCALL", "syscall", MAN_SECT_2);
  man_need_def("lib/vx-9p/messages.def", "P9_MSG", "message", MAN_SECT_5);
  for (size_t i = 0; i < sizeof MAN_FORMATS / sizeof MAN_FORMATS[0]; i++)
    man_need("format", MAN_FORMATS[i].name, MAN_SECT_6);
  for (int n = 1; n <= 8; n++) man_need("intro", "intro", (uint16_t)(1u << n));
}

static bool man_str_eq(vx_str a, const char *b) { return a.len == strlen(b) && memcmp(a.ptr, b, a.len) == 0; }
static bool man_vstr_eq(vx_str a, vx_str b) {
  return a.len == b.len && (!a.len || memcmp(a.ptr, b.ptr, a.len) == 0);
}

// A name's entry in section sect: a page's (page nullptr), or a node of that page.
static const man_entry *man_find(vx_str name, int sect, const char *page) {
  for (int i = 0; i < man_nindex; i++) {
    const man_entry *e = &man_index[i];
    bool kind = page ? e->node && strcmp(e->page, page) == 0 : !e->node;
    if (e->sect == sect && kind && man_str_eq(name, e->name)) return e;
  }
  return nullptr;
}

static void man_index_add(const char *name, const char *page, bool node, const char *about, const char *keys,
                          int sect, const char *where) {
  if (man_find((vx_str){name, strlen(name)}, sect, node ? page : nullptr))
    man_error(where, 0, fmt(node ? "node %s twice" : "%s(%d) is named by two pages", name, sect));
  if (man_nindex == (int)(sizeof man_index / sizeof man_index[0])) die("the manual's index is full");
  man_index[man_nindex++] = (man_entry){
      .name = name, .page = page, .node = node ? name : nullptr, .about = about, .keys = keys, .sect = sect};
}

// 12 §8's house rules, on a page's raw lines.
static void man_house(const char *where, vx_str text) {
  bool fence = false;
  size_t line = 1;
  for (size_t i = 0; i < text.len; line++) {
    size_t j = i;
    while (j < text.len && text.ptr[j] != '\n') j++;
    vx_str l = {text.ptr + i, j - i};
    bool ticks = l.len >= 3 && memcmp(l.ptr, "```", 3) == 0, edge = ticks && (!fence || l.len == 3);
    if (l.len && (l.ptr[l.len - 1] == ' ' || l.ptr[l.len - 1] == '\t'))
      man_error(where, line, "a trailing space");
    if (!fence && memchr(l.ptr, '\t', l.len)) man_error(where, line, "a tab outside a fence");
    if (fence && !edge && vx_utflen(l.ptr, l.len) > 80)
      man_error(where, line, "a fence line wider than 80 columns");
    if (edge) fence = !fence; // opened by ```kind, closed by ``` alone
    i = j + 1;
  }
}

typedef struct man_page {
  const char *path;
  vx_str text;
  int sect;
  const char *page;
} man_page;

// A span's link resolves: name(N), name(N)#node, #node or a URL.
static void man_link(const man_page *p, vx_str target, size_t line) {
  if (!target.len) return;
  if (target.ptr[0] == '#') {
    if (!man_find((vx_str){target.ptr + 1, target.len - 1}, p->sect, p->page))
      man_error(p->path, line, fmt("a link to no node of this page: %.*s", (int)target.len, target.ptr));
    return;
  }
  if (target.ptr[target.len - 1] != ')' && !memchr(target.ptr, '#', target.len)) return; // a URL
  vx_guide_inline it = {.s = target};
  vx_guide_span sp;
  if (vx_guide_span_next(&it, &sp) != VX_SPAN_REF) return; // a URL with a ( in it
  const man_entry *e = man_find(sp.name, sp.sect, nullptr);
  for (int i = 0; !e && i < man_nitems; i++) // a page the ledger promises: linked before it is written
    if (man_items[i].listed && (man_items[i].sects & (1u << sp.sect)) &&
        man_str_eq(sp.name, man_items[i].name)) {
      if (it.pos < target.len) man_error(p->path, line, "a link to a node of a page not yet written");
      return;
    }
  if (!e) {
    man_error(p->path, line, fmt("a link to nothing: %.*s", (int)sp.text.len, sp.text.ptr));
    return;
  }
  if (it.pos < target.len &&
      !man_find((vx_str){target.ptr + it.pos + 1, target.len - it.pos - 1}, e->sect, e->page))
    man_error(p->path, line, fmt("a link to no such node: %.*s", (int)target.len, target.ptr));
}

static void man_spans(const man_page *p, vx_str text, size_t line) {
  vx_guide_inline it = {.s = text};
  vx_guide_span sp;
  for (vx_guide_span_kind k; (k = vx_guide_span_next(&it, &sp)) > VX_SPAN_END;) {
    if (k == VX_SPAN_REF) man_link(p, sp.text, line);
    if (k == VX_SPAN_LINK) man_link(p, sp.target, line);
  }
}

// The second pass: headings in order and capitals, every link resolved.
static void man_body(const man_page *p) {
  static vx_guide g;
  if (!vx_guide_open(&g, p->text)) return;
  vx_guide_block b;
  int last = -1;
  while (vx_guide_next(&g, &b) > VX_GUIDE_END) {
    if (b.kind == VX_GUIDE_HEADING) {
      for (size_t i = 0; i < b.text.len; i++)
        if (b.text.ptr[i] >= 'a' && b.text.ptr[i] <= 'z') {
          man_error(p->path, b.line, "a heading not in capitals");
          break;
        }
      for (int k = 0; k < (int)(sizeof MAN_ORDER / sizeof MAN_ORDER[0]); k++)
        if (man_str_eq(b.text, MAN_ORDER[k])) {
          if (k <= last) man_error(p->path, b.line, "a heading out of Plan 9's order (12 §8)");
          last = k;
        }
    }
    if (b.kind == VX_GUIDE_FENCE || b.kind == VX_GUIDE_NODE) continue;
    man_spans(p, b.text, b.line);
    if (b.body.len) man_spans(p, b.body, b.line);
  }
}

static void man_discard(void *ctx, const char *s, size_t n) { (void)ctx, (void)s, (void)n; }

typedef struct man_key {
  vx_str scope, key;
  bool seen;
} man_key;

// The next "..." in s from *at, or false.
static bool man_quoted(vx_str s, size_t *at, vx_str *out) {
  const char *q = memchr(s.ptr + *at, '"', s.len - *at);
  if (!q) return false;
  const char *e = memchr(q + 1, '"', (size_t)(s.ptr + s.len - q - 1));
  if (!e) return false;
  *out = (vx_str){q + 1, (size_t)(e - q - 1)};
  *at = (size_t)(e + 1 - s.ptr);
  return true;
}

// A format's page against its key table: each key defined in DESCRIPTION, in
// the table's node for it, and nothing defined there that the table lacks.
static void man_check_keys(const char *page, const char *table) {
  static man_key keys[256];
  int n = 0;
  vx_str def = read_file(table);
  for (size_t i = 0; i + 4 < def.len; i++) {
    if ((i && def.ptr[i - 1] != '\n') || memcmp(def.ptr + i, "KEY(", 4) != 0) continue;
    size_t at = i;
    man_key k = {};
    if (n == (int)(sizeof keys / sizeof keys[0]) || !man_quoted(def, &at, &k.scope) ||
        !man_quoted(def, &at, &k.key))
      die("%s: a KEY line the check cannot read, or too many", table);
    keys[n++] = k;
  }
  vx_str text = read_file(page);
  static vx_guide g;
  if (!vx_guide_open(&g, text)) return; // the first pass reported it
  vx_guide_block b;
  vx_str scope = {}, heading = {};
  while (vx_guide_next(&g, &b) > VX_GUIDE_END) {
    if (b.kind == VX_GUIDE_NODE) scope = b.node;
    if (b.kind == VX_GUIDE_HEADING) heading = b.text;
    if (b.kind != VX_GUIDE_DEF || !man_str_eq(heading, "DESCRIPTION")) continue;
    bool checked = false; // a node the table names
    for (int k = 0; k < n; k++) checked = checked || man_vstr_eq(keys[k].scope, scope);
    for (size_t at = 0; checked;) {
      const char *q = memchr(b.text.ptr + at, '`', b.text.len - at);
      const char *e = q ? memchr(q + 1, '`', (size_t)(b.text.ptr + b.text.len - q - 1)) : nullptr;
      if (!e) break;
      vx_str term = {q + 1, (size_t)(e - q - 1)};
      at = (size_t)(e + 1 - b.text.ptr);
      int found = -1;
      for (int k = 0; k < n && found < 0; k++)
        if (man_vstr_eq(keys[k].scope, scope) && man_vstr_eq(keys[k].key, term)) found = k;
      if (found < 0)
        man_error(page, b.line,
                  fmt("defines `%.*s`, which %s does not list", (int)term.len, term.ptr, table));
      else
        keys[found].seen = true;
    }
  }
  for (int k = 0; k < n; k++)
    if (!keys[k].seen)
      man_error(page, 0,
                fmt("%s lists `%.*s`, which the page does not define%s%.*s", table, (int)keys[k].key.len,
                    keys[k].key.ptr, keys[k].scope.len ? " in node " : "", (int)keys[k].scope.len,
                    keys[k].scope.ptr));
}

static bool check_man(void) {
  double start = now_seconds();
  man_nitems = man_nindex = man_errors = 0;
  man_inventory();
  static man_page pages[1024];
  int npages = 0;
  for (int sect = 1; sect <= 8; sect++) { // the first pass: parse, and index
    DIR *d = opendir(fmt("man/%d", sect));
    for (struct dirent *e; d && (e = readdir(d));) {
      if (e->d_name[0] == '.') continue;
      if (npages == (int)(sizeof pages / sizeof pages[0])) die("more pages than the check holds");
      man_page *p = &pages[npages];
      p->path = fmt("man/%d/%s", sect, e->d_name), p->sect = sect;
      p->text = read_file(p->path);
      p->page = str_dup((vx_str){e->d_name, strlen(e->d_name)});
      man_house(p->path, p->text);
      static vx_guide g;
      const char *error = "";
      size_t line = 0;
      vx_guide_out null_out = {.write = man_discard};
      if (!vx_guide_open(&g, p->text) || !vx_guide_render(p->text, nullptr, &null_out, &error, &line)) {
        man_error(p->path, g.error ? g.error_line : line, g.error ? g.error : error);
        continue;
      }
      if (!man_str_eq(g.h.page, p->page) || g.h.sect != sect)
        man_error(p->path, 1, "page= and sect= are its file's name and directory");
      vx_str names = g.h.names, name;
      const char *summary = str_dup(g.h.summary);
      const char *keys = str_dup(g.h.keys);
      bool self =
          false; // the page's own name is a link to it too, named or not (12 §3: open(2) and vx_create(2))
      while (vx_guide_item_next(&names, &name)) {
        man_index_add(str_dup(name), p->page, false, summary, keys, sect, p->path);
        self = self || man_str_eq(name, p->page);
      }
      if (!self) man_index_add(p->page, p->page, false, summary, keys, sect, p->path);
      vx_guide_block b;
      while (vx_guide_next(&g, &b) > VX_GUIDE_END)
        if (b.kind == VX_GUIDE_NODE)
          man_index_add(str_dup(b.node), p->page, true, str_dup(b.title), str_dup(b.keys), sect, p->path);
      npages++;
    }
    if (d) closedir(d);
  }

  for (size_t i = 0; i < sizeof MAN_FORMATS / sizeof MAN_FORMATS[0]; i++)
    if (MAN_FORMATS[i].keys && exists(fmt("man/6/%s", MAN_FORMATS[i].name)))
      man_check_keys(fmt("man/6/%s", MAN_FORMATS[i].name), MAN_FORMATS[i].keys);

  // The ledger: each record names something the inventory has, once.
  int missing = 0;
  if (exists("man/missing")) {
    vx_ndb_reader r = {.src = read_file("man/missing"), .scratch = alloc(4096), .scratch_cap = 4096};
    vx_ndb_record rec;
    for (vx_ndb_result res; (res = vx_ndb_next(&r, &rec)) != VX_NDB_END;) {
      if (res == VX_NDB_ERROR) die("man/missing:%zu: %s", r.error_line, r.error);
      vx_str kind = vx_ndb_get(&rec, "kind"), name = vx_ndb_get(&rec, "name");
      uint64_t sect = 0;
      vx_ndb_get_u64(&rec, "sect", &sect);
      man_item *it = nullptr;
      for (int i = 0; i < man_nitems && !it; i++)
        if (man_str_eq(kind, man_items[i].kind) && man_str_eq(name, man_items[i].name) &&
            (!sect || (sect <= 8 && man_items[i].sects == (uint16_t)(1u << sect))))
          it = &man_items[i];
      if (!it || it->listed)
        man_error("man/missing", rec.line, it ? "listed twice" : "names nothing the system has: remove it");
      if (it) it->listed = true;
      missing++;
    }
  }
  for (int i = 0; i < npages; i++) man_body(&pages[i]); // links resolve to pages, or to the ledger
  for (int i = 0; i < man_nitems; i++) {
    man_item *it = &man_items[i];
    bool has = false;
    for (int s = 1; s <= 8 && !has; s++)
      has = (it->sects & (1u << s)) && man_find((vx_str){it->name, strlen(it->name)}, s, nullptr);
    const char *sect = strcmp(it->kind, "intro") == 0 ? fmt(" sect=%d", __builtin_ctz(it->sects)) : "";
    if (has && it->listed)
      man_error("man/missing", 0,
                fmt("documented now, so remove: kind=%s name=%s%s", it->kind, it->name, sect));
    if (!has && !it->listed)
      man_error("man", 0,
                fmt("no page, and not in man/missing: kind=%s name=%s%s", it->kind, it->name, sect));
  }

  // A program with a page takes its usage message from it (6a3): VX_USAGE, never its own.
  for (int i = 0; i < USER_PROGRAM_COUNT; i++) {
    const program *p = &USER_PROGRAMS[i];
    if (!usage_page(p) || strncmp(p->source, "tests/", 6) == 0) continue;
    vx_str src = read_file(p->source);
    bool own = memmem(src.ptr, src.len, "\"usage:", 7);
    // A program that prints no usage message needs none; one that does takes it from its page.
    if (usage_flags(p) && own)
      man_error(p->source, 0, "a program with a page takes its usage message from it: VX_USAGE, not its own");
    if (!usage_flags(p) && own)
      man_error(usage_page(p), 0, fmt("%s has a usage message, and its page no usage line for it", p->name));
  }

  // The index, as 12 §5 has it: one record per name and node.
  mkdirs("out/man/index");
  size_t cap = (size_t)man_nindex * 512 + 64;
  vx_ndb_writer w = {.buf = alloc(cap), .cap = cap};
  for (int i = 0; i < man_nindex; i++) {
    const man_entry *e = &man_index[i];
    vx_ndb_put(&w, "name", (vx_str){e->name, strlen(e->name)});
    vx_ndb_put(&w, "page", (vx_str){e->page, strlen(e->page)});
    vx_ndb_put_u64(&w, "sect", (uint64_t)e->sect);
    if (e->node) vx_ndb_put(&w, "node", (vx_str){e->node, strlen(e->node)});
    if (e->about[0]) vx_ndb_put(&w, e->node ? "title" : "summary", (vx_str){e->about, strlen(e->about)});
    if (e->keys[0]) vx_ndb_put(&w, "keys", (vx_str){e->keys, strlen(e->keys)});
    vx_ndb_end(&w);
  }
  if (w.failed) die("the manual's index does not fit");
  write_file("out/man/index/base", (vx_str){w.buf, w.len});
  double ms = (now_seconds() - start) * 1000;
  bool ok = man_errors == 0;
  fprintf(stderr, "  MAN   %d pages, %d names, %d missing, %.0f ms (budget 200 ms) %s\n", npages, man_nindex,
          missing, ms, ok ? "ok" : fmt("FAIL: %d errors", man_errors));
  return ok && ms < 200;
}

static int cmd_check(void) {
  bool ok = !check_wants("man") || check_man();
  ok = (!check_wants("host") || check_host_tests()) && ok;
  ok = (!check_wants("fuzz") || check_fuzz()) && ok;
  ok = (!check_wants("vxfs") || check_vxfs_image()) && ok;
  ok = (!check_wants("vendor") || cmd_vendor_check() == 0) && ok;
  ok = (!check_wants("format") || check_format()) && ok;
  ok = (!check_wants("sa") || check_analyzer()) && ok;
  ok = (!check_wants("tidy") || check_tidy()) && ok;
  ok = (!check_wants("time") || check_build_time()) && ok;
  if ((check_wants("sa") || check_wants("tidy")) && !check_units_run) {
    fprintf(stderr, "build: check: no unit is named so: nothing was analysed\n"); // never a silent pass
    ok = false;
  }
  fprintf(stderr, "build: check %s\n", ok ? "passed" : "FAILED");
  return ok ? 0 : 1;
}

// ./build man [section ...] title [node]: a page of man/, rendered as man(1)
// renders it (12 §6.1), so the manual can be read before an image boots.
static void man_write(void *ctx, const char *s, size_t n) { fwrite(s, 1, n, ctx); }

static int cmd_man(const char *const *args, int n) {
  if (n == 1 &&
      strcmp(args[0], "--check") == 0) { // the manual's pass of check alone (12 §7), in milliseconds
    check_toolchain();
    return check_man() ? 0 : 1;
  }
  int sects[8], nsect = 0;
  while (n && args[0][0] >= '1' && args[0][0] <= '8' && !args[0][1] && nsect < 8)
    sects[nsect++] = args[0][0] - '0', args++, n--;
  if (n < 1 || n > 2) die("usage: ./build man [section ...] title [node]");
  if (!nsect)
    for (int k = 1; k <= 8; k++) sects[nsect++] = k;
  struct winsize ws = {};
  uint32_t width = isatty(1) && ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col ? ws.ws_col : 80;
  for (int k = 0; k < nsect; k++) {
    const char *path = fmt("man/%d/%s", sects[k], args[0]);
    if (!exists(path)) continue;
    vx_str page = read_file(path);
    vx_guide_out o = {.write = man_write, .ctx = stdout, .width = width};
    const char *error;
    size_t line;
    if (!vx_guide_render(page, n == 2 ? args[1] : nullptr, &o, &error, &line))
      die("%s:%zu: %s", path, line, error);
    return 0;
  }
  die("no page %s in man/", args[0]);
}

static void usage(void) {
  fprintf(
      stderr,
      "usage: ./build [-v] <command> [options]\n"
      "\n"
      "  all           [--arch A] [--release]          the kernel and Limine (both architectures by "
      "default)\n"
      "  image         [--arch A] [--release] [--iso]  a GPT disk image: out/A/MODE/vectra-A.img;\n"
      "                                                 with --iso, a UEFI CD image too: vectra-A.iso\n"
      "  qemu          [--arch A] [--release] [--kvm] [--gdb]   boot the image; Ctrl-A X quits\n"
      "  test          [--arch A] [--release] [--tcg] [scenario...]   boot headless and check "
      "tests/qemu/*.ndb;\n"
      "                                                 x86_64 uses KVM when it can, unless --tcg\n"
      "  bench                                          00 §8's budgets under KVM in a release build, each\n"
      "                                                 between two trace marks (bench), and its own test "
      "(benchslow)\n"
      "  release       [--verify RECORD]               both base trees in out/release/store, store-A.tar, "
      "and\n"
      "                                                 release.ndb (unsigned); --verify rebuilds and "
      "compares\n"
      "  loc                                            the line-count ledger\n"
      "  man           [section ...] title [node]     a page of man/, as man(1) shows it;\n"
      "                --check                         or check's manual pass alone (12 §7)\n"
      "  vendor-check                                   check third_party/ against VENDOR.ndb\n"
      "  check                                          host tests (ASan, UBSan), the fuzzers, a volume "
      "image, "
      "vendor-check, the format,\n"
      "                                                 the static analyzer and the build-time budget: CI's "
      "first job\n"
      "  check [STAGE ...] [UNIT ...]                   only those stages (man host fuzz vxfs vendor format "
      "sa tidy\n"
      "                                                 time), the analyzer and tidy only on those units: "
      "rc, ktest, ...\n"
      "\n"
      "A is x86_64 or aarch64. qemu defaults to x86_64.\n"
      "Still to come: in check, the vx-check models (M2).\n");
  exit(2);
}

int main(int argc, char **argv) {
  rebuild_self(argv);
  if (!getcwd(root, sizeof root)) die("cannot read the current directory");
  setenv("MTOOLS_SKIP_CHECK", "1", 1);
  set_source_date_epoch();

  int i = 1;
  if (i < argc && strcmp(argv[i], "-v") == 0) {
    verbose = true;
    i++;
  }
  if (i >= argc) usage();
  const char *command = argv[i++];

  const arch *only = nullptr;
  bool release = false;
  const char *verify = nullptr; // release --verify RECORD
  qemu_opts qo = {};
  for (; i < argc; i++) {
    if (strcmp(argv[i], "--release") == 0) {
      release = true;
    } else if (strcmp(argv[i], "--kvm") == 0) {
      qo.kvm = true;
    } else if (strcmp(argv[i], "--gdb") == 0) {
      qo.gdb = true;
    } else if (strcmp(argv[i], "--tcg") == 0) {
      force_tcg = true;
    } else if (strcmp(argv[i], "--iso") == 0 && strcmp(command, "image") == 0) {
      want_iso = true;
    } else if (strcmp(argv[i], "--verify") == 0 && strcmp(command, "release") == 0 && i + 1 < argc) {
      verify = argv[++i];
    } else if (strcmp(argv[i], "--arch") == 0 && i + 1 < argc) {
      i++;
      for (int a = 0; a < ARCH_COUNT; a++)
        if (strcmp(argv[i], ARCHES[a].name) == 0) only = &ARCHES[a];
      if (!only) die("unknown architecture %s", argv[i]);
    } else if (argv[i][0] != '-' && strcmp(command, "check") == 0 && check_arg_count < 64) {
      check_args[check_arg_count++] = argv[i];
    } else if (argv[i][0] != '-' && strcmp(command, "test") == 0 && scenario_count < SCENARIO_MAX) {
      scenarios[scenario_count++] = argv[i];
    } else if (strcmp(command, "man") == 0) {
      return cmd_man((const char *const *)argv + i, argc - i);
    } else {
      usage();
    }
  }

  if (strcmp(command, "release") == 0) return cmd_release(verify);
  if (strcmp(command, "bench") == 0) { // 00 §8's budgets, under KVM, in a release build (7a5)
    check_toolchain();
    const arch *x86 = &ARCHES[0];
    if (!kvm_usable(x86)) die("bench needs KVM: x86_64 and access to /dev/kvm");
    scenarios[0] = "bench", scenarios[1] = "benchslow", scenarios[2] = "termrate", scenario_count = 3;
    return cmd_test(x86, true);
  }
  if (strcmp(command, "loc") == 0) return cmd_loc();
  if (strcmp(command, "vendor-check") == 0) return cmd_vendor_check();
  if (strcmp(command, "check") == 0) {
    check_toolchain();
    return cmd_check();
  }
  if (strcmp(command, "all") == 0 || strcmp(command, "image") == 0 || strcmp(command, "qemu") == 0 ||
      strcmp(command, "test") == 0) {
    check_toolchain();
    if (strcmp(command, "all") == 0) return cmd_all(only, release);
    if (strcmp(command, "image") == 0) return per_arch(only, release, build_image);
    if (strcmp(command, "test") == 0) return cmd_test(only, release);
    if (qo.kvm && !kvm_usable(only ? only : &ARCHES[0])) die("--kvm needs x86_64 and access to /dev/kvm");
    return cmd_qemu(only ? only : &ARCHES[0], release, qo);
  }
  usage();
}
