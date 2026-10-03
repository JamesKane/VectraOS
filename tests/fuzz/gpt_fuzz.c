// gpt_fuzz.c: arbitrary bytes as a disk for vx-gpt's reader. Whatever it
// accepts must be a table whose partitions lie in its usable range, inside
// the disk, and overlap no other, with names that are NUL-terminated.

#include <stdlib.h>
#include <string.h>

#include "../../lib/vx-gpt/gpt.c"

typedef struct disk {
  const uint8_t *bytes;
  uint64_t sectors;
} disk;

static bool disk_read(void *ctx, uint64_t lba, uint32_t count, uint8_t *buf) {
  const disk *d = ctx;
  if (lba >= d->sectors || count > d->sectors - lba) return false;
  memcpy(buf, d->bytes + lba * 512, (size_t)count * 512);
  return true;
}

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static vx_gpt g;
  disk d = {.bytes = data, .sectors = size / 512};
  if (vx_gpt_read(&g, 512, d.sectors, disk_read, &d) != VX_OK) return 0;
  if (g.first_usable > g.last_usable || g.last_usable >= d.sectors) abort();
  for (uint32_t i = 0; i < g.count; i++) {
    const vx_gpt_part *p = &g.parts[i];
    if (p->first > p->last || p->first < g.first_usable || p->last > g.last_usable) abort();
    if (!memchr(p->name, 0, sizeof p->name)) abort();
    for (uint32_t k = 0; k < i; k++)
      if (p->first <= g.parts[k].last && g.parts[k].first <= p->last) abort();
  }
  return 0;
}
