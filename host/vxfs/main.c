// vxfs: makes, fills, reads and checks vx-fs volume images on the build
// machine (docs/11 §7), with the library fsd uses.
//
//   vxfs mkfs [-u USER] IMAGE MIB BRANCH...
//                                       a new volume of MIB MiB, an empty root in each branch;
//                                       with an adm branch, /adm/users: adm, none and USER
//                                       (vectra by default), who owns home's root
//   vxfs put IMAGE BRANCH DIR           DIR's tree copied into the branch's root, committed
//   vxfs ls IMAGE LABEL [PATH]          a directory's entries
//   vxfs cat IMAGE LABEL PATH           a file's contents, to stdout
//   vxfs verify IMAGE LABEL DIR         exit 0 if the label holds DIR's tree exactly
//   vxfs check IMAGE                    the checker; exit 0 if the volume is clean
//   vxfs info IMAGE                     the last commit, arenas, labels and space
//   vxfs snap IMAGE BRANCH LABEL        as /adm/ctl's commands (11 §9), each committed
//   vxfs fork IMAGE LABEL BRANCH
//   vxfs del IMAGE LABEL
//   vxfs rollback IMAGE BRANCH LABEL
//
// A LABEL is a snapshot's or a branch's (its last commit). Files are copied
// with their modes, mtimes and symbolic links, owned by the branch root's
// owner.

#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "../../lib/vx-fs/check.c"
#include "../../lib/vx-fs/file.c"

static const char *image;

[[noreturn]] static void die(const char *fmt, const char *what, vx_status st) {
  fprintf(stderr, "vxfs: ");
  fprintf(stderr, fmt, what);
  if (st != VX_OK) fprintf(stderr, ": status %d", st);
  fprintf(stderr, "\n");
  exit(1);
}

// --- The image as a device ---

static vx_status img_read(void *ctx, uint64_t addr, void *buf) {
  return pread(*(int *)ctx, buf, VXFS_BLKSZ, (off_t)addr) == VXFS_BLKSZ ? VX_OK : VX_ERR_IO;
}
static vx_status img_write(void *ctx, uint64_t addr, const void *buf) {
  return pwrite(*(int *)ctx, buf, VXFS_BLKSZ, (off_t)addr) == VXFS_BLKSZ ? VX_OK : VX_ERR_IO;
}
static vx_status img_barrier(void *ctx) { return fdatasync(*(int *)ctx) == 0 ? VX_OK : VX_ERR_IO; }
static void *m_alloc([[maybe_unused]] void *ctx, size_t n) { return malloc(n); }
static void m_free([[maybe_unused]] void *ctx, void *p, [[maybe_unused]] size_t n) { free(p); }

static int fd = -1;
static vxfs_vol vol;
static constexpr uint32_t CACHE = 4096; // blocks: 64 MiB

static vxfs_dev open_image(const char *path, bool create, uint64_t size) {
  fd = open(path, O_RDWR | (create ? O_CREAT | O_TRUNC : 0), 0644);
  if (fd < 0) die("cannot open %s", path, VX_OK);
  if (create && ftruncate(fd, (off_t)size) != 0) die("cannot size %s", path, VX_OK);
  struct stat st;
  if (fstat(fd, &st) != 0) die("cannot stat %s", path, VX_OK);
  return (vxfs_dev){
      .ctx = &fd, .read = img_read, .write = img_write, .barrier = img_barrier, .size = (uint64_t)st.st_size};
}

static const vxfs_mem MEM = {.alloc = m_alloc, .free = m_free};

static void mount(void) {
  vx_status st = vxfs_mount(&vol, open_image(image, false, 0), MEM, CACHE);
  if (st != VX_OK) die("%s: not a volume it can mount", image, st);
}

static void finish(void) {
  vx_status st = vxfs_commit(&vol);
  if (st != VX_OK) die("%s: the commit failed", image, st);
  vxfs_unmount(&vol);
  close(fd);
}

