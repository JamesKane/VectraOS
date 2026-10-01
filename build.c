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
static const char CLANG_FORMAT_VERSION[] = "clang-format version 22.1.8 (Fedora 22.1.8-4.fc44)";
static const char CLANG_TIDY_VERSION[] = "LLVM version 22.1.8";
static const char NASM_VERSION[] = "NASM version 3.02 compiled on Jul 14 2026"; // nasm-3.02-1.fc44

// When any of these changes, ./build rebuilds itself, and cached ports rebuild.
static const char *const BUILD_SOURCES[] = {
    "build.c",      "lib/vx-ndb/ndb.h",    "lib/vx-ndb/ndb.c",  "lib/vx-sha256/sha256.c",
    "abi/vx/abi.h", "abi/vx/syscalls.def", "abi/vx/rights.def", "abi/vx/status.def",
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

// Debug builds of the OS tree, kernel and user space, trap on undefined behaviour.
static const char *const DEBUG_FLAGS[] = {
    "-O1", "-fsanitize=undefined", "-fno-sanitize=function", "-fsanitize-trap=undefined", nullptr,
};

static const char *const RELEASE_FLAGS[] = {"-O2", nullptr};

// First-party user programs in M1: freestanding, static, non-PIE, against
// lib/vx-rt. No FP/SIMD until the kernel saves that state (M2).
static const char *const USER_FLAGS[] = {
    "-ffreestanding",
    "-fno-pic",
    "-mgeneral-regs-only",
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
static char arena[32 << 20];
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
  p->input_hash = h;
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
  for (int i = 0; i < asm_files.count && i < 63; i++)
    sources[i + 1] = fmt("kernel/arch/%s", asm_files.paths[i]);
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
} program;

static const program USER_PROGRAMS[] = {
    {"svcd", "servers/svcd/svcd.c", IN_MODULE, nullptr},
    {"ktest", "tests/kernel/ktest.c", IN_MODULE, nullptr}, // the root task instead of svcd with vx.root=ktest
    {"bootfs", "servers/bootfs/bootfs.c", IN_BOOTFS, nullptr},
    {"nstest", "tests/user/nstest.c", IN_TESTS, nullptr},
    {"constest", "tests/user/constest.c", IN_TESTS, nullptr},
    {"drv-uart-16550", "drivers/drv-uart-16550/uart.c", IN_BOOTFS, "x86_64"},
    {"drv-uart-pl011", "drivers/drv-uart-pl011/uart.c", IN_BOOTFS, "aarch64"},
};

static bool program_for(const program *p, const arch *a) { return !p->arch || strcmp(p->arch, a->name) == 0; }
static constexpr int USER_PROGRAM_COUNT = sizeof USER_PROGRAMS / sizeof USER_PROGRAMS[0];

static bool build_user_program(const arch *a, bool release, const char *name, const char *source) {
  const char *dir = fmt("out/%s/%s", a->name, release ? "release" : "debug");
  const char *obj = fmt("%s/%s.o", dir, name);
  const char *elf = fmt("%s/%s", dir, name);
  fprintf(stderr, "  CC    %-7s %s\n", name, a->name);
  cmd cc = {};
  cmd_add(&cc, CLANG);
  cmd_addv(&cc, a->user_flags);
  cmd_addv(&cc, HOUSE_FLAGS);
  cmd_addv(&cc, USER_FLAGS);
  cmd_addv(&cc, release ? RELEASE_FLAGS : DEBUG_FLAGS);
  cmd_add(&cc, fmt("-ffile-prefix-map=%s=/src", root));
  cmd_add(&cc, "-c");
  cmd_add(&cc, source);
  cmd_add(&cc, "-o");
  cmd_add(&cc, obj);
  if (!run(&cc)) return false;

  cmd ld = {};
  cmd_add(&ld, LLD);
  cmd_addv(&ld, (const char *const[]){"-static", "-nostdlib", "--build-id=sha1", "-z", "max-page-size=0x1000",
                                      "-z", "noexecstack", "-e", "_start", "-o", nullptr});
  cmd_add(&ld, elf);
  cmd_add(&ld, obj);
  return run(&ld);
}

static bool build_arch(const arch *a, bool release) {
  if (!build_kernel(a, release)) return false;
  for (int i = 0; i < USER_PROGRAM_COUNT; i++)
    if (program_for(&USER_PROGRAMS[i], a) &&
        !build_user_program(a, release, USER_PROGRAMS[i].name, USER_PROGRAMS[i].source))
      return false;
  const vx_ndb_record *t = port_target_for(&limine, a);
  return !t || build_port_target(&limine, t);
}

static void check_toolchain(void) {
  check_version(CLANG, CLANG_VERSION);
  check_version(LLD, LLD_VERSION);
  check_version(OBJCOPY, OBJCOPY_VERSION);
  port_load(&limine, "limine");
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
static const char *const BOOTFS_DIRS[] = {"bin", "boot", "boot/bin", "boot/svc", "dev", "proc", "srv", "tmp"};

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
// in bootfs, and boot/svc with the service manifests from boot/svc/*.ndb.
// `with` adds test programs and their manifests (tests/user/NAME.ndb). The
// archive is deterministic: fixed order, no times or owners.
static bool make_bootfs(const arch *a, bool release, const char *with, const char *out) {
  static file_list manifests;
  manifests = (file_list){};
  port tree = {.src = root};
  collect(&manifests, &tree, (vx_str){"boot/svc", 8}, ".ndb");

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
static bool make_image(const arch *a, bool release, const char *image, const char *cmdline,
                       const char *with) {
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
  unlink(esp);
  unlink(bootfs);
  return true;
}

static bool build_image(const arch *a, bool release) {
  return build_arch(a, release) && make_image(a, release, image_path(a, release), nullptr, "");
}

// --- qemu and test ---

typedef struct qemu_opts {
  bool kvm;
  bool gdb;
  bool test; // serial on stdout, no monitor
} qemu_opts;

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
  cmd_add(c, fmt("if=none,id=disk,format=raw,file=%s", image));
  cmd_addv(c, (const char *const[]){"-device", "virtio-blk-pci,drive=disk", nullptr});
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
// against serial output lines, and fail= records, any of which fails the test
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
  vx_str input[64] = {}; // typed once every expect before it has matched: input[k] goes before expect[k]
  int expect_count = 0, fail_count = 0;
  double timeout = 0;
  const char *cmdline = "", *with = "";
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
    } else if (vx_ndb_has(&rec, "expect") && expect_count < 64) {
      expect[expect_count++] = substitute_arch(vx_ndb_get(&rec, "expect"), a);
    } else if (vx_ndb_has(&rec, "fail") && fail_count < 64) {
      fail[fail_count++] = substitute_arch(vx_ndb_get(&rec, "fail"), a);
    } else if ((vx_ndb_has(&rec, "send") || vx_ndb_has(&rec, "type")) && expect_count < 64) {
      bool send = vx_ndb_has(&rec, "send"); // send= presses return after it; type= types exactly
      vx_str text = vx_ndb_get(&rec, send ? "send" : "type"), *in = &input[expect_count];
      in->ptr =
          fmt("%.*s%.*s%s", (int)in->len, in->ptr ? in->ptr : "", (int)text.len, text.ptr, send ? "\r" : "");
      in->len += text.len + send;
    } else {
      die("%s:%zu: expected scenario=, expect=, fail=, send= or type=", path, rec.line);
    }
  }
  if (timeout <= 0 || expect_count == 0) die("%s: needs scenario= with a timeout, and an expect=", path);

  const char *image = image_path(a, release);
  if (*cmdline || *with) {
    image = fmt("%s/test-%s.img", out_dir(a, release), name);
    if (!make_image(a, release, image, cmdline, with)) return false;
  }

  const char *log_path = fmt("%s/test-%s.log", out_dir(a, release), name);
  FILE *log = fopen(log_path, "w");
  if (!log) die("cannot write %s", log_path);

  cmd c = {};
  qemu_cmd(&c, a, image, (qemu_opts){.kvm = kvm_usable(a), .test = true});
  if (verbose) cmd_print(&c);
  int fds[2], keys[2]; // QEMU's serial: its output, and what is typed into it
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
  while (!verdict) {
    if (typed < next && input[next].len) {
      if (write(keys[1], input[next].ptr, input[next].len) != (ssize_t)input[next].len)
        die("cannot type into QEMU");
      typed = next;
    }
    double left = timeout - (now_seconds() - start);
    if (left <= 0) {
      verdict = fmt("timed out waiting for \"%s\"", expect[next]);
      break;
    }
    struct pollfd pfd = {.fd = fds[0], .events = POLLIN};
    if (poll(&pfd, 1, (int)(left * 1000) + 1) <= 0) continue;
    char buf[4096];
    ssize_t n = read(fds[0], buf, sizeof buf);
    if (n <= 0) {
      verdict = "QEMU exited";
      break;
    }
    fwrite(buf, 1, (size_t)n, log);
    for (ssize_t i = 0; i < n && !verdict; i++) {
      if (buf[i] == '\r') continue;
      if (buf[i] != '\n' && len < sizeof line - 1) {
        line[len++] = buf[i];
        continue;
      }
      if (buf[i] != '\n') continue;
      line[len] = 0;
      len = 0;
      for (int k = 0; k < fail_count; k++)
        if (strstr(line, fail[k])) verdict = fmt("failure line: %s", line);
      if (!verdict && strstr(line, expect[next])) {
        next++;
        if (next == expect_count) verdict = "ok";
      }
    }
  }
  kill(pid, SIGKILL);
  wait_ok(pid);
  close(fds[0]);
  close(keys[1]);
  fclose(log);

  bool ok = strcmp(verdict, "ok") == 0;
  fprintf(stderr, "  TEST  %-11s %-8s %s (%.1f s)%s\n", name, a->name, ok ? "ok" : "FAIL",
          now_seconds() - start, ok ? "" : fmt(": %s; serial log in %s", verdict, log_path));
  return ok;
}

