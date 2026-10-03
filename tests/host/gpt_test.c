// gpt_test.c: lib/vx-gpt against tables made here, whole and damaged: the
// primary used when it is sound, the backup when the primary's header or
// entries fail, nothing when both do; partitions that overlap or leave the
// usable range refused; names from UTF-16; GUIDs from text; 4 KiB sectors.

#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "../../lib/vx-gpt/gpt.c"

typedef struct disk {
  uint8_t *bytes;
  uint32_t sector;
  uint64_t sectors;
  bool broken; // every read fails
} disk;

static bool disk_read(void *ctx, uint64_t lba, uint32_t count, uint8_t *buf) {
  const disk *d = ctx;
  if (d->broken || lba >= d->sectors || count > d->sectors - lba) return false;
  memcpy(buf, d->bytes + lba * d->sector, (size_t)count * d->sector);
  return true;
}

static void put32(uint8_t *p, uint32_t v) {
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> 8 * i);
}
static void put64(uint8_t *p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> 8 * i);
}

typedef struct part {
  const char *type; // GUID text
  uint64_t first, last;
  const uint16_t *name; // UTF-16, NUL-terminated
} part;

static const char ESP[] = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
static const char SYSTEM[] = "7C6D3E1A-2B4F-4E0A-9C1D-56F2A8B90E35";

// Writes a header for a table at `lba` whose entries are at `entries`.
static void header(disk *d, uint64_t lba, uint64_t alt, uint64_t entries, uint32_t ecrc) {
  uint8_t *h = d->bytes + lba * d->sector;
  memset(h, 0, d->sector);
  static const uint8_t SIGNATURE[8] = {'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T'};
  memcpy(h, SIGNATURE, sizeof SIGNATURE);
  put32(h + 8, 0x00010000);
  put32(h + 12, 92);
  put64(h + 24, lba);
  put64(h + 32, alt);
  uint64_t esect = 128 * 128 / d->sector;
  put64(h + 40, 2 + esect);
  put64(h + 48, d->sectors - 2 - esect);
  memset(h + 56, 0x5a, 16);
  put64(h + 72, entries);
  put32(h + 80, 128);
  put32(h + 84, 128);
  put32(h + 88, ecrc);
  put32(h + 16, gpt_crc32(h, 92));
}

// A whole disk with these partitions, primary and backup.
static disk make(uint32_t sector, uint64_t sectors, const part *parts, int n) {
  disk d = {.bytes = calloc(sectors, sector), .sector = sector, .sectors = sectors};
  uint8_t entries[128 * 128] = {};
  for (int i = 0; i < n; i++) {
    uint8_t *e = entries + (size_t)128 * i;
    vx_gpt_guid(parts[i].type, strlen(parts[i].type), e);
    memset(e + 16, i + 1, 16);
    put64(e + 32, parts[i].first);
    put64(e + 40, parts[i].last);
    for (int k = 0; parts[i].name && parts[i].name[k]; k++)
      e[56 + 2 * k] = (uint8_t)parts[i].name[k], e[57 + 2 * k] = (uint8_t)(parts[i].name[k] >> 8);
  }
  uint32_t ecrc = gpt_crc32(entries, sizeof entries);
  uint64_t esect = sizeof entries / sector;
  memcpy(d.bytes + (size_t)2 * sector, entries, sizeof entries);
  memcpy(d.bytes + (sectors - 1 - esect) * sector, entries, sizeof entries);
  header(&d, 1, sectors - 1, 2, ecrc);
  header(&d, sectors - 1, 1, sectors - 1 - esect, ecrc);
  return d;
}

static const uint16_t NAME_ESP[] = {'E', 'F', 'I', 0};
static const uint16_t NAME_VECTRA[] = {'v', 'e', 'c', 't', 'r', 'a', 0};
static const uint16_t NAME_ODD[] = {0x00e9, 0x20ac, 0xd83d,
                                    0xde00, 0xdc00, 0}; // é € 😀, a lone low surrogate

