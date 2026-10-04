// vxstore: makes and reads content stores (docs/06 §4) on the build machine,
// with lib/vx-store: what ./build release uses (M5 step 9a).
//
//   vxstore put STORE DIR [TAR]     DIR's tree (and TAR's entries, at its root)
//                                   into STORE; prints the tree's hash
//   vxstore tar STORE TREE OUT      every object TREE reaches, as a ustar
//                                   archive of b2/xx/<hex> paths (store.tar)
//   vxstore check STORE TREE        every object TREE reaches, checked; exit 0
//                                   if all are there and sound
//   vxstore ls STORE TREE [PATH]    a directory's entries
//   vxstore cat STORE TREE PATH     a file's bytes, to stdout
//
// Modes are not the build machine's: a file is 0444, or 0555 if any execute
// bit is set; a directory 0555; a link 0777. Times and owners are not kept.
// So a tree's hash depends only on names, contents and links, and two
// builds of one commit give one hash (04 §7).

#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../../lib/vx-store/store.c"
#include "../../lib/vx-tar/tar.c"

[[noreturn]] static void die(const char *what, const char *arg) {
  fprintf(stderr, "vxstore: %s%s%s\n", what, arg ? ": " : "", arg ? arg : "");
  exit(1);
}

static void *xalloc(size_t n) {
  void *p = calloc(1, n ? n : 1);
  if (!p) die("out of memory", nullptr);
  return p;
}

// --- Reading files whole ---

static uint8_t *slurp(const char *path, size_t *len) {
  int fd = open(path, O_RDONLY);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) != 0) return nullptr;
  uint8_t *buf = xalloc((size_t)st.st_size);
  size_t got = 0;
  while (got < (size_t)st.st_size) {
    ssize_t n = read(fd, buf + got, (size_t)st.st_size - got);
    if (n <= 0) die("cannot read", path);
    got += (size_t)n;
  }
  close(fd);
  *len = got;
  return buf;
}

// --- The store ---

static const char *store;

static char *object_path(const vx_hash *h) {
  char rel[71];
  vx_store_path(h, rel);
  char *p = xalloc(strlen(store) + 72);
  sprintf(p, "%s/%s", store, rel);
  return p;
}

// An object written, if the store lacks it: to a temporary name, then renamed.
static void put_object(const vx_hash *h, const uint8_t *data, size_t len) {
  char *path = object_path(h);
  struct stat st;
  if (stat(path, &st) == 0) {
    free(path);
    return;
  }
  char dir[4096];
  snprintf(dir, sizeof dir, "%s/b2", store);
  mkdir(store, 0755), mkdir(dir, 0755);
  snprintf(dir, sizeof dir, "%.*s", (int)(strrchr(path, '/') - path), path);
  mkdir(dir, 0755);
  char tmp[4200];
  snprintf(tmp, sizeof tmp, "%s.tmp", path);
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0444);
  if (fd < 0 || (len && write(fd, data, len) != (ssize_t)len) || close(fd) != 0 || rename(tmp, path) != 0)
    die("cannot write", path);
  free(path);
}

static uint8_t *get_object(const vx_hash *h, size_t *len) {
  char *path = object_path(h);
  uint8_t *data = slurp(path, len);
  if (!data) {
    char hex[VX_STORE_HEX + 1];
    vx_store_hex(h, hex);
    die("the store lacks", hex);
  }
  free(path);
  return data;
}

// --- Trees in memory ---

typedef struct node {
  char *name;
  uint32_t mode;
  struct node **kids;
  size_t nkids, cap;
  const uint8_t *data; // a file's bytes (from a tar), or nullptr: read from path
  uint64_t size;
  char *path, *link;
} node;

static node *child(node *dir, const char *name, size_t len, bool make) {
  for (size_t i = 0; i < dir->nkids; i++)
    if (strlen(dir->kids[i]->name) == len && memcmp(dir->kids[i]->name, name, len) == 0) return dir->kids[i];
  if (!make) return nullptr;
  if (dir->nkids == dir->cap) {
    dir->cap = dir->cap ? 2 * dir->cap : 8;
    node **k = xalloc(dir->cap * sizeof *k);
    if (dir->nkids) memcpy(k, dir->kids, dir->nkids * sizeof *k);
    free(dir->kids);
    dir->kids = k;
  }
  node *n = xalloc(sizeof *n);
  n->name = strndup(name, len);
  n->mode = 040555;
  dir->kids[dir->nkids++] = n;
  return n;
}

