// vx-store: the content store's objects and tree format (docs/06 §4, M5
// step 9a), shared by distd, install and host/vxstore. Pure code over
// Monocypher's BLAKE2b (ADR-0032), so it builds for the host's tests too.
//
// Every object is named by a BLAKE2b-256 hash, written b2:<64 hex>, and
// stored as b2/<first two hex>/<all 64 hex> under the store's root. Three
// kinds:
//
// - A block: up to 64 KiB of a file. Its name is the leaf hash
//   BLAKE2b(0x00 || bytes).
// - A file's index: "vxsf", the file's size (u64, little-endian), then the
//   hash of each of its blocks (one block, empty, for an empty file). Its
//   name, which is the file's hash, is BLAKE2b(0x02 || size || root): the
//   size, and the root of a hash tree over those block hashes, shaped as
//   RFC 6962's (split at the largest power of two below the count), each
//   inner node BLAKE2b(0x01 || left || right). So a reader checks the index
//   against its name once, then any block against the index on its own.
// - A directory: ndb text, one record per entry, sorted by name (bytes),
//   in one canonical form (vx_store_dir_put's):
//     name=bin mode=040555 hash=b2:...
//     name=svcd mode=0555 size=394632 hash=b2:...
//     name=sh mode=0120777 link=/bin/gsh
//   Its name is BLAKE2b(text), as doc 06 has it. A tree's hash is its root
//   directory's.
//
// The prefixes keep a leaf from passing for an inner node; a directory's
// text never starts with 0x00 or 0x01, so it cannot pass for either.

#pragma once

#include "../../abi/vx/abi.h"
#include "../vx-ndb/ndb.c"
#include "monocypher.h"

#if __STDC_HOSTED__
#include <string.h>
#else
#include "../vx-mem/mem.h"
#endif

enum : uint32_t { VX_STORE_BLOCK = 65536, VX_STORE_HASH = 32, VX_STORE_HEX = 3 + 64 };
static constexpr uint32_t VX_STORE_INDEX_HEAD = 12; // "vxsf" and the size

typedef struct vx_hash {
  uint8_t b[VX_STORE_HASH];
} vx_hash;

[[maybe_unused]] static bool vx_hash_eq(const vx_hash *a, const vx_hash *b) {
  return memcmp(a->b, b->b, VX_STORE_HASH) == 0;
}

// --- Hashes ---

[[maybe_unused]] static void vx_store_leaf(const uint8_t *data, size_t len, vx_hash *out) {
  crypto_blake2b_ctx ctx;
  crypto_blake2b_init(&ctx, VX_STORE_HASH);
  crypto_blake2b_update(&ctx, (const uint8_t[]){0x00}, 1);
  crypto_blake2b_update(&ctx, data, len);
  crypto_blake2b_final(&ctx, out->b);
}

[[maybe_unused]] static void vx_store_node(const vx_hash *l, const vx_hash *r, vx_hash *out) {
  crypto_blake2b_ctx ctx;
  crypto_blake2b_init(&ctx, VX_STORE_HASH);
  crypto_blake2b_update(&ctx, (const uint8_t[]){0x01}, 1);
  crypto_blake2b_update(&ctx, l->b, VX_STORE_HASH);
  crypto_blake2b_update(&ctx, r->b, VX_STORE_HASH);
  crypto_blake2b_final(&ctx, out->b);
}

// The root over n leaf hashes (n >= 1), stored as the index has them:
// n * 32 bytes. Recursion depth is the tree's height, log2(n).
// NOLINTNEXTLINE(misc-no-recursion): as deep as the tree, 40 levels at most
[[maybe_unused]] static void vx_store_root(const uint8_t *leaves, uint64_t n, vx_hash *out) {
  if (n == 1) {
    memcpy(out->b, leaves, VX_STORE_HASH);
    return;
  }
  uint64_t k = 1;
  while (k * 2 < n) k *= 2; // the largest power of two below n
  vx_hash l, r;
  vx_store_root(leaves, k, &l);
  vx_store_root(leaves + k * VX_STORE_HASH, n - k, &r);
  vx_store_node(&l, &r, out);
}

// A file's hash: its size and its blocks' root, bound together.
[[maybe_unused]] static void vx_store_file_hash(uint64_t size, const vx_hash *root, vx_hash *out) {
  uint8_t head[9] = {0x02};
  for (int i = 0; i < 8; i++) head[1 + i] = (uint8_t)(size >> (8 * i));
  crypto_blake2b_ctx ctx;
  crypto_blake2b_init(&ctx, VX_STORE_HASH);
  crypto_blake2b_update(&ctx, head, sizeof head);
  crypto_blake2b_update(&ctx, root->b, VX_STORE_HASH);
  crypto_blake2b_final(&ctx, out->b);
}

