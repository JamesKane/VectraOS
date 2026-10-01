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
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "lib/vx-ndb/ndb.c"
#include "lib/vx-sha256/sha256.c"
#include "lib/vx-tar/tar.c"

// ADR-0001: the toolchain is pinned to these exact binaries and versions.
// Each pin is one line of the tool's --version output, compared exactly.
static const char CLANG[] = "/usr/bin/clang";
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
    "build.c",           "lib/vx-ndb/ndb.h",
    "lib/vx-ndb/ndb.c",  "lib/vx-sha256/sha256.c",
    "abi/vx/abi.h",      "abi/vx/syscalls.def",
    "abi/vx/rights.def", "abi/vx/status.def",
    "lib/vx-tar/tar.c",  nullptr,
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
// lib/vx-rt. No FP/SIMD until the kernel saves that state (M2).
static const char *const USER_FLAGS[] = {
    "-ffreestanding", "-fno-pic", "-fstack-protector-strong", "-mstack-protector-guard=global", nullptr,
};

static const char *const X86_64_FLAGS[] = {
    "--target=x86_64-unknown-none-elf", "-mno-red-zone", "-mcmodel=kernel", "-fcf-protection=full", nullptr,
};

static const char *const AARCH64_FLAGS[] = {
    "--target=aarch64-unknown-none-elf",
    "-mbranch-protection=standard",
    nullptr,
};

static const char *const X86_64_USER_FLAGS[] = {
    "--target=x86_64-unknown-none-elf",
    "-fcf-protection=full",
    nullptr,
};

static const char *const AARCH64_USER_FLAGS[] = {
    "--target=aarch64-unknown-none-elf",
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
static char arena[128 << 20];
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
  memcpy(p, s.ptr, s.len);
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
// output, NUL-terminated (at most 64 KiB). Its standard error is discarded.
// Returns nullptr if it could not run or did not exit with status 0.
static char *run_capture(const char *const *argv) {
  int fds[2];
  if (pipe(fds) != 0) die("pipe failed");
  pid_t pid = fork();
  if (pid < 0) die("fork failed");
  if (pid == 0) {
    int null = open("/dev/null", O_WRONLY);
    if (null < 0 || dup2(fds[1], 1) < 0 || dup2(null, 2) < 0) _exit(127);
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
  struct stat bin;
  bool stale = stat("build", &bin) != 0;
  for (const char *const *src = BUILD_SOURCES; *src; src++) {
    struct stat st;
    if (stat(*src, &st) != 0) die("run ./build from the repository root (missing %s)", *src);
    if (!stale && newer(&st, &bin)) stale = true;
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

typedef struct port {
  const char *name;
  const char *dir;    // ports/<name>, which also holds the captured config.h
  const char *src;    // third_party/<name>, absolute
  vx_ndb_record head; // the port= record
  vx_ndb_record targets[PORT_MAX_TARGETS];
  int target_count;
  vx_ndb_record files[PORT_MAX_FILES];
  int file_count;
  uint64_t input_hash;
} port;

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
    } else {
      die("%s:%zu: a record must start with port=, target= or file=", path, rec.line);
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
        cmd_add_words(c, vx_ndb_get(&p->head, "cflags"));
        cmd_add(c, "-Iports/musl/vx/arch/generic");
        cmd_add(c, fmt("-I%s/arch/%s", musl.src, a->name));
        cmd_add(c, fmt("-I%s/arch/generic", musl.src));
        cmd_add(c, "-Iports/musl/generated/internal");
        cmd_add(c, fmt("-I%s/src/include", musl.src));
        cmd_add(c, fmt("-I%s/src/internal", musl.src));
        cmd_add(c, fmt("-Iports/musl/generated/%s/include", a->name));
        cmd_add(c, fmt("-I%s/include", musl.src));
      } else {
        cmd_addv(c, posix_flags(a));
        cmd_add_words(c, vx_ndb_get(&p->head, "cflags"));
      }
      if (extra) cmd_add_words(c, extra(rel));
      cmd_add(c, prefix_map);
      cmd_add(c, "-c");
      cmd_add(c, fmt("%s/%s", p->src, rel));
      cmd_add(c, "-o");
      cmd_add(c, objs[i] = object_for(objdir, rel));
      mkdirs_for(objs[i]);
      ptrs[n] = c;
    }
    if (!run_parallel(ptrs, n)) return false;
  }
  return true;
}