static uint32_t file_mode(uint32_t host) { return host & 0111 ? 0100555 : 0100444; }

// NOLINTNEXTLINE(misc-no-recursion): as deep as the directory tree
static void add_dir(node *dir, const char *path) {
  DIR *d = opendir(path);
  if (!d) die("cannot read the directory", path);
  struct dirent *de;
  while ((de = readdir(d))) {
    if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;
    char *p = xalloc(strlen(path) + strlen(de->d_name) + 2);
    sprintf(p, "%s/%s", path, de->d_name);
    struct stat st;
    if (lstat(p, &st) != 0) die("cannot stat", p);
    node *n = child(dir, de->d_name, strlen(de->d_name), true);
    if (S_ISDIR(st.st_mode)) {
      add_dir(n, p);
      free(p);
    } else if (S_ISLNK(st.st_mode)) {
      char target[4096];
      ssize_t l = readlink(p, target, sizeof target - 1);
      if (l <= 0) die("cannot read the link", p);
      n->mode = 0120777, n->link = strndup(target, (size_t)l);
      free(p);
    } else if (S_ISREG(st.st_mode)) {
      n->mode = file_mode(st.st_mode), n->path = p, n->size = (uint64_t)st.st_size;
    } else {
      die("neither a file, a directory nor a link", p);
    }
  }
  closedir(d);
}

static void add_tar(node *root, const uint8_t *image, size_t size) {
  vx_tar t = vx_tar_open(image, size);
  vx_tar_entry e;
  vx_status st;
  while ((st = vx_tar_next(&t, &e)) == VX_OK) {
    node *dir = root;
    vx_str p = e.path;
    while (p.len) {
      size_t n = 0;
      while (n < p.len && p.ptr[n] != '/') n++;
      bool last = n == p.len;
      node *k = child(dir, p.ptr, n, true);
      if (last && !e.dir) k->mode = file_mode(e.mode), k->data = e.data, k->size = e.size;
      dir = k;
      p = last ? (vx_str){p.ptr + n, 0} : (vx_str){p.ptr + n + 1, p.len - n - 1};
    }
  }
  if (t.failed) die("a malformed tar", nullptr);
}

static int by_name(const void *a, const void *b) {
  const node *x = *(node *const *)a, *y = *(node *const *)b;
  return strcmp(x->name, y->name); // bytes, as unsigned: strcmp compares as unsigned char
}

// A file's blocks and index, written; its hash.
static void hash_file(node *n, vx_hash *out) {
  size_t len = 0;
  uint8_t *owned = nullptr;
  const uint8_t *data = n->data;
  if (!data) {
    owned = slurp(n->path, &len);
    if (!owned) die("cannot read", n->path);
    data = owned, n->size = len;
  }
  uint64_t count = vx_store_blocks(n->size);
  size_t ilen = VX_STORE_INDEX_HEAD + count * VX_STORE_HASH;
  uint8_t *idx = xalloc(ilen);
  vx_store_index_head(n->size, idx);
  for (uint64_t i = 0; i < count; i++) {
    uint64_t at = i * VX_STORE_BLOCK, bl = n->size - at < VX_STORE_BLOCK ? n->size - at : VX_STORE_BLOCK;
    vx_hash h;
    vx_store_leaf(data + at, n->size ? bl : 0, &h);
    put_object(&h, data + at, n->size ? bl : 0);
    memcpy(idx + VX_STORE_INDEX_HEAD + i * VX_STORE_HASH, h.b, VX_STORE_HASH);
  }
  vx_hash root;
  vx_store_root(idx + VX_STORE_INDEX_HEAD, count, &root);
  vx_store_file_hash(n->size, &root, out);
  put_object(out, idx, ilen);
  free(idx);
  free(owned);
}