// Builds the image, then runs every scenario at once, each in its own QEMU.
static bool test_arch(const arch *a, bool release) {
  if (!build_image(a, release)) return false;
  pid_t pids[64] = {};
  int count = scenario_count;
  for (int i = 0; i < count; i++) {
    pids[i] = fork();
    if (pids[i] < 0) die("fork failed");
    if (pids[i] == 0) _exit(run_scenario(a, release, scenarios[i]) ? 0 : 1);
  }
  bool ok = true;
  for (int i = 0; i < count; i++) ok = wait_ok(pids[i]) && ok;
  return ok;
}

static int cmd_test(const arch *only, bool release) {
  if (scenario_count == 0) {
    static file_list found;
    port dir = {.src = fmt("%s/tests", root)};
    collect(&found, &dir, (vx_str){"qemu", 4}, ".ndb");
    for (int i = 0; i < found.count && scenario_count < 64; i++) {
      const char *base = strrchr(found.paths[i], '/') + 1;
      scenarios[scenario_count++] = fmt("%.*s", (int)(strlen(base) - 4), base);
    }
  }
  return per_arch(only, release, test_arch);
}

static int cmd_qemu(const arch *a, bool release, qemu_opts o) {
  if (!build_image(a, release)) return 1;
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
    "version", "upstream", "sha256", "tree.sha256", "license", "adr", "reviewed.by", nullptr,
};
static const char *const VENDOR_OPTIONAL_KEYS[] = {
    "name", "signed.by", "port", "patches", "reviewed.date", "reviewed.scope", nullptr,
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

  // Every directory under third_party/ has a record.
  DIR *d = opendir("third_party");
  if (!d) die("cannot read third_party/");
  for (struct dirent *e; (e = readdir(d));) {
    if (e->d_name[0] == '.' || e->d_type != DT_DIR) continue;
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

static int cmd_all(const arch *only, bool release) { return per_arch(only, release, build_arch); }

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
static const char *const GROUPED[] = {"lib", "servers", "drivers", "apps", "third_party", nullptr};

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

  long n = count_lines(path);
  component_for(name, strncmp(path, "third_party/", 12) == 0)->lines += n;

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
    cmd_addv(&fuzz, (const char *const[]){"-max_len=4096", "-print_final_stats=0",
                                          "-artifact_prefix=out/fuzz/", nullptr});
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

static int os_units(unit *units, bool with_host_tests) {
  int n = 0;
  for (int i = 0; i < ARCH_COUNT; i++) {
    units[n++] = (unit){
        fmt("kernel %s", ARCHES[i].name), "kernel/kernel.c", {ARCHES[i].flags, HOUSE_FLAGS, KERNEL_FLAGS}};
    for (int k = 0; k < USER_PROGRAM_COUNT; k++)
      if (program_for(&USER_PROGRAMS[k], &ARCHES[i]))
        units[n++] = (unit){fmt("%s %s", USER_PROGRAMS[k].name, ARCHES[i].name),
                            USER_PROGRAMS[k].source,
                            {ARCHES[i].user_flags, HOUSE_FLAGS, USER_FLAGS}};
  }
  units[n++] = (unit){"build", "build.c", {HOST_C23}};
  if (with_host_tests) {
    static file_list tests;
    tests = (file_list){};
    port dir = {.src = fmt("%s/tests", root)};
    collect(&tests, &dir, (vx_str){"host", 4}, "_test.c");
    collect(&tests, &dir, (vx_str){"fuzz", 4}, "_fuzz.c");
    for (int i = 0; i < tests.count && n < 64; i++)
      units[n++] = (unit){tests.paths[i] + 5, fmt("tests/%s", tests.paths[i]), {HOST_C23}};
  }
  return n;
}

// Runs one tool over each unit, one at a time so each report reads whole: the
// command `before`, the unit's flags, `after`, then the source. A tool that
// takes its source first, with the compiler flags after a separator (clang-tidy
// and `--`), passes that separator instead.
static bool check_units(const char *tag, bool with_host_tests, const char *const *before,
                        const char *const *after, const char *separator) {
  unit units[64];
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
static const char *const FORMATTED_DIRS[] = {"abi",        "kernel",     "lib",  "servers",
                                             "tests/host", "tests/fuzz", nullptr};

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
    for (int k = 0; k < USER_PROGRAM_COUNT; k++) {
      if (!program_for(&USER_PROGRAMS[k], &ARCHES[i])) continue;
      t0 = now_seconds();
      ok = build_user_program(&ARCHES[i], false, USER_PROGRAMS[k].name, USER_PROGRAMS[k].source) && ok;
      total += now_seconds() - t0;
    }
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
      "  image         [--arch A] [--release]          a GPT disk image: out/A/MODE/vectra-A.img\n"
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
      "Still to come: bench, image --iso, and in check, the vx-check models (M2).\n");
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