// The plain hash of an object's bytes: a directory's name.
[[maybe_unused]] static void vx_store_text_hash(const uint8_t *text, size_t len, vx_hash *out) {
  crypto_blake2b(out->b, VX_STORE_HASH, text, len);
}

// --- Names ---

[[maybe_unused]] static void vx_store_hex(const vx_hash *h, char out[VX_STORE_HEX + 1]) {
  out[0] = 'b', out[1] = '2', out[2] = ':';
  for (uint32_t i = 0; i < VX_STORE_HASH; i++) {
    out[3 + 2 * i] = "0123456789abcdef"[h->b[i] >> 4];
    out[4 + 2 * i] = "0123456789abcdef"[h->b[i] & 15];
  }
  out[VX_STORE_HEX] = 0;
}

// "b2:<64 lower-case hex>" as a hash; false if it is not one.
[[maybe_unused]] static bool vx_store_parse(vx_str s, vx_hash *out) {
  if (s.len != VX_STORE_HEX || memcmp(s.ptr, "b2:", 3) != 0) return false;
  for (uint32_t i = 0; i < 2 * VX_STORE_HASH; i++) {
    char c = s.ptr[3 + i];
    int d = c >= '0' && c <= '9' ? c - '0' : -1;
    if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
    if (d < 0) return false;
    if (i % 2 == 0)
      out->b[i / 2] = (uint8_t)(d << 4);
    else
      out->b[i / 2] |= (uint8_t)d;
  }
  return true;
}

// The object's path under the store's root: "b2/9f/9f3c...", NUL-terminated.
[[maybe_unused]] static void vx_store_path(const vx_hash *h, char out[3 + 3 + 64 + 1]) {
  char hex[VX_STORE_HEX + 1];
  vx_store_hex(h, hex);
  memcpy(out, "b2/", 3);
  memcpy(out + 3, hex + 3, 2);
  out[5] = '/';
  memcpy(out + 6, hex + 3, 64);
  out[70] = 0;
}

// --- Files ---

[[maybe_unused]] static uint64_t vx_store_blocks(uint64_t size) {
  return size ? (size + VX_STORE_BLOCK - 1) / VX_STORE_BLOCK : 1;
}

// A file's index checked against its name: its size, and where its block
// hashes are in it (n of them). INVALID if it is not an index; IO if it is
// one that does not hash to the name (corrupt, or not the object asked for).
[[maybe_unused]] static vx_status vx_store_index_check(const vx_hash *name, const uint8_t *obj, size_t len,
                                                       uint64_t *size, const uint8_t **hashes, uint64_t *n) {
  if (len < VX_STORE_INDEX_HEAD || memcmp(obj, "vxsf", 4) != 0) return VX_ERR_INVALID;
  uint64_t sz = 0;
  for (int i = 7; i >= 0; i--) sz = sz << 8 | obj[4 + i];
  uint64_t count = vx_store_blocks(sz);
  if (sz > (1ull << 48) || len != VX_STORE_INDEX_HEAD + count * VX_STORE_HASH) return VX_ERR_INVALID;
  vx_hash root, h;
  vx_store_root(obj + VX_STORE_INDEX_HEAD, count, &root);
  vx_store_file_hash(sz, &root, &h);
  if (!vx_hash_eq(&h, name)) return VX_ERR_IO;
  *size = sz, *hashes = obj + VX_STORE_INDEX_HEAD, *n = count;
  return VX_OK;
}

// Block i of a file of size bytes checked against the index's hashes.
[[maybe_unused]] static vx_status vx_store_block_check(const uint8_t *hashes, uint64_t n, uint64_t size,
                                                       uint64_t i, const uint8_t *data, size_t len) {
  if (i >= n) return VX_ERR_RANGE;
  uint64_t want = i + 1 < n ? VX_STORE_BLOCK : size - i * VX_STORE_BLOCK;
  if (len != want) return VX_ERR_IO;
  vx_hash h;
  vx_store_leaf(data, len, &h);
  return memcmp(h.b, hashes + i * VX_STORE_HASH, VX_STORE_HASH) == 0 ? VX_OK : VX_ERR_IO;
}

// The head of an index for a file of size bytes; its block hashes follow.
[[maybe_unused]] static void vx_store_index_head(uint64_t size, uint8_t out[VX_STORE_INDEX_HEAD]) {
  out[0] = 'v', out[1] = 'x', out[2] = 's', out[3] = 'f';
  for (int i = 0; i < 8; i++) out[4 + i] = (uint8_t)(size >> (8 * i));
}

// --- Directories ---

