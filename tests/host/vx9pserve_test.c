// vx9pserve_test.c: vx9pserve's file server (host/vx9pserve/fs.c) on a
// temporary directory, through vx-9p's client. Files read, written,
// created and removed; and nothing outside the directory reached: symbolic
// links, in the directory or swapped in under a path already walked, are
// neither followed nor listed.

#define _GNU_SOURCE // before any system header: fs.c needs openat and O_PATH
#include <stdio.h>
#include <stdlib.h>

#include "check.h"
#include "../../host/vx9pserve/fs.c"
#include "../../lib/vx-9p/client.c"

static hostfs h;
static p9_server server;
static char dir[64];

static size_t loopback(void *ctx, const uint8_t *req, size_t len, uint8_t *resp, size_t cap) {
  return p9_serve(ctx, req, len, resp, cap);
}

static void put_file(const char *rel, const char *text) {
  char path[256];
  snprintf(path, sizeof path, "%s/%s", dir, rel);
  FILE *f = fopen(path, "w");
  if (f) fputs(text, f), fclose(f);
}

static bool host_has(const char *rel, const char *text) {
  char path[256], got[256] = {};
  snprintf(path, sizeof path, "%s/%s", dir, rel);
  FILE *f = fopen(path, "r");
  if (!f) return false;
  size_t n = fread(got, 1, sizeof got - 1, f);
  fclose(f);
  return n == strlen(text) && memcmp(got, text, n) == 0;
}