// A directory's entries' objects, then its own; its hash, and the bytes under it.
// NOLINTNEXTLINE(misc-no-recursion): as deep as the directory tree
static uint64_t hash_dir(node *dir, vx_hash *out) {
  qsort(dir->kids, dir->nkids, sizeof *dir->kids, by_name);
  size_t cap = 256 + dir->nkids * 512;
  char *text = xalloc(cap);
  vx_ndb_writer w = {.buf = text, .cap = cap};
  uint64_t bytes = 0;
  for (size_t i = 0; i < dir->nkids; i++) {
    node *k = dir->kids[i];
    vx_store_entry e = {.name = {k->name, strlen(k->name)}, .mode = k->mode};
    if ((k->mode & 0170000) == 040000) {
      bytes += hash_dir(k, &e.hash);
    } else if ((k->mode & 0170000) == 0120000) {
      e.link = (vx_str){k->link, strlen(k->link)};
    } else {
      hash_file(k, &e.hash);
      e.size = k->size, bytes += k->size;
    }
    if (!vx_store_dir_put(&w, &e)) die("a name ndb cannot hold, or too many entries", k->name);
  }
  vx_store_text_hash((const uint8_t *)text, w.len, out);
  put_object(out, (const uint8_t *)text, w.len);
  free(text);
  return bytes;
}

// --- Walking a stored tree ---

typedef void (*visit_fn)(const vx_hash *h, bool block, void *ctx);

// NOLINTNEXTLINE(misc-no-recursion): as deep as the tree
static void walk_tree(const vx_hash *dir, visit_fn fn, void *ctx) {
  size_t len;
  uint8_t *text = get_object(dir, &len);
  if (vx_store_dir_check(dir, text, len) != VX_OK) die("a directory does not match its name", nullptr);
  fn(dir, false, ctx);
  static char scratch[1 << 16];
  vx_ndb_reader r = {.src = {(const char *)text, len}, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    r.scratch_used = 0;
    vx_store_entry e;
    if (vx_store_dir_entry(&rec, &e) != VX_OK) die("a malformed directory entry", nullptr);
    if (vx_store_is_link(&e)) continue;
    if (vx_store_is_dir(&e)) {
      walk_tree(&e.hash, fn, ctx);
      continue;
    }
    size_t ilen;
    uint8_t *idx = get_object(&e.hash, &ilen);
    uint64_t size, n;
    const uint8_t *hashes;
    if (vx_store_index_check(&e.hash, idx, ilen, &size, &hashes, &n) != VX_OK || size != e.size)
      die("a file's index does not match its name", nullptr);
    fn(&e.hash, false, ctx);
    for (uint64_t i = 0; i < n; i++) {
      vx_hash b;
      memcpy(b.b, hashes + i * VX_STORE_HASH, VX_STORE_HASH);
      size_t blen;
      uint8_t *data = get_object(&b, &blen);
      if (vx_store_block_check(hashes, n, size, i, data, blen) != VX_OK)
        die("a block does not match its hash", nullptr);
      free(data);
      fn(&b, true, ctx);
    }
    free(idx);
  }
  free(text);
}

typedef struct names {
  char **paths;
  size_t n, cap;
} names;

static void collect(const vx_hash *h, bool block, void *ctx) {
  (void)block;
  names *s = ctx;
  char rel[71];
  vx_store_path(h, rel);
  if (s->n == s->cap) {
    s->cap = s->cap ? 2 * s->cap : 1024;
    char **p = xalloc(s->cap * sizeof *p);
    if (s->n) memcpy(p, s->paths, s->n * sizeof *p);
    free(s->paths);
    s->paths = p;
  }
  s->paths[s->n++] = strdup(rel);
}