static int64_t ns_of(struct timespec t) { return (int64_t)t.tv_sec * 1'000'000'000 + t.tv_nsec; }

static vxfs_tree label_tree(const char *label) {
  vxfs_tree t;
  vx_status st = vxfs_snap_open(&vol, label, &t);
  if (st != VX_OK) die("no label %s", label, st);
  return t;
}

// --- mkfs: the users file, and home's owner ---

static constexpr uint32_t USER_ID = 1000;

// users(6) as gefs's ream writes it: adm, whose group USER is in; none;
// USER. adm is 0, as POSIX's root is.
static vx_status make_users(const char *name, int64_t now) {
  vxfs_branch *br;
  vxfs_file root, f;
  vx_status st = vxfs_branch_open(&vol, "adm", &br);
  if (st == VX_ERR_NOT_FOUND) return VX_OK; // no adm branch: no users file
  char text[256];
  int n = snprintf(text, sizeof text, "0:adm:adm:%s\n1:none::\n%u:%s:%s:\n", name, USER_ID, name, name);
  if (st == VX_OK) st = vxfs_root(&vol, &br->t, &root);
  if (st == VX_OK) st = vxfs_create(&vol, &br->t, &root, "users", 0664, 0, 0, now, &f);
  if (st == VX_OK) st = vxfs_write(&vol, &br->t, &f, 0, text, (uint64_t)n, now, 0);
  if (st != VX_OK) return st;
  if ((st = vxfs_branch_open(&vol, "home", &br)) != VX_OK) return st == VX_ERR_NOT_FOUND ? VX_OK : st;
  vxfs_attr a = {.valid = VXFS_WUID | VXFS_WGID, .uid = USER_ID, .gid = USER_ID};
  if ((st = vxfs_root(&vol, &br->t, &root)) == VX_OK) st = vxfs_setattr(&vol, &br->t, &root, &a, now);
  return st;
}

// --- put: a host tree copied in ---

static uint64_t copied;
static uint32_t owner, group; // the branch root's

// NOLINTNEXTLINE(misc-no-recursion): as deep as the host tree
static void put_dir(vxfs_tree *t, const vxfs_file *dir, const char *host) {
  DIR *d = opendir(host);
  if (!d) die("cannot read %s", host, VX_OK);
  static uint8_t buf[1 << 20];
  for (struct dirent *e; (e = readdir(d));) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", host, e->d_name);
    struct stat st;
    if (lstat(path, &st) != 0) die("cannot stat %s", path, VX_OK);
    int64_t mtime = ns_of(st.st_mtim);
    vxfs_file f;
    vx_status s;
    if (S_ISDIR(st.st_mode)) {
      s = vxfs_create(&vol, t, dir, e->d_name, VXFS_DMDIR | (st.st_mode & 07777), owner, group, mtime, &f);
      if (s != VX_OK) die("cannot make %s", path, s);
      put_dir(t, &f, path);
    } else if (S_ISLNK(st.st_mode)) {
      char target[4097];
      ssize_t n = readlink(path, target, sizeof target - 1);
      if (n <= 0) die("cannot read the link %s", path, VX_OK);
      target[n] = 0;
      s = vxfs_symlink(&vol, t, dir, e->d_name, target, owner, group, mtime, &f);
      if (s != VX_OK) die("cannot make the link %s", path, s);
    } else if (S_ISREG(st.st_mode)) {
      s = vxfs_create(&vol, t, dir, e->d_name, st.st_mode & 07777, owner, group, mtime, &f);
      if (s != VX_OK) die("cannot make %s", path, s);
      int in = open(path, O_RDONLY);
      if (in < 0) die("cannot open %s", path, VX_OK);
      uint64_t off = 0;
      for (ssize_t n; (n = read(in, buf, sizeof buf)) > 0; off += (uint64_t)n)
        if ((s = vxfs_write(&vol, t, &f, off, buf, (uint64_t)n, mtime, 0)) != VX_OK)
          die("cannot write %s", path, s);
      close(in);
      copied += off;
    } else {
      continue; // devices, sockets and fifos have no place in a volume image
    }
    vxfs_attr a = {.valid = VXFS_WMTIME | VXFS_WATIME, .mtime = mtime, .atime = mtime};
    if ((s = vxfs_setattr(&vol, t, &f, &a, mtime)) != VX_OK) die("cannot set the times of %s", path, s);
  }
  closedir(d);
}

// --- verify: a label against a host tree ---

static bool same_file(const vxfs_tree *t, const vxfs_file *f, const char *path, uint64_t size) {
  static uint8_t a[1 << 20], b[1 << 20];
  if (f->d.length != size) return false;
  int in = open(path, O_RDONLY);
  if (in < 0) return false;
  bool same = true;
  for (uint64_t off = 0; same && off < size;) {
    ssize_t n = read(in, a, sizeof a);
    uint64_t got = 0;
    same = n > 0 && vxfs_read(&vol, t, f, off, b, (uint64_t)n, &got) == VX_OK && got == (uint64_t)n &&
           memcmp(a, b, got) == 0;
    off += n > 0 ? (uint64_t)n : 0;
  }
  close(in);
  return same;
}

typedef struct counting {
  uint32_t n;
} counting;

static bool count_entry(void *ctx, [[maybe_unused]] const char *name, [[maybe_unused]] uint16_t n,
                        [[maybe_unused]] const vxfs_dir *d) {
  ((counting *)ctx)->n++;
  return true;
}

