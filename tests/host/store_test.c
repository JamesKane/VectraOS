// store_test.c: lib/vx-store (docs/06 §4). Monocypher as linked, against
// RFC 7693's BLAKE2b-512("abc") and RFC 8032's first Ed25519 vector; the
// hash tree's shape (RFC 6962's split) for one to five leaves; a file's
// index checked whole and each block against it, and refused when a hash,
// a length or the size is wrong; directories written canonically and read
// back, names with spaces and quotes included, and records that are not
// entries refused, a key store(6) does not name among them; a release
// record's keys; and one small tree's hash, fixed, so the format cannot
// drift unnoticed.
// host-links: monocypher

static const char FIXED_TREE[] = "b2:504f0b421e49fbf7de23620bb329b15884cd839c21bf77c70604f5adbce868b0";

#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-store/store.c"
#include "monocypher-ed25519.h"

static int nibble(char c) { return c <= '9' ? c - '0' : c - 'a' + 10; }

static void unhex(const char *s, uint8_t *out) {
  for (size_t i = 0; s[2 * i]; i++) out[i] = (uint8_t)(nibble(s[2 * i]) << 4 | nibble(s[2 * i + 1]));
}

static void check_monocypher(void) {
  uint8_t h[64], want[64];
  crypto_blake2b(h, 64, (const uint8_t *)"abc", 3);
  unhex("ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
        "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923",
        want);
  CHECK(memcmp(h, want, 64) == 0);
  uint8_t pk[32], sig[64];
  unhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", pk);
  unhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25b"
        "f5f0595bbe24655141438e7a100b",
        sig);
  CHECK(crypto_ed25519_check(sig, pk, (const uint8_t *)"", 0) == 0);
  sig[0] ^= 1;
  CHECK(crypto_ed25519_check(sig, pk, (const uint8_t *)"", 0) != 0);
}

static void check_tree_shape(void) {
  uint8_t leaves[5 * 32];
  vx_hash l[5], ab, cd, abcd, out;
  for (int i = 0; i < 5; i++) {
    uint8_t b = (uint8_t)i;
    vx_store_leaf(&b, 1, &l[i]);
    memcpy(leaves + (size_t)32 * i, l[i].b, 32);
  }
  // The leaf prefix: BLAKE2b(0x00 || 0x00) for the one-byte block {0}.
  uint8_t raw[2] = {0, 0}, want[32];
  crypto_blake2b(want, 32, raw, 2);
  CHECK(memcmp(l[0].b, want, 32) == 0);
  vx_store_root(leaves, 1, &out);
  CHECK(vx_hash_eq(&out, &l[0]));
  vx_store_node(&l[0], &l[1], &ab);
  vx_store_root(leaves, 2, &out);
  CHECK(vx_hash_eq(&out, &ab));
  vx_hash abc;
  vx_store_node(&ab, &l[2], &abc); // 3 = 2 + 1
  vx_store_root(leaves, 3, &out);
  CHECK(vx_hash_eq(&out, &abc));
  vx_store_node(&l[2], &l[3], &cd);
  vx_store_node(&ab, &cd, &abcd);
  vx_hash abcde;
  vx_store_node(&abcd, &l[4], &abcde); // 5 = 4 + 1
  vx_store_root(leaves, 5, &out);
  CHECK(vx_hash_eq(&out, &abcde));
  vx_store_node(&l[1], &l[0], &out); // order matters
  CHECK(!vx_hash_eq(&out, &ab));
}

// An index for data, as host/vxstore makes one.
static uint8_t *make_index(const uint8_t *data, uint64_t size, size_t *len, vx_hash *name) {
  uint64_t n = vx_store_blocks(size);
  *len = VX_STORE_INDEX_HEAD + n * 32;
  uint8_t *idx = malloc(*len);
  vx_store_index_head(size, idx);
  for (uint64_t i = 0; i < n; i++) {
    uint64_t at = i * VX_STORE_BLOCK, bl = size - at < VX_STORE_BLOCK ? size - at : VX_STORE_BLOCK;
    vx_hash h;
    vx_store_leaf(data + at, size ? bl : 0, &h);
    memcpy(idx + VX_STORE_INDEX_HEAD + i * 32, h.b, 32);
  }
  vx_hash root;
  vx_store_root(idx + VX_STORE_INDEX_HEAD, n, &root);
  vx_store_file_hash(size, &root, name);
  return idx;
}