static int by_str(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static void none(const vx_hash *h, bool block, void *ctx) { (void)h, (void)block, (void)ctx; }

// The entry at path under a tree.
static vx_store_entry lookup(const vx_hash *tree, const char *path, uint8_t **owner) {
  vx_store_entry e = {.mode = 040555, .hash = *tree};
  *owner = nullptr;
  static char scratch[1 << 16];
  while (*path) {
    while (*path == '/') path++;
    size_t n = strcspn(path, "/");
    if (!n) break;
    if (!vx_store_is_dir(&e)) die("not a directory on the way", path);
    size_t len;
    free(*owner);
    *owner = get_object(&e.hash, &len);
    if (vx_store_dir_find(*owner, len, (vx_str){path, n}, scratch, sizeof scratch, &e) != VX_OK)
      die("no such entry", path);
    path += n;
  }
  return e;
}

static vx_hash tree_arg(const char *s) {
  vx_hash h;
  if (!vx_store_parse((vx_str){s, strlen(s)}, &h)) die("not a b2: hash", s);
  return h;
}

int main(int argc, char **argv) {
  if (argc < 4) die("usage: vxstore put|tar|check|ls|cat STORE ...", nullptr);
  store = argv[2];
  if (strcmp(argv[1], "put") == 0 && (argc == 4 || argc == 5)) {
    node root = {.name = "", .mode = 040555};
    add_dir(&root, argv[3]);
    size_t tlen = 0;
    uint8_t *tar = argc == 5 ? slurp(argv[4], &tlen) : nullptr;
    if (argc == 5 && !tar) die("cannot read", argv[4]);
    if (tar) add_tar(&root, tar, tlen);
    vx_hash h;
    uint64_t bytes = hash_dir(&root, &h);
    char hex[VX_STORE_HEX + 1];
    vx_store_hex(&h, hex);
    printf("%s %llu\n", hex, (unsigned long long)bytes);
    return 0;
  }
  vx_hash tree = tree_arg(argv[3]);
  if (strcmp(argv[1], "check") == 0 && argc == 4) {
    walk_tree(&tree, none, nullptr);
    return 0;
  }
  if (strcmp(argv[1], "tar") == 0 && argc == 5) {
    names s = {};
    walk_tree(&tree, collect, &s);
    qsort(s.paths, s.n, sizeof *s.paths, by_str);
    size_t total = 1024;
    for (size_t i = 0; i < s.n; i++) {
      char p[4200];
      snprintf(p, sizeof p, "%s/%s", store, s.paths[i]);
      struct stat st;
      if (stat(p, &st) != 0) die("cannot stat", p);
      total += 2 * VX_TAR_BLOCK + (size_t)st.st_size;
    }
    vx_tar_writer w = {.buf = xalloc(total), .cap = total};
    for (size_t i = 0; i < s.n; i++) {
      if (i && strcmp(s.paths[i], s.paths[i - 1]) == 0) continue; // shared by two files
      char p[4200];
      snprintf(p, sizeof p, "%s/%s", store, s.paths[i]);
      size_t len;
      uint8_t *data = slurp(p, &len);
      vx_tar_add(&w, (vx_str){s.paths[i], strlen(s.paths[i])}, false, 0444, data, len);
      free(data);
    }
    if (w.failed) die("cannot write the archive", nullptr);
    int fd = open(argv[4], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || write(fd, w.buf, w.len + 1024) != (ssize_t)(w.len + 1024) || close(fd) != 0)
      die("cannot write", argv[4]); // two zero blocks end it
    return 0;
  }
  if ((strcmp(argv[1], "ls") == 0 && (argc == 4 || argc == 5)) ||
      (strcmp(argv[1], "cat") == 0 && argc == 5)) {
    uint8_t *owner;
    vx_store_entry e = lookup(&tree, argc == 5 ? argv[4] : "", &owner);
    size_t len;
    uint8_t *obj = get_object(&e.hash, &len);
    if (argv[1][0] == 'l') {
      if (!vx_store_is_dir(&e)) die("not a directory", argv[4]);
      fwrite(obj, 1, len, stdout);
      return 0;
    }
    uint64_t size, n;
    const uint8_t *hashes;
    if (vx_store_is_dir(&e) || vx_store_index_check(&e.hash, obj, len, &size, &hashes, &n) != VX_OK)
      die("not a sound file", argv[4]);
    for (uint64_t i = 0; i < n; i++) {
      vx_hash b;
      memcpy(b.b, hashes + i * VX_STORE_HASH, VX_STORE_HASH);
      size_t blen;
      uint8_t *data = get_object(&b, &blen);
      if (vx_store_block_check(hashes, n, size, i, data, blen) != VX_OK)
        die("a block does not match its hash", nullptr);
      fwrite(data, 1, blen, stdout);
      free(data);
    }
    return 0;
  }
  die("usage: vxstore put|tar|check|ls|cat STORE ...", nullptr);
}
