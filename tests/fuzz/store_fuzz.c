// store_fuzz.c: arbitrary bytes as content-store objects, into vx-store, as
// distd and install meet them from untrusted peers and media (06 §6). As a
// directory: every entry found must be one (a name without '/', a known
// type, a hash or a target). As a file's index: one that checks must have
// as many hashes as its size has blocks, inside the input. As a block of
// such a file: it is checked, and only a block of the right length can pass.
// host-links: monocypher

#include <stdlib.h>

#include "../../lib/vx-store/store.c"

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t len); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t len) {
  static char scratch[1 << 16];
  vx_store_entry e;
  vx_str names[] = {VX_STR("bin"), VX_STR("a"), VX_STR("")};
  for (size_t i = 0; i < 3; i++) {
    vx_status st = vx_store_dir_find(data, len, names[i], scratch, sizeof scratch, &e);
    if (st == VX_OK) {
      for (size_t k = 0; k < e.name.len; k++)
        if (e.name.ptr[k] == '/') abort();
      uint32_t type = e.mode & 0170000;
      if (type != 040000 && type != 0100000 && type != 0120000) abort();
      if (type == 0120000 && !e.link.len) abort();
    }
  }
  // As an index named by its own computed hash (so the check can pass).
  if (len >= VX_STORE_INDEX_HEAD && memcmp(data, "vxsf", 4) == 0) {
    uint64_t sz = 0;
    for (int i = 7; i >= 0; i--) sz = sz << 8 | data[4 + i];
    uint64_t n = vx_store_blocks(sz);
    vx_hash name = {};
    if (sz <= (1ull << 48) && len == VX_STORE_INDEX_HEAD + n * VX_STORE_HASH) {
      vx_hash root;
      vx_store_root(data + VX_STORE_INDEX_HEAD, n, &root);
      vx_store_file_hash(sz, &root, &name);
    }
    uint64_t file_size, got_n;
    const uint8_t *hashes;
    if (vx_store_index_check(&name, data, len, &file_size, &hashes, &got_n) == VX_OK) {
      if (got_n != vx_store_blocks(file_size) || hashes + got_n * VX_STORE_HASH != data + len) abort();
      // The input itself as each block: only one of the right length can pass.
      for (uint64_t i = 0; i < got_n && i < 4; i++) {
        uint64_t want = i + 1 < got_n ? VX_STORE_BLOCK : file_size - i * VX_STORE_BLOCK;
        if (vx_store_block_check(hashes, got_n, file_size, i, data, len) == VX_OK && len != want) abort();
      }
    }
  }
  vx_hash any = {};
  (void)vx_store_dir_check(&any, data, len);
  return 0;
}