typedef struct vx_store_entry {
  vx_str name;
  uint32_t mode; // POSIX: type bits and permissions (040555 a directory, 0120777 a link)
  uint64_t size; // a file's
  vx_hash hash;  // a file's or a directory's
  vx_str link;   // a link's target
} vx_store_entry;

[[maybe_unused]] static bool vx_store_is_dir(const vx_store_entry *e) {
  return (e->mode & 0170000) == 040000;
}
[[maybe_unused]] static bool vx_store_is_link(const vx_store_entry *e) {
  return (e->mode & 0170000) == 0120000;
}

// An entry's record, canonical: name, mode (octal), size (files), hash or link.
[[maybe_unused]] static bool vx_store_dir_put(vx_ndb_writer *w, const vx_store_entry *e) {
  char mode[12];
  int n = 0;
  uint32_t m = e->mode;
  char digits[12];
  int nd = 0;
  do digits[nd++] = (char)('0' + (m & 7));
  while ((m >>= 3) && nd < 11);
  mode[n++] = '0';
  while (nd) mode[n++] = digits[--nd];
  vx_ndb_put(w, "name", e->name);
  vx_ndb_put(w, "mode", (vx_str){mode, (size_t)n});
  if (vx_store_is_link(e)) {
    vx_ndb_put(w, "link", e->link);
  } else {
    char hex[VX_STORE_HEX + 1];
    vx_store_hex(&e->hash, hex);
    if (!vx_store_is_dir(e)) vx_ndb_put_u64(w, "size", e->size);
    vx_ndb_put(w, "hash", (vx_str){hex, VX_STORE_HEX});
  }
  return vx_ndb_end(w);
}

// An entry from a directory's record: INVALID if the record is not one.
// Its strings point into the record (the reader's scratch).
[[maybe_unused]] static vx_status vx_store_dir_entry(const vx_ndb_record *rec, vx_store_entry *e) {
  *e = (vx_store_entry){.name = vx_ndb_get(rec, "name")};
  vx_str mode = vx_ndb_get(rec, "mode");
  if (!e->name.len || mode.len < 2 || mode.len > 7 || mode.ptr[0] != '0') return VX_ERR_INVALID;
  for (size_t i = 0; i < e->name.len; i++)
    if (e->name.ptr[i] == '/' || e->name.ptr[i] == 0) return VX_ERR_INVALID;
  if ((e->name.len == 1 && e->name.ptr[0] == '.') || (e->name.len == 2 && memcmp(e->name.ptr, "..", 2) == 0))
    return VX_ERR_INVALID;
  for (size_t i = 1; i < mode.len; i++) {
    if (mode.ptr[i] < '0' || mode.ptr[i] > '7') return VX_ERR_INVALID;
    e->mode = e->mode << 3 | (uint32_t)(mode.ptr[i] - '0');
  }
  uint32_t type = e->mode & 0170000;
  if (type == 0120000) {
    e->link = vx_ndb_get(rec, "link");
    return e->link.len ? VX_OK : VX_ERR_INVALID;
  }
  if (type != 040000 && type != 0100000) return VX_ERR_INVALID;
  if (!vx_store_parse(vx_ndb_get(rec, "hash"), &e->hash)) return VX_ERR_INVALID;
  if (type == 0100000 && !vx_ndb_get_u64(rec, "size", &e->size)) return VX_ERR_INVALID;
  return VX_OK;
}

// A directory object checked against its name: IO if it does not hash to it.
[[maybe_unused]] static vx_status vx_store_dir_check(const vx_hash *name, const uint8_t *text, size_t len) {
  vx_hash h;
  vx_store_text_hash(text, len, &h);
  return vx_hash_eq(&h, name) ? VX_OK : VX_ERR_IO;
}

// The entry named name in a directory's text (checked already): NOT_FOUND
// if none, INVALID if a record is not an entry. scratch holds its strings.
[[maybe_unused]] static vx_status vx_store_dir_find(const uint8_t *text, size_t len, vx_str name,
                                                    char *scratch, size_t cap, vx_store_entry *e) {
  vx_ndb_reader r = {.src = {(const char *)text, len}, .scratch = scratch, .scratch_cap = cap};
  vx_ndb_record rec;
  vx_ndb_result res;
  while ((res = vx_ndb_next(&r, &rec)) == VX_NDB_RECORD) {
    vx_status st = vx_store_dir_entry(&rec, e);
    if (st != VX_OK) return st;
    if (e->name.len == name.len && memcmp(e->name.ptr, name.ptr, name.len) == 0) return VX_OK;
  }
  return res == VX_NDB_END ? VX_ERR_NOT_FOUND : VX_ERR_INVALID;
}