// NOLINTNEXTLINE(misc-no-recursion): as deep as the host tree
static bool verify_dir(const vxfs_tree *t, const vxfs_file *dir, const char *host) {
  DIR *d = opendir(host);
  if (!d) return false;
  bool ok = true;
  uint32_t entries = 0;
  for (struct dirent *e; ok && (e = readdir(d));) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", host, e->d_name);
    struct stat st;
    vxfs_file f;
    if (lstat(path, &st) != 0) ok = false;
    if (ok && !S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode) && !S_ISREG(st.st_mode)) continue;
    entries++;
    ok = ok && vxfs_walk(&vol, t, dir, e->d_name, &f) == VX_OK;
    if (ok && S_ISDIR(st.st_mode)) {
      ok = (f.d.mode & VXFS_DMDIR) && verify_dir(t, &f, path);
    } else if (ok && S_ISLNK(st.st_mode)) {
      char target[4097], got[4097];
      ssize_t n = readlink(path, target, sizeof target - 1);
      uint64_t g = 0;
      ok = n > 0 && (f.d.mode & VXFS_DMSYMLINK) && vxfs_read(&vol, t, &f, 0, got, sizeof got, &g) == VX_OK &&
           g == (uint64_t)n && memcmp(target, got, g) == 0;
    } else if (ok) {
      ok = !(f.d.mode & (VXFS_DMDIR | VXFS_DMSYMLINK)) && (f.d.mode & 07777) == (st.st_mode & 07777) &&
           f.d.mtime == ns_of(st.st_mtim) && same_file(t, &f, path, (uint64_t)st.st_size);
    }
    if (!ok) fprintf(stderr, "vxfs: %s differs\n", path);
  }
  closedir(d);
  counting c = {};
  if (ok && (vxfs_readdir(&vol, t, dir, count_entry, &c) != VX_OK || c.n != entries)) {
    fprintf(stderr, "vxfs: %s holds other entries too\n", host);
    ok = false;
  }
  return ok;
}

// --- ls, info ---

static bool print_entry([[maybe_unused]] void *ctx, const char *name, uint16_t n, const vxfs_dir *d) {
  char kind = '-';
  if (d->mode & VXFS_DMDIR) kind = 'd';
  if (d->mode & VXFS_DMSYMLINK) kind = 'L';
  printf("%c%04o %4u %10llu %.*s\n", kind, d->mode & 07777, d->uid, (unsigned long long)d->length, (int)n,
         name);
  return true;
}

static void info(void) {
  printf("commit %llu, %u arenas, next generation %llu\n", (unsigned long long)vol.sb.commit, vol.fs.narenas,
         (unsigned long long)vol.sb.nextgen);
  uint64_t used = 0, size = 0;
  for (uint32_t i = 0; i < vol.fs.narenas; i++) used += vol.fs.arenas[i].used, size += vol.fs.arenas[i].size;
  printf("used %llu of %llu KiB\n", (unsigned long long)(used / 1024), (unsigned long long)(size / 1024));
  uint8_t pfx = VXFS_KLABEL;
  vxfs_scan s;
  vxfs_scan_start(&s, &vol.snap, &pfx, 1);
  vxfs_kvp kv;
  while (vxfs_scan_next(&vol.fs, &s, &kv))
    if (kv.nv == 12)
      printf("%s %.*s: snapshot %llu\n", vxfs_get32(kv.v + 8) & VXFS_LMUT ? "branch" : "label",
             (int)(kv.nk - 1), (const char *)kv.k + 1, (unsigned long long)vxfs_get64(kv.v));
  vxfs_scan_end(&vol.fs, &s);
}

[[noreturn]] static void usage(void) {
  fprintf(stderr,
          "usage: vxfs mkfs [-u USER] IMAGE MIB BRANCH... | put IMAGE BRANCH DIR | ls IMAGE LABEL [PATH] |\n"
          "       cat IMAGE LABEL PATH | verify IMAGE LABEL DIR | check IMAGE | info IMAGE |\n"
          "       snap IMAGE BRANCH LABEL | fork IMAGE LABEL BRANCH | del IMAGE LABEL |\n"
          "       rollback IMAGE BRANCH LABEL\n");
  exit(2);
}