int main(void) {
  static vx_gpt g;
  part two[] = {{ESP, 2048, 4095, NAME_ESP}, {SYSTEM, 4096, 8191, NAME_VECTRA}};

  // Sound: the primary, its partitions as written.
  disk d = make(512, 16384, two, 2);
  CHECK(vx_gpt_read(&g, 512, d.sectors, disk_read, &d) == VX_OK && !g.backup && g.count == 2);
  uint8_t esp[16], sys[16];
  CHECK(vx_gpt_guid(ESP, sizeof ESP - 1, esp) && vx_gpt_guid(SYSTEM, sizeof SYSTEM - 1, sys));
  CHECK(memcmp(g.parts[0].type, esp, 16) == 0 && g.parts[0].first == 2048 && g.parts[0].last == 4095);
  CHECK(memcmp(g.parts[1].type, sys, 16) == 0 && strcmp(g.parts[1].name, "vectra") == 0);
  CHECK(strcmp(g.parts[0].name, "EFI") == 0);
  // As the disk stores the ESP's type GUID (build.c's ESP_TYPE).
  static const uint8_t ESP_ON_DISK[16] = {0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11,
                                          0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b};
  CHECK(memcmp(esp, ESP_ON_DISK, 16) == 0);

  // The primary's header damaged: the backup.
  d.bytes[512 + 40] ^= 1;
  CHECK(vx_gpt_read(&g, 512, d.sectors, disk_read, &d) == VX_OK && g.backup && g.count == 2);
  // Both damaged: nothing.
  d.bytes[(d.sectors - 1) * 512 + 40] ^= 1;
  CHECK(vx_gpt_read(&g, 512, d.sectors, disk_read, &d) == VX_ERR_INVALID && g.count == 0);
  free(d.bytes);

  // The primary's entries damaged: the backup's.
  d = make(512, 16384, two, 2);
  d.bytes[2 * 512 + 33] ^= 1;
  CHECK(vx_gpt_read(&g, 512, d.sectors, disk_read, &d) == VX_OK && g.backup);
  // A header that says it is somewhere else is not the one there.
  d.broken = true;
  CHECK(vx_gpt_read(&g, 512, d.sectors, disk_read, &d) == VX_ERR_IO);
  free(d.bytes);

  // Overlapping partitions, or one outside the usable range: refused.
  part overlap[] = {{ESP, 2048, 4095, nullptr}, {SYSTEM, 4000, 8191, nullptr}};
  d = make(512, 16384, overlap, 2);
  CHECK(vx_gpt_read(&g, 512, d.sectors, disk_read, &d) == VX_ERR_INVALID);
  free(d.bytes);
  part outside[] = {{ESP, 2048, 16383, nullptr}};
  d = make(512, 16384, outside, 1);
  CHECK(vx_gpt_read(&g, 512, d.sectors, disk_read, &d) == VX_ERR_INVALID);
  free(d.bytes);
  part early[] = {{ESP, 10, 100, nullptr}}; // over the primary's entries
  d = make(512, 16384, early, 1);
  CHECK(vx_gpt_read(&g, 512, d.sectors, disk_read, &d) == VX_ERR_INVALID);
  free(d.bytes);

  // Names beyond ASCII, a lone surrogate as U+FFFD.
  part odd[] = {{ESP, 2048, 4095, NAME_ODD}};
  d = make(512, 16384, odd, 1);
  CHECK(vx_gpt_read(&g, 512, d.sectors, disk_read, &d) == VX_OK &&
        strcmp(g.parts[0].name, "\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\xef\xbf\xbd") == 0);
  free(d.bytes);

  // 4 KiB sectors.
  part big[] = {{SYSTEM, 256, 1023, NAME_VECTRA}};
  d = make(4096, 4096, big, 1);
  CHECK(vx_gpt_read(&g, 4096, d.sectors, disk_read, &d) == VX_OK && g.count == 1 && g.parts[0].first == 256);
  free(d.bytes);

  // GUID text that is not one.
  uint8_t x[16];
  CHECK(!vx_gpt_guid("C12A7328F81F11D2BA4B00A0C93EC93B", 32, x));
  CHECK(!vx_gpt_guid("C12A7328-F81F-11D2-BA4B-00A0C93EC93", 35, x));
  CHECK(!vx_gpt_guid("G12A7328-F81F-11D2-BA4B-00A0C93EC93B", 36, x));
  CHECK(!vx_gpt_guid("C12A7328-F81F-11D2-BA4B+00A0C93EC93B", 36, x));
  return check_result();
}