int main(void) {
  snprintf(dir, sizeof dir, "/tmp/vx9pserve-test-XXXXXX");
  if (!mkdtemp(dir)) return 1;
  char path[256];
  put_file("hello.txt", "hello from the host\n");
  snprintf(path, sizeof path, "%s/sub", dir);
  mkdir(path, 0755);
  put_file("sub/inner.txt", "inner");
  snprintf(path, sizeof path, "%s/escape", dir);
  CHECK(symlink("/etc", path) == 0);
  snprintf(path, sizeof path, "%s/sub/up", dir);
  CHECK(symlink("../..", path) == 0);
  snprintf(path, sizeof path, "%s/passwd", dir);
  CHECK(symlink("/etc/passwd", path) == 0);

  CHECK(hostfs_init(&h, &server, dir, 8192));
  static uint8_t tbuf[8192], rbuf[8192];
  p9_client c = {.rpc = loopback, .ctx = &server, .tbuf = tbuf, .rbuf = rbuf, .bufsize = sizeof tbuf};
  uint32_t root = 0, f = 0;
  CHECK(p9c_version(&c, 8192, 0) == VX_OK && p9c_attach(&c, VX_STR(""), &root) == VX_OK);

  // Reading.
  char buf[256];
  CHECK(p9c_walk(&c, root, VX_STR("hello.txt"), &f) == VX_OK && p9c_open(&c, f, P9_OREAD) == VX_OK);
  CHECK(p9c_read(&c, f, 0, buf, sizeof buf) == 20 && memcmp(buf, "hello from the host\n", 20) == 0);
  p9_stat st;
  CHECK(p9c_stat(&c, f, &st) == VX_OK && st.length == 20 && st.name.len == 9 && !(st.qid.type & P9_QTDIR));
  p9c_clunk(&c, f);
  CHECK(p9c_walk(&c, root, VX_STR("sub/inner.txt"), &f) == VX_OK && p9c_open(&c, f, P9_OREAD) == VX_OK);
  CHECK(p9c_read(&c, f, 0, buf, sizeof buf) == 5);
  p9c_clunk(&c, f);

  // Symbolic links: not walked to, wherever they point.
  CHECK(p9c_walk(&c, root, VX_STR("escape"), &f) == VX_ERR_NOT_FOUND);
  CHECK(p9c_walk(&c, root, VX_STR("escape/passwd"), &f) == VX_ERR_NOT_FOUND);
  CHECK(p9c_walk(&c, root, VX_STR("passwd"), &f) == VX_ERR_NOT_FOUND);
  CHECK(p9c_walk(&c, root, VX_STR("sub/up/etc"), &f) == VX_ERR_NOT_FOUND);
  CHECK(p9c_walk(&c, root, VX_STR("../../etc"), &f) == VX_ERR_NOT_FOUND); // .. stops at the root

  // Listing: the file and the directory; no links.
  CHECK(p9c_walk(&c, root, VX_STR(""), &f) == VX_OK && p9c_open(&c, f, P9_OREAD) == VX_OK);
  uint8_t listing[4096];
  int64_t n = p9c_read(&c, f, 0, listing, sizeof listing);
  int entries = 0, links = 0;
  p9_stat e;
  for (size_t off = 0; n > 0 && p9_dir_next(listing, (size_t)n, &off, &e);) {
    entries++;
    links += (e.name.len == 6 && memcmp(e.name.ptr, "escape", 6) == 0) ||
             (e.name.len == 6 && memcmp(e.name.ptr, "passwd", 6) == 0);
  }
  CHECK(entries == 2 && links == 0);
  p9c_clunk(&c, f);

  // A directory walked to, then swapped for a link out: the next open is refused.
  uint32_t sub = 0;
  CHECK(p9c_walk(&c, root, VX_STR("sub/inner.txt"), &sub) == VX_OK);
  char from[256], to[256];
  snprintf(from, sizeof from, "%s/sub", dir);
  snprintf(to, sizeof to, "%s/sub-moved", dir);
  CHECK(rename(from, to) == 0 && symlink("/etc", from) == 0);
  CHECK(p9c_open(&c, sub, P9_OREAD) == VX_ERR_NOT_FOUND);
  p9c_clunk(&c, sub);
  unlink(from);
  CHECK(rename(to, from) == 0);

  // Writing, creating and removing.
  CHECK(p9c_walk(&c, root, VX_STR(""), &f) == VX_OK);
  CHECK(p9c_create(&c, f, VX_STR("out.txt"), 0644, P9_OWRITE) == VX_OK);
  CHECK(p9c_write(&c, f, 0, "hi\n", 3) == 3);
  p9c_clunk(&c, f);
  CHECK(host_has("out.txt", "hi\n"));
  CHECK(p9c_walk(&c, root, VX_STR("out.txt"), &f) == VX_OK &&
        p9c_open(&c, f, P9_OWRITE | P9_OTRUNC) == VX_OK);
  CHECK(p9c_write(&c, f, 0, "again", 5) == 5);
  p9c_clunk(&c, f);
  CHECK(host_has("out.txt", "again"));
  CHECK(p9c_walk(&c, root, VX_STR(""), &f) == VX_OK);
  CHECK(p9c_create(&c, f, VX_STR("out.txt"), 0644, P9_OWRITE) == VX_ERR_EXISTS);
  p9c_clunk(&c, f);
  CHECK(p9c_walk(&c, root, VX_STR(""), &f) == VX_OK);
  CHECK(p9c_create(&c, f, VX_STR("newdir"), P9_DMDIR | 0755, P9_OREAD) == VX_OK);
  p9c_clunk(&c, f);
  CHECK(p9c_walk(&c, root, VX_STR("newdir"), &f) == VX_OK && p9c_remove(&c, f) == VX_OK);
  CHECK(p9c_walk(&c, root, VX_STR("out.txt"), &f) == VX_OK && p9c_remove(&c, f) == VX_OK);
  CHECK(!host_has("out.txt", "again"));
  CHECK(p9c_walk(&c, root, VX_STR(""), &f) == VX_OK && p9c_remove(&c, f) == VX_ERR_ACCESS); // not the root

  // Clean up: exactly what was made.
  static const char *const MADE[] = {"hello.txt", "sub/inner.txt", "sub/up", "escape", "passwd"};
  for (size_t k = 0; k < sizeof MADE / sizeof MADE[0]; k++) {
    snprintf(path, sizeof path, "%s/%s", dir, MADE[k]);
    unlink(path);
  }
  snprintf(path, sizeof path, "%s/sub", dir);
  rmdir(path);
  CHECK(rmdir(dir) == 0); // nothing else was left behind
  return check_result();
}