int main(int argc, char **argv) {
  if (argc < 3) usage();
  const char *cmd = argv[1], *name = "vectra";
  if (!strcmp(cmd, "mkfs") && argc >= 4 && !strcmp(argv[2], "-u")) { // -u USER: the volume's user
    name = argv[3];
    argv += 2, argc -= 2;
  }
  image = argv[2];
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  vx_status st;
  if (!strcmp(cmd, "mkfs") && argc >= 5) {
    char *end;
    unsigned long mib = strtoul(argv[3], &end, 10);
    if (*end || mib < 1 || mib > (1ul << 22)) die("%s is not a size in MiB", argv[3], VX_OK);
    vxfs_dev dev = open_image(image, true, (uint64_t)mib << 20);
    st = vxfs_mkfs(&vol, dev, MEM, CACHE, 0, (const char *const *)argv + 4, (uint32_t)(argc - 4), 0755, 0, 0,
                   ns_of(now));
    if (st == VX_OK) st = make_users(name, ns_of(now));
    if (st == VX_OK) st = vxfs_commit(&vol);
    if (st != VX_OK) die("cannot make a volume on %s", image, st);
    vxfs_unmount(&vol);
    close(fd);
    return 0;
  }
  if (!strcmp(cmd, "put") && argc == 5) {
    mount();
    vxfs_branch *br;
    vxfs_file root;
    if ((st = vxfs_branch_open(&vol, argv[3], &br)) != VX_OK) die("no branch %s", argv[3], st);
    if ((st = vxfs_root(&vol, &br->t, &root)) != VX_OK) die("%s has no root", argv[3], st);
    owner = root.d.uid, group = root.d.gid;
    put_dir(&br->t, &root, argv[4]);
    finish();
    fprintf(stderr, "vxfs: %llu bytes into %s\n", (unsigned long long)copied, argv[3]);
    return 0;
  }
  if ((!strcmp(cmd, "ls") && (argc == 4 || argc == 5)) || (!strcmp(cmd, "cat") && argc == 5)) {
    mount();
    vxfs_tree t = label_tree(argv[3]);
    vxfs_file f;
    const char *path = argc == 5 ? argv[4] : "/";
    if ((st = vxfs_walk_path(&vol, &t, path, &f)) != VX_OK) die("no %s", path, st);
    if (!strcmp(cmd, "ls")) {
      if ((st = vxfs_readdir(&vol, &t, &f, print_entry, nullptr)) != VX_OK) die("cannot list %s", path, st);
    } else {
      static uint8_t buf[1 << 20];
      uint64_t got = 0;
      for (uint64_t off = 0; (st = vxfs_read(&vol, &t, &f, off, buf, sizeof buf, &got)) == VX_OK && got;
           off += got)
        fwrite(buf, 1, got, stdout);
      if (st != VX_OK) die("cannot read %s", path, st);
    }
    vxfs_unmount(&vol);
    return 0;
  }
  if (!strcmp(cmd, "verify") && argc == 5) {
    mount();
    vxfs_tree t = label_tree(argv[3]);
    vxfs_file root;
    if ((st = vxfs_root(&vol, &t, &root)) != VX_OK) die("%s has no root", argv[3], st);
    bool ok = verify_dir(&t, &root, argv[4]);
    vxfs_unmount(&vol);
    return ok ? 0 : 1;
  }
  if (!strcmp(cmd, "check") && argc == 3) {
    mount();
    vxfs_check c;
    st = vxfs_check_volume(&vol, &c);
    printf("%u snapshots, %u labels, %u deadlists; %llu blocks in use: %llu in trees, %llu else\n",
           c.snapshots, c.labels, c.dlists, (unsigned long long)c.used, (unsigned long long)c.trees,
           (unsigned long long)c.other);
    if (st != VX_OK)
      printf("NOT CLEAN: leaked %llu, unallocated %llu, shared %llu, damaged %llu, bad snapshots %llu, bad "
             "deadlists %llu\n",
             (unsigned long long)c.leaked, (unsigned long long)c.unallocated, (unsigned long long)c.shared,
             (unsigned long long)c.damaged, (unsigned long long)c.bad_snaps, (unsigned long long)c.bad_lists);
    vxfs_unmount(&vol);
    return st == VX_OK ? 0 : 1;
  }
  if (!strcmp(cmd, "info") && argc == 3) {
    mount();
    info();
    vxfs_unmount(&vol);
    return 0;
  }
  if ((!strcmp(cmd, "snap") || !strcmp(cmd, "fork") || !strcmp(cmd, "rollback")) && argc == 5) {
    mount();
    if (!strcmp(cmd, "rollback"))
      st = vxfs_rollback(&vol, argv[3], argv[4]);
    else
      st = vxfs_label(&vol, argv[3], argv[4], !strcmp(cmd, "fork") ? VXFS_LMUT : 0);
    if (st != VX_OK) die("%s failed", cmd, st);
    finish();
    return 0;
  }
  if (!strcmp(cmd, "del") && argc == 4) {
    mount();
    if ((st = vxfs_unlabel(&vol, argv[3])) != VX_OK) die("no label %s to delete", argv[3], st);
    finish();
    return 0;
  }
  usage();
}