static void check_files(void) {
  static uint8_t data[200'000];
  for (size_t i = 0; i < sizeof data; i++) data[i] = (uint8_t)(i * 31 + i / 997);
  size_t len;
  vx_hash name;
  uint8_t *idx = make_index(data, sizeof data, &len, &name);
  uint64_t size, n;
  const uint8_t *hashes;
  CHECK(vx_store_index_check(&name, idx, len, &size, &hashes, &n) == VX_OK && size == sizeof data && n == 4);
  for (uint64_t i = 0; i < n; i++) {
    uint64_t at = i * VX_STORE_BLOCK, bl = size - at < VX_STORE_BLOCK ? size - at : VX_STORE_BLOCK;
    CHECK(vx_store_block_check(hashes, n, size, i, data + at, bl) == VX_OK);
  }
  data[70'000] ^= 1; // block 1 changed
  CHECK(vx_store_block_check(hashes, n, size, 1, data + VX_STORE_BLOCK, VX_STORE_BLOCK) == VX_ERR_IO);
  CHECK(vx_store_block_check(hashes, n, size, 3, data + (size_t)3 * VX_STORE_BLOCK, 100) ==
        VX_ERR_IO); // short
  CHECK(vx_store_block_check(hashes, n, size, 4, data, 1) == VX_ERR_RANGE);
  idx[VX_STORE_INDEX_HEAD + 40] ^= 1; // a block hash changed: the index no longer hashes to its name
  CHECK(vx_store_index_check(&name, idx, len, &size, &hashes, &n) == VX_ERR_IO);
  idx[VX_STORE_INDEX_HEAD + 40] ^= 1;
  idx[4] ^= 1; // the size changed by one, the block count not: the name binds the size
  CHECK(vx_store_index_check(&name, idx, len, &size, &hashes, &n) == VX_ERR_IO);
  idx[4] ^= 1;
  idx[6] ^= 1; // by 65536: the count no longer matches the hashes
  CHECK(vx_store_index_check(&name, idx, len, &size, &hashes, &n) == VX_ERR_INVALID);
  idx[6] ^= 1;
  CHECK(vx_store_index_check(&name, idx, len - 1, &size, &hashes, &n) == VX_ERR_INVALID);
  CHECK(vx_store_index_check(&name, (const uint8_t *)"vxs", 3, &size, &hashes, &n) == VX_ERR_INVALID);
  free(idx);
  // An empty file: one empty block.
  idx = make_index(data, 0, &len, &name);
  CHECK(vx_store_index_check(&name, idx, len, &size, &hashes, &n) == VX_OK && size == 0 && n == 1);
  CHECK(vx_store_block_check(hashes, n, size, 0, data, 0) == VX_OK);
  free(idx);
}

static void check_dirs(void) {
  vx_hash h;
  memset(h.b, 0xab, 32);
  vx_store_entry in[] = {
      {.name = VX_STR("bin"), .mode = 040555, .hash = h},
      {.name = VX_STR("a file \"quoted\""), .mode = 0100444, .size = 12, .hash = h},
      {.name = VX_STR("sh"), .mode = 0120777, .link = VX_STR("/bin/rc")},
  };
  static char text[4096];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  for (size_t i = 0; i < 3; i++) CHECK(vx_store_dir_put(&w, &in[i]));
  CHECK(!w.failed);
  const char *want =
      "name=bin mode=040555 hash=b2:abababababababababababababababababababababababababababababababab\n"
      "name=\"a file \"\"quoted\"\"\" mode=0100444 size=12 "
      "hash=b2:abababababababababababababababababababababababababababababababab\n"
      "name=sh mode=0120777 link=/bin/rc\n";
  CHECK(w.len == strlen(want) && memcmp(text, want, w.len) == 0);
  static char scratch[4096];
  vx_store_entry e;
  CHECK(vx_store_dir_find((const uint8_t *)text, w.len, VX_STR("a file \"quoted\""), scratch, sizeof scratch,
                          &e) == VX_OK &&
        e.size == 12 && e.mode == 0100444 && vx_hash_eq(&e.hash, &h));
  CHECK(vx_store_dir_find((const uint8_t *)text, w.len, VX_STR("sh"), scratch, sizeof scratch, &e) == VX_OK &&
        vx_store_is_link(&e) && e.link.len == 7 && memcmp(e.link.ptr, "/bin/rc", 7) == 0);
  CHECK(vx_store_dir_find((const uint8_t *)text, w.len, VX_STR("bin"), scratch, sizeof scratch, &e) ==
            VX_OK &&
        vx_store_is_dir(&e));
  CHECK(vx_store_dir_find((const uint8_t *)text, w.len, VX_STR("nothing"), scratch, sizeof scratch, &e) ==
        VX_ERR_NOT_FOUND);
  vx_hash name;
  vx_store_text_hash((const uint8_t *)text, w.len, &name);
  CHECK(vx_store_dir_check(&name, (const uint8_t *)text, w.len) == VX_OK);
  text[0] ^= 1;
  CHECK(vx_store_dir_check(&name, (const uint8_t *)text, w.len) == VX_ERR_IO);

  // Records that are not entries.
  static const char *const bad[] = {
      "name=x mode=0100444 hash=b2:ab\n", // a short hash
      "name=x mode=100444 size=1 "
      "hash=b2:abababababababababababababababababababababababababababababababab\n", // no 0
      "name=x mode=0100448 size=1 "
      "hash=b2:abababababababababababababababababababababababababababababababab\n", // 8
      "name=a/b mode=0100444 size=1 "
      "hash=b2:abababababababababababababababababababababababababababababababab\n",
      "name=.. mode=040555 "
      "hash=b2:abababababababababababababababababababababababababababababababab\n",
      "name=x mode=0100444 "
      "hash=b2:abababababababababababababababababababababababababababababababab\n", // no size
      "name=x mode=0120777\n",                                                      // no target
      "name=x mode=060644 "
      "hash=b2:abababababababababababababababababababababababababababababababab\n", // a device
      "name=x mode=0100444 size=1 "
      "hash=b2:ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB\n",
      "name=x mode=0100444 size=1 owner=adm "
      "hash=b2:abababababababababababababababababababababababababababababababab\n", // a key not in store(6)
  };
  for (size_t i = 0; i < sizeof bad / sizeof *bad; i++)
    CHECK(vx_store_dir_find((const uint8_t *)bad[i], strlen(bad[i]), VX_STR("y"), scratch, sizeof scratch,
                            &e) == VX_ERR_INVALID);

  // A release record's keys (release(6)).
  static char rs[256];
  vx_ndb_reader r = {
      .src = VX_STR("release=3 name=x unsigned set=base"), .scratch = rs, .scratch_cap = sizeof rs};
  vx_ndb_record rec;
  CHECK(vx_ndb_next(&r, &rec) == VX_NDB_RECORD && vx_release_known(&rec));
  r = (vx_ndb_reader){.src = VX_STR("release=3 expires=9"), .scratch = rs, .scratch_cap = sizeof rs};
  CHECK(vx_ndb_next(&r, &rec) == VX_NDB_RECORD && !vx_release_known(&rec));
  // The first record as ./build release writes it since level 1 (6e4e, 6e4f).
  r = (vx_ndb_reader){
      .src = VX_STR("release=439 name=dev-439 channel=dev commit=c vx-abi=1 behaviour=fd1f unsigned"),
      .scratch = rs,
      .scratch_cap = sizeof rs};
  CHECK(vx_ndb_next(&r, &rec) == VX_NDB_RECORD && vx_release_known(&rec));

  // Paths and names.
  char path[71], hex[VX_STORE_HEX + 1];
  vx_store_path(&h, path);
  CHECK(strcmp(path, "b2/ab/abababababababababababababababababababababababababababababababab") == 0);
  vx_store_hex(&h, hex);
  vx_hash back;
  CHECK(vx_store_parse((vx_str){hex, VX_STORE_HEX}, &back) && vx_hash_eq(&back, &h));
}

// One small tree, its hash fixed: a directory holding "hello\n" as hello.txt
// and an empty directory. If this changes, the format changed.
static void check_fixed_tree(void) {
  size_t len;
  vx_hash file, empty, root;
  uint8_t *idx = make_index((const uint8_t *)"hello\n", 6, &len, &file);
  free(idx);
  vx_store_text_hash((const uint8_t *)"", 0, &empty);
  static char text[512];
  vx_ndb_writer w = {.buf = text, .cap = sizeof text};
  vx_store_entry a = {.name = VX_STR("empty"), .mode = 040555, .hash = empty};
  vx_store_entry b = {.name = VX_STR("hello.txt"), .mode = 0100444, .size = 6, .hash = file};
  CHECK(vx_store_dir_put(&w, &a) && vx_store_dir_put(&w, &b));
  vx_store_text_hash((const uint8_t *)text, w.len, &root);
  char hex[VX_STORE_HEX + 1];
  vx_store_hex(&root, hex);
  printf("store_test: the fixed tree is %s\n", hex);
  CHECK(strcmp(hex, FIXED_TREE) == 0);
}

int main(void) {
  check_monocypher();
  check_tree_shape();
  check_files();
  check_dirs();
  check_fixed_tree();
  return check_result();
}