static vx_str musl_file_flags(const char *rel) {
  const char *base = strrchr(rel, '/') + 1;
  size_t n = strcspn(base, ".");
  vx_str nossp = vx_ndb_get(&musl.head, "nossp");
  if (words_has(nossp, str_dup((vx_str){base, n}))) return (vx_str){"-fno-stack-protector", 20};
  return (vx_str){};
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
static bool build_cached(const port *p, const arch *a, file_list *files, const char **objs,
                         vx_str (*extra)(const char *rel)) {
  const char *outdir = fmt("%s/out/%s/%s", root, p->name, a->name);
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
  return true;
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
// images whose scenario names it with `with=`, together with its manifest.
typedef enum placement : uint8_t { IN_MODULE, IN_BOOTFS, IN_TESTS } placement;

typedef struct program {
  const char *name, *source;
  placement where;
  const char *arch; // the only architecture it is built for, or nullptr for every one
  bool posix;       // against vectra-musl, rather than freestanding against vx-rt
} program;

static const program USER_PROGRAMS[] = {
    {"svcd", "servers/svcd/svcd.c", IN_MODULE, nullptr, false},
    {"ktest", "tests/kernel/ktest.c", IN_MODULE, nullptr,
     false}, // the root task instead of svcd with vx.root=ktest
    {"bootfs", "servers/bootfs/bootfs.c", IN_BOOTFS, nullptr, false},
    {"nstest", "tests/user/nstest.c", IN_TESTS, nullptr, false},
    {"constest", "tests/user/constest.c", IN_TESTS, nullptr, false},
    {"nettest", "tests/user/nettest.c", IN_TESTS, nullptr, false},
    {"tcptest", "tests/user/tcptest.c", IN_TESTS, nullptr, false},
    {"procfs", "servers/procfs/procfs.c", IN_BOOTFS, nullptr, false},
    {"posixd", "servers/posixd/posixd.c", IN_BOOTFS, nullptr, false},
    {"tmpfs", "servers/tmpfs/tmpfs.c", IN_BOOTFS, nullptr, false},
    {"nullfs", "servers/nullfs/nullfs.c", IN_BOOTFS, nullptr, false},
    {"devmgr", "servers/devmgr/devmgr.c", IN_BOOTFS, nullptr, false},
    {"netd", "servers/netd/netd.c", IN_BOOTFS, nullptr, false},
    {"gsh", "cmd/gsh.c", IN_BOOTFS, nullptr, false},
    {"ls", "cmd/ls.c", IN_BOOTFS, nullptr, false},
    {"cat", "cmd/cat.c", IN_BOOTFS, nullptr, false},
    {"echo", "cmd/echo.c", IN_BOOTFS, nullptr, false},
    {"ps", "cmd/ps.c", IN_BOOTFS, nullptr, false},
    {"ns", "cmd/ns.c", IN_BOOTFS, nullptr, false},
    {"tail", "cmd/tail.c", IN_BOOTFS, nullptr, false},
    {"ping", "cmd/ping.c", IN_BOOTFS, nullptr, false},
    {"cs", "cmd/cs.c", IN_BOOTFS, nullptr, false},
    {"drv-uart-16550", "drivers/drv-uart-16550/uart.c", IN_BOOTFS, "x86_64", false},
    {"drv-uart-pl011", "drivers/drv-uart-pl011/uart.c", IN_BOOTFS, "aarch64", false},
    {"drv-virtio-net", "drivers/drv-virtio-net/net.c", IN_BOOTFS, nullptr, false},
    {"ctest", "tests/posix/ctest.c", IN_TESTS, nullptr, true},
};

static bool program_for(const program *p, const arch *a) { return !p->arch || strcmp(p->arch, a->name) == 0; }
static constexpr int USER_PROGRAM_COUNT = sizeof USER_PROGRAMS / sizeof USER_PROGRAMS[0];

// Every user program for an architecture: compiled in parallel, then linked
// in parallel. Each is its own unity build, so nothing is shared between them.
static bool build_user_programs(const arch *a, bool release) {
  const char *dir = fmt("out/%s/%s", a->name, release ? "release" : "debug");
  static cmd cc[USER_PROGRAM_COUNT], ld[USER_PROGRAM_COUNT];
  cmd *ccs[USER_PROGRAM_COUNT], *lds[USER_PROGRAM_COUNT];
  int n = 0;
  for (int i = 0; i < USER_PROGRAM_COUNT; i++) {
    const program *p = &USER_PROGRAMS[i];
    if (!program_for(p, a)) continue;
    const char *obj = fmt("%s/%s.o", dir, p->name);
    fprintf(stderr, "  CC    %-7s %s\n", p->name, a->name);
    cc[n] = (cmd){};
    cmd_add(&cc[n], CLANG);
    cmd_addv(&cc[n], p->posix ? posix_flags(a) : a->user_flags);
    cmd_addv(&cc[n], HOUSE_FLAGS);
    cmd_addv(&cc[n], p->posix ? POSIX_PROGRAM_FLAGS : USER_FLAGS);
    cmd_addv(&cc[n], release ? RELEASE_FLAGS : DEBUG_FLAGS);
    cmd_add(&cc[n], fmt("-ffile-prefix-map=%s=/src", root));
    cmd_addv(&cc[n], (const char *const[]){"-c", p->source, "-o", obj, nullptr});
    ld[n] = (cmd){};
    cmd_add(&ld[n], LLD);
    cmd_addv(&ld[n],
             (const char *const[]){"-static", "-nostdlib", "--build-id=sha1", "-z", "max-page-size=0x1000",
                                   "-z", "noexecstack", "-e", "_start", "-o", nullptr});
    cmd_add(&ld[n], fmt("%s/%s", dir, p->name));
    const char *lib = vectra_musl_lib(a, release);
    if (p->posix) {
      cmd_add(&ld[n], fmt("%s/crt1.o", lib));
      cmd_add(&ld[n], fmt("%s/crti.o", lib));
    }
    cmd_add(&ld[n], obj);
    if (p->posix) {
      cmd_add(&ld[n], fmt("%s/libc.a", lib));
      cmd_add(&ld[n], fmt("%s/libclang_rt.builtins.a", lib));
      cmd_add(&ld[n], fmt("%s/crtn.o", lib));
    }
    ccs[n] = &cc[n];
    lds[n] = &ld[n];
    n++;
  }
  return run_parallel(ccs, n) && run_parallel(lds, n);
}

static bool build_arch(const arch *a, bool release) {
  if (!build_kernel(a, release) || !build_vectra_musl(a, release) || !build_user_programs(a, release))
    return false;
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
  // musl's build also reads the back end's syscall_arch.h and the generated headers.
  musl.input_hash = hash_tree(musl.input_hash, fmt("%s/ports/musl/vx/arch", root));
  musl.input_hash = hash_tree(musl.input_hash, fmt("%s/ports/musl/generated", root));
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

static constexpr uint64_t SECTOR = 512;
static constexpr uint64_t ESP_BYTES = 64ull << 20;
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

static void pwrite_all(int fd, const void *p, size_t n, uint64_t off, const char *path) {
  if (pwrite(fd, p, n, (off_t)off) != (ssize_t)n) die("cannot write %s", path);
}

static void write_gpt_disk(const char *path, const char *esp_path, uint64_t seed) {
  uint64_t esp_sectors = ESP_BYTES / SECTOR;
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
  for (uint64_t off = 0; off < ESP_BYTES;) {
    ssize_t n = pread(in, chunk, sizeof chunk, (off_t)off);
    if (n <= 0) die("short read from %s", esp_path);
    pwrite_all(fd, chunk, (size_t)n, ESP_LBA * SECTOR + off, path);
    off += (uint64_t)n;
  }
  close(in);
  if (close(fd) != 0) die("cannot write %s", path);
}

// --- ISO 9660 with El Torito (image --iso, M3's deliverables) ---
//
// A CD image for UEFI. Its El Torito boot entry ("no emulation", platform
// EFI) is a small FAT image holding only the loader; the loader then reads
// its configuration, the kernel and the modules from the ISO 9660 tree, as
// Limine does on a CD. An MBR in the system area also names the boot image
// as a partition (type EFI), as xorriso's --efi-boot-part does: that is how
// Limine finds which volume it was booted from. Names are plain ISO 9660
// (upper case, "NAME.EXT;1"),
// which Limine matches case-insensitively. Every date is zero, so the image
// is reproducible.

static constexpr uint32_t ISO_SECTOR = 2048;
static constexpr int ISO_MAX_DIRS = 16;

typedef struct iso_file {
  const char *path; // in the ISO: "boot/vx/kernel.elf"
  const char *from; // where it is on this machine
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

// A directory record at p; its length.
static size_t iso_record(uint8_t *p, uint32_t lba, uint32_t size, bool dir, const char *name,
                         size_t name_len) {
  size_t len = 33 + name_len + !(name_len & 1); // padded to an even length
  memset(p, 0, len);
  p[0] = (uint8_t)len;
  iso_both32(p + 2, lba);
  iso_both32(p + 10, size);
  p[25] = dir ? 2 : 0;
  iso_both16(p + 28, 1); // volume sequence number
  p[32] = (uint8_t)name_len;
  memcpy(p + 33, name, name_len);
  return len;
}

static void iso_put(uint8_t *p, const char *s) { // the characters, without a NUL
  for (size_t i = 0; s[i]; i++) p[i] = (uint8_t)s[i];
}

static void iso_text(uint8_t *p, size_t len, const char *s) { // a-characters, padded with spaces
  memset(p, ' ', len);
  for (size_t i = 0; i < len && s[i]; i++) p[i] = (uint8_t)s[i];
}

// A path component as ISO 9660 names it: upper case; a file gets ".EXT;1".
static const char *iso_name(const char *name, size_t len, bool file) {
  char out[40];
  size_t n = 0;
  bool dot = false;
  for (size_t i = 0; i < len; i++) {
    char c = name[i] >= 'a' && name[i] <= 'z' ? (char)(name[i] - 32) : name[i];
    bool ok = (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || (c == '.' && file && !dot);
    if (!ok || n + 4 >= sizeof out) die("%.*s cannot be an ISO 9660 name", (int)len, name);
    dot = dot || c == '.';
    out[n++] = c;
  }
  if (file && !dot) out[n++] = '.';
  if (file) out[n++] = ';', out[n++] = '1';
  return fmt("%.*s", (int)n, out);
}

typedef struct iso_dir {
  const char *path; // "" for the root
  int parent;       // its index, once sorted
  uint32_t lba;
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

static void write_iso(const char *path, const char *boot_image, iso_file *files, int count,
                      uint32_t disk_id) {
  // The directories: each file's, and theirs, in path table order (by depth,
  // then parent, then name).
  iso_dir dirs[ISO_MAX_DIRS] = {{.path = ""}};
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

  // The layout: descriptors, path tables, a sector per directory, the boot
  // catalog, the boot image, then the files.
  enum : uint32_t { PVD = 16, BOOT_RECORD, TERMINATOR, PATH_L, PATH_M, DIRS };
  struct stat st;
  if (stat(boot_image, &st) != 0) die("cannot stat %s", boot_image);
  vx_str boot = {nullptr, (size_t)st.st_size}; // its length; it is copied in at the end
  for (int f = 0; f < count; f++) {
    if (stat(files[f].from, &st) != 0) die("cannot stat %s", files[f].from);
    files[f].size = (uint64_t)st.st_size;
  }
  uint32_t lba = DIRS;
  for (int i = 0; i < ndirs; i++) dirs[i].lba = lba++;
  uint32_t catalog = lba++, boot_lba = lba;
  lba += (uint32_t)((boot.len + ISO_SECTOR - 1) / ISO_SECTOR);
  uint32_t *file_lba = alloc((size_t)count * sizeof *file_lba);
  for (int f = 0; f < count; f++) {
    file_lba[f] = lba;
    lba += (uint32_t)((files[f].size + ISO_SECTOR - 1) / ISO_SECTOR);
  }
  uint32_t total = lba;
  uint8_t *img = alloc((size_t)boot_lba * ISO_SECTOR); // the metadata; the rest is written in place
  memset(img, 0, (size_t)boot_lba * ISO_SECTOR);

  // Path tables, little-endian and big-endian.
  uint8_t *pl = img + (size_t)PATH_L * ISO_SECTOR, *pm = img + (size_t)PATH_M * ISO_SECTOR;
  size_t ptsize = 0;
  for (int i = 0; i < ndirs; i++) {
    const char *base = strrchr(dirs[i].path, '/');
    base = base ? base + 1 : dirs[i].path;
    const char *name = i ? iso_name(base, strlen(base), false) : "\\0";
    size_t nlen = i ? strlen(name) : 1;
    uint8_t *l = pl + ptsize, *m = pm + ptsize;
    l[0] = m[0] = (uint8_t)nlen;
    put32(l + 2, dirs[i].lba);
    m[2] = (uint8_t)(dirs[i].lba >> 24), m[3] = (uint8_t)(dirs[i].lba >> 16),
    m[4] = (uint8_t)(dirs[i].lba >> 8), m[5] = (uint8_t)dirs[i].lba;
    uint16_t parent = (uint16_t)(dirs[i].parent + 1);
    put16(l + 6, parent);
    m[6] = (uint8_t)(parent >> 8), m[7] = (uint8_t)parent;
    for (size_t k = 0; k < nlen; k++) l[8 + k] = m[8 + k] = (uint8_t)name[k];
    ptsize += 8 + nlen + (nlen & 1);
  }
  if (ptsize > ISO_SECTOR) die("the ISO's path table does not fit a sector");

  // Each directory: ".", "..", then its children sorted by name.
  for (int i = 0; i < ndirs; i++) {
    uint8_t *d = img + (size_t)dirs[i].lba * ISO_SECTOR;
    size_t at = iso_record(d, dirs[i].lba, ISO_SECTOR, true, "\\0", 1);
    at += iso_record(d + at, dirs[dirs[i].parent].lba, ISO_SECTOR, true, "\\1", 1);
    const char *names[64];
    uint32_t lbas[64], sizes[64];
    bool isdir[64];
    int n = 0;
    size_t plen = strlen(dirs[i].path);
    for (int k = 1; k < ndirs; k++)
      if (dirs[k].parent == i) {
        const char *base = dirs[k].path + (plen ? plen + 1 : 0);
        names[n] = iso_name(base, strlen(base), false), lbas[n] = dirs[k].lba, sizes[n] = ISO_SECTOR,
        isdir[n++] = true;
      }
    for (int f = 0; f < count; f++) {
      const char *slash = strrchr(files[f].path, '/');
      size_t dlen = slash ? (size_t)(slash - files[f].path) : 0;
      if (dlen != plen || memcmp(files[f].path, dirs[i].path, plen) != 0) continue;
      const char *base = slash ? slash + 1 : files[f].path;
      names[n] = iso_name(base, strlen(base), true), lbas[n] = file_lba[f],
      sizes[n] = (uint32_t)files[f].size, isdir[n++] = false;
    }
    if (i == 0) { // the boot pieces, in the root
      names[n] = "BOOT.CAT;1", lbas[n] = catalog, sizes[n] = ISO_SECTOR, isdir[n++] = false;
      names[n] = "EFIBOOT.IMG;1", lbas[n] = boot_lba, sizes[n] = (uint32_t)boot.len, isdir[n++] = false;
    }
    int order[64];
    for (int k = 0; k < n; k++) order[k] = k;
    for (int k = 1; k < n; k++)
      for (int q = k; q > 0 && strcmp(names[order[q]], names[order[q - 1]]) < 0; q--) {
        int t = order[q];
        order[q] = order[q - 1];
        order[q - 1] = t;
      }
    for (int k = 0; k < n; k++) {
      int c = order[k];
      if (at + 33 + strlen(names[c]) + 1 > ISO_SECTOR) die("an ISO directory does not fit a sector");
      at += iso_record(d + at, lbas[c], sizes[c], isdir[c], names[c], strlen(names[c]));
    }
  }

  uint8_t *pvd = img + (size_t)PVD * ISO_SECTOR;
  pvd[0] = 1;
  iso_put(pvd + 1, "CD001");
  pvd[6] = 1;
  iso_text(pvd + 8, 32, "");
  iso_text(pvd + 40, 32, "VECTRAOS");
  iso_both32(pvd + 80, total);
  iso_both16(pvd + 120, 1);
  iso_both16(pvd + 124, 1);
  iso_both16(pvd + 128, ISO_SECTOR);
  iso_both32(pvd + 132, (uint32_t)ptsize);
  put32(pvd + 140, PATH_L);
  pvd[148] = 0, pvd[149] = 0, pvd[150] = 0, pvd[151] = PATH_M; // big-endian
  iso_record(pvd + 156, dirs[0].lba, ISO_SECTOR, true, "\\0", 1);
  iso_text(pvd + 190, (size_t)128 * 4, "");
  iso_text(pvd + 574, 128, "VECTRAOS BUILD");
  iso_text(pvd + 702, (size_t)37 * 3, "");
  for (size_t d = 0; d < 4; d++) memset(pvd + 813 + 17 * d, '0', 16); // dates: none
  pvd[881] = 1;

  uint8_t *br = img + (size_t)BOOT_RECORD * ISO_SECTOR; // El Torito's boot record
  iso_put(br + 1, "CD001");
  br[6] = 1;
  iso_put(br + 7, "EL TORITO SPECIFICATION");
  put32(br + 71, catalog);

  uint8_t *term = img + (size_t)TERMINATOR * ISO_SECTOR;
  term[0] = 255;
  iso_put(term + 1, "CD001");
  term[6] = 1;

  uint8_t *cat = img + (size_t)catalog * ISO_SECTOR;
  cat[0] = 1;    // the validation entry
  cat[1] = 0xef; // EFI
  cat[30] = 0x55, cat[31] = 0xaa;
  uint16_t sum = 0;
  for (int i = 0; i < 32; i += 2) sum = (uint16_t)(sum + (cat[i] | cat[i + 1] << 8));
  put16(cat + 28, (uint16_t)-sum); // the words sum to 0
  cat[32] = 0x88;                  // bootable, no emulation
  uint64_t count512 = (boot.len + 511) / 512;
  if (count512 > 0xffff) die("the ISO's boot image is too big for its catalog entry");
  put16(cat + 38, (uint16_t)count512);
  put32(cat + 40, boot_lba);

  // The MBR: one partition, the boot image, in 512-byte sectors.
  put32(img + 0x1b8, disk_id);
  uint8_t *pe = img + 446;
  pe[4] = 0xef;
  put32(pe + 8, boot_lba * (ISO_SECTOR / 512));
  put32(pe + 12, (uint32_t)count512);
  img[510] = 0x55, img[511] = 0xaa;

  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || ftruncate(fd, (off_t)total * ISO_SECTOR) != 0) die("cannot create %s", path);
  pwrite_all(fd, img, (size_t)boot_lba * ISO_SECTOR, 0, path);
  copy_into(fd, path, boot_image, (uint64_t)boot_lba * ISO_SECTOR);
  for (int f = 0; f < count; f++) copy_into(fd, path, files[f].from, (uint64_t)file_lba[f] * ISO_SECTOR);
  if (close(fd) != 0) die("cannot write %s", path);
}

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

// The directories every boot image has: mount points for the namespace (02 §5)
// and bootfs's own. In order, parents first.
static const char *const BOOTFS_DIRS[] = {"bin", "boot", "boot/bin", "boot/drv", "boot/ns", "boot/svc",
                                          "dev", "n",    "net",      "proc",     "srv",     "tmp"};

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
// boot/drv with the driver manifests from boot/drv/*.ndb, and boot/ns with the
// namespace templates from boot/ns/*.ndb.
// `with` adds test programs and their manifests (tests/user/NAME.ndb). The
// archive is deterministic: fixed order, no times or owners.
static bool make_bootfs(const arch *a, bool release, const char *with, const char *out) {
  static file_list manifests;
  manifests = (file_list){};
  port tree = {.src = root};
  collect(&manifests, &tree, (vx_str){"boot/svc", 8}, ".ndb");
  collect(&manifests, &tree, (vx_str){"boot/drv", 8}, ".ndb");
  collect(&manifests, &tree, (vx_str){"boot/ns", 7}, ".ndb");

  // Programs, then the system's manifests, then the tests': svcd starts
  // services in this order, so a test's run after what it tests.
  vx_str files[64];
  const char *paths[64];
  int count = 0;
  size_t total = 0;
  for (int i = 0; i < USER_PROGRAM_COUNT; i++) {
    const program *p = &USER_PROGRAMS[i];
    if (p->where == IN_MODULE || (p->where == IN_TESTS && !listed(with, p->name)) || !program_for(p, a))
      continue;
    files[count] = read_file(fmt("%s/%s", out_dir(a, release), p->name));
    paths[count++] = fmt("boot/bin/%s", p->name);
  }
  for (int i = 0; i < manifests.count && count < 64; i++) {
    files[count] = read_file(manifests.paths[i]);
    paths[count++] = manifests.paths[i];
  }
  for (int i = 0; i < USER_PROGRAM_COUNT && count < 64; i++) {
    if (USER_PROGRAMS[i].where != IN_TESTS || !listed(with, USER_PROGRAMS[i].name)) continue;
    files[count] = read_file(fmt("tests/user/%s.ndb", USER_PROGRAMS[i].name));
    paths[count++] = fmt("boot/svc/%s.ndb", USER_PROGRAMS[i].name);
  }
  for (int i = 0; i < count; i++) total += files[i].len + 2 * VX_TAR_BLOCK;

  vx_tar_writer w = {.cap = total + (sizeof BOOTFS_DIRS / sizeof BOOTFS_DIRS[0] + 2) * VX_TAR_BLOCK};
  w.buf = alloc(w.cap);
  for (size_t i = 0; i < sizeof BOOTFS_DIRS / sizeof BOOTFS_DIRS[0]; i++)
    vx_tar_add(&w, (vx_str){BOOTFS_DIRS[i], strlen(BOOTFS_DIRS[i])}, true, 0755, nullptr, 0);
  for (int i = 0; i < count; i++) {
    bool program = strncmp(paths[i], "boot/bin/", 9) == 0;
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

  int fd = open(esp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0 || ftruncate(fd, (off_t)ESP_BYTES) != 0) die("cannot create %s", esp);
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
    files[nf++] = (iso_file){.path = "boot/vx/kernel.elf", .from = kernel};
    files[nf++] = (iso_file){.path = "boot/vx/bootfs.tar", .from = bootfs};
    files[nf++] = (iso_file){.path = "boot/limine/limine.conf", .from = config};
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

// --- qemu and test ---

typedef struct qemu_opts {
  bool kvm;
  bool gdb;
  bool test;         // serial on stdout, no monitor
  const char *share; // the directory vx9pserve serves at 10.0.2.100!5640
  const char *u9fs;  // the root u9fs serves at 10.0.2.101!564, and its log; or nullptr
  const char *cdrom; // boot this ISO as a CD, with no disk
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
            "-machine", "virt,gic-version=3", "-cpu", "max", "-drive",
            "if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw",
            "-drive",
            "if=pflash,format=raw,unit=1,snapshot=on,file=/usr/share/edk2/aarch64/vars-template-pflash.raw",
            nullptr});
  }
  cmd_addv(c, (const char *const[]){"-m", "512M", "-smp", "4", "-display", "none", "-no-reboot", nullptr});
  cmd_add(c, "-drive");
  if (o.cdrom) { // on virtio-scsi, which both architectures' firmware boots from
    cmd_add(c, fmt("if=none,id=cd,media=cdrom,readonly=on,file=%s", o.cdrom));
    cmd_addv(c, (const char *const[]){"-device", "virtio-scsi-pci,id=scsi,disable-legacy=on", "-device",
                                      "scsi-cd,drive=cd,bus=scsi.0", nullptr});
  } else {
    // A test never writes the image, so several can boot one image at once.
    cmd_add(c, fmt("if=none,id=disk,format=raw,file=%s%s", image, o.test ? ",snapshot=on" : ""));
    cmd_addv(c, (const char *const[]){"-device", "virtio-blk-pci,drive=disk,disable-legacy=on", nullptr});
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
  cmd_addv(c, (const char *const[]){"-device", "virtio-net-pci,netdev=net0,disable-legacy=on", nullptr});
  if (o.test)
    cmd_addv(c, (const char *const[]){"-serial", "stdio", "-monitor", "none", nullptr});
  else
    cmd_addv(c, (const char *const[]){"-serial", "mon:stdio", nullptr});
  if (o.gdb) cmd_addv(c, (const char *const[]){"-s", "-S", nullptr});
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
// presses return.
static const char *scenarios[64];
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

static bool run_scenario(const arch *a, bool release, const char *name) {
  const char *path = fmt("tests/qemu/%s.ndb", name);
  vx_ndb_reader r = {.src = read_file(path), .scratch = alloc(16 << 10), .scratch_cap = 16 << 10};
  const char *expect[64], *fail[64];
  bool whole[64] = {};   // expect[k] came from line=: the whole line must be it
  bool prompt[64] = {};  // expect[k] came from prompt=: it has started a line since the last thing typed
  vx_str input[64] = {}; // typed once every expect before it has matched: input[k] goes before expect[k]
  int expect_count = 0, fail_count = 0;
  double timeout = 0;
  const char *cmdline = "", *with = "";
  bool iso = false;                        // scenario=... iso: boot the ISO, as a CD
  const char *host_file[8], *host_text[8]; // host=FILE text=...: in the share, once it passed
  int host_count = 0;
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
    } else if ((vx_ndb_has(&rec, "send") || vx_ndb_has(&rec, "type")) && expect_count < 64) {
      bool send = vx_ndb_has(&rec, "send"); // send= presses return after it; type= types exactly
      vx_str text = vx_ndb_get(&rec, send ? "send" : "type"), *in = &input[expect_count];
      in->ptr =
          fmt("%.*s%.*s%s", (int)in->len, in->ptr ? in->ptr : "", (int)text.len, text.ptr, send ? "\r" : "");
      in->len += text.len + send;
    } else {
      if (expect_count == 64 || fail_count == 64)
        die("%s:%zu: more than 64 expect= or fail= records", path, rec.line);
      die("%s:%zu: expected scenario=, expect=, line=, prompt=, fail=, send=, type= or host=", path,
          rec.line);
    }
  }
  if (timeout <= 0 || expect_count == 0) die("%s: needs scenario= with a timeout, and an expect=", path);

  const char *image = image_path(a, release), *cdrom = nullptr;
  if (*cmdline || *with || iso) {
    image = fmt("%s/test-%s.img", out_dir(a, release), name);
    if (iso) cdrom = fmt("%s/test-%s.iso", out_dir(a, release), name);
    if (!make_image(a, release, image, cmdline, with, cdrom)) return false;
  }

  const char *log_path = fmt("%s/test-%s.log", out_dir(a, release), name);
  FILE *log = fopen(log_path, "w");
  if (!log) die("cannot write %s", log_path);

  cmd c = {};
  // What the run's servers serve, fresh: run-NAME/share for vx9pserve, run-NAME/u9fs for u9fs.
  const char *run_dir = fmt("%s/run-%s", out_dir(a, release), name);
  const char *share = fresh_share(fmt("%s/share", run_dir)), *u9fs = fresh_u9fs_root(fmt("%s/u9fs", run_dir));
  qemu_cmd(&c, a, image,
           (qemu_opts){.kvm = kvm_usable(a), .test = true, .share = share, .u9fs = u9fs, .cdrom = cdrom});
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
  int next = 0, typed = -1; // input[typed] has been typed
  const char *verdict = nullptr;
  char line[4096];
  size_t len = 0;
  static char since[64 * 1024]; // the output since the last thing typed, for prompt=
  size_t since_len = 0;
  bool since_cut = false; // since[0] is mid-line: older output was let go
  static char buf[4096];  // read from QEMU; [pos, n) not looked at yet
  ssize_t n = 0, pos = 0;
  while (!verdict) {
    if (typed < next && input[next].len) {
      if (write(keys[1], input[next].ptr, input[next].len) != (ssize_t)input[next].len) {
        verdict = "cannot type into QEMU (it has exited?)"; // QEMU is still killed, and the log kept
        break;
      }
      typed = next;
      since_len = 0;
      since_cut = false;
    }
    if (pos == n) { // all looked at: read more
      double left = timeout - (now_seconds() - start);
      if (left <= 0) {
        verdict = fmt("timed out waiting for \"%s\"", expect[next]);
        break;
      }
      struct pollfd pfd = {.fd = fds[0], .events = POLLIN};
      if (poll(&pfd, 1, (int)(left * 1000) + 1) <= 0) continue;
      n = read(fds[0], buf, sizeof buf);
      pos = 0;
      if (n <= 0) {
        verdict = "QEMU exited";
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
      if (!verdict && !prompt[next] &&
          (whole[next] ? strcmp(line, expect[next]) == 0 : strstr(line, expect[next]) != nullptr)) {
        next++;
        if (next == expect_count) verdict = "ok";
        if (input[next].len && typed < next) break; // type it before looking at what follows
      }
    }
    // A prompt has no newline after it, and may share its line with other
    // programs' output: it counts if it started any line since the last thing
    // typed.
    size_t plen = next < expect_count && prompt[next] ? strlen(expect[next]) : 0;
    for (size_t at = 0; !verdict && plen && at + plen <= since_len; at++) {
      bool line_start = at ? since[at - 1] == '\n' : !since_cut;
      if (!line_start || memcmp(since + at, expect[next], plen) != 0) continue;
      since_len = 0; // used: the next prompt= needs a prompt after this one
      since_cut = false;
      if (++next == expect_count) verdict = "ok";
      break;
    }
  }
  kill(pid, SIGKILL);
  wait_ok(pid);
  close(fds[0]);
  close(keys[1]);
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

  bool ok = strcmp(verdict, "ok") == 0;
  fprintf(stderr, "  TEST  %-11s %-8s %s (%.1f s)%s\n", name, a->name, ok ? "ok" : "FAIL",
          now_seconds() - start, ok ? "" : fmt(": %s; serial log in %s", verdict, log_path));
  return ok;
}

// Builds the image, then runs every scenario at once, each in its own QEMU.
// Runs the scenarios, a few at a time: each QEMU has 4 CPUs of its own, and
// with every architecture's scenarios at once, all at once would starve each
// other into their timeouts. Half the host's CPUs per architecture, at least 2.
static bool test_arch(const arch *a, bool release) {
  if (!build_image(a, release)) return false;
  long cpus = sysconf(_SC_NPROCESSORS_ONLN);
  int slots = cpus >= 4 ? (int)(cpus / 2) : 2, running = 0;
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

static int cmd_test(const arch *only, bool release) {
  if (scenario_count == 0) {
    static file_list found;
    port dir = {.src = fmt("%s/tests", root)};
    collect(&found, &dir, (vx_str){"qemu", 4}, ".ndb");
    if (found.count > 64) die("more than 64 scenarios in tests/qemu");
    for (int i = 0; i < found.count; i++) {
      const char *base = strrchr(found.paths[i], '/') + 1;
      scenarios[scenario_count++] = fmt("%.*s", (int)(strlen(base) - 4), base);
    }
  }
  if (!build_vx9pserve() || !build_u9fs()) return 1;
  return per_arch(only, release, test_arch);
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
    nullptr,
};

// Each tests/host/*_test.c is one translation unit: the library it includes and
// its checks. It is built for the host under ASan and UBSan, and run.
static bool check_host_tests(void) {
  static file_list tests;
  port dir = {.src = fmt("%s/tests", root)};
  collect(&tests, &dir, (vx_str){"host", 4}, "_test.c");
  mkdirs("out/host");
  bool ok = true;
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
    cmd run_test = {};
    cmd_add(&run_test, exe);
    bool passed = run(&cc) && run(&run_test);
    fprintf(stderr, "  HOST  %-16s %s\n", name, passed ? "ok" : "FAIL");
    ok = ok && passed;
  }
  return ok;
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
  const char *const *flags[4];
} unit;

static const char *const HOST_C23[] = {"-std=c23", nullptr};

static constexpr int MAX_UNITS = 128;

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
      unit *u = &units[unit_slot(&n)];
      *u = (unit){fmt("%s %s", p->name, ARCHES[i].name), p->source, {}};
      u->flags[0] = p->posix ? posix_flags(&ARCHES[i]) : ARCHES[i].user_flags;
      u->flags[1] = HOUSE_FLAGS;
      u->flags[2] = p->posix ? POSIX_PROGRAM_FLAGS : USER_FLAGS;
    }
    units[unit_slot(&n)] = (unit){fmt("libc-vx %s", ARCHES[i].name),
                                  "ports/musl/vx/backend.c",
                                  {posix_flags(&ARCHES[i]), HOUSE_FLAGS, POSIX_BACKEND_FLAGS}};
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
      units[unit_slot(&n)] = (unit){tests.paths[i] + 5, fmt("tests/%s", tests.paths[i]), {HOST_C23}};
  }
  return n;
}

// Runs one tool over each unit, one at a time so each report reads whole: the
// command `before`, the unit's flags, `after`, then the source. A tool that
// takes its source first, with the compiler flags after a separator (clang-tidy
// and `--`), passes that separator instead.
static bool check_units(const char *tag, bool with_host_tests, const char *const *before,
                        const char *const *after, const char *separator) {
  static unit units[MAX_UNITS];
  int n = os_units(units, with_host_tests);
  bool ok = true;
  for (int i = 0; i < n; i++) {
    cmd c = {};
    cmd_addv(&c, before);
    if (separator) {
      cmd_add(&c, units[i].source);
      cmd_add(&c, separator);
    }
    for (int f = 0; f < 4 && units[i].flags[f]; f++) cmd_addv(&c, units[i].flags[f]);
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

static int cmd_check(void) {
  bool ok = check_host_tests();
  ok = check_fuzz() && ok;
  ok = cmd_vendor_check() == 0 && ok;
  ok = check_format() && ok;
  ok = check_analyzer() && ok;
  ok = check_tidy() && ok;
  ok = check_build_time() && ok;
  fprintf(stderr, "build: check %s\n", ok ? "passed" : "FAILED");
  return ok ? 0 : 1;
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
      "  loc                                            the line-count ledger\n"
      "  vendor-check                                   check third_party/ against VENDOR.ndb\n"
      "  check                                          host tests (ASan, UBSan), the fuzzers, vendor-check, "
      "the format,\n"
      "                                                 the static analyzer and the build-time budget: CI's "
      "first job\n"
      "\n"
      "A is x86_64 or aarch64. qemu defaults to x86_64.\n"
      "Still to come: bench, and in check, the vx-check models (M2).\n");
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
    } else if (strcmp(argv[i], "--arch") == 0 && i + 1 < argc) {
      i++;
      for (int a = 0; a < ARCH_COUNT; a++)
        if (strcmp(argv[i], ARCHES[a].name) == 0) only = &ARCHES[a];
      if (!only) die("unknown architecture %s", argv[i]);
    } else if (argv[i][0] != '-' && strcmp(command, "test") == 0 && scenario_count < 64) {
      scenarios[scenario_count++] = argv[i];
    } else {
      usage();
    }
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
