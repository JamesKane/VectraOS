// acpi_test.c: lib/vx-acpi and lib/vx-pci's capability walk. Tables are found
// by signature and only whole, with good checksums; MCFG regions read back;
// and a capability list that loops or points nowhere is walked safely.

#include <string.h>

#include "check.h"
#include "../../lib/vx-acpi/acpi.c"
#include "../../lib/vx-pci/pci.c"

static uint8_t blob[512];

// A table of `len` bytes with this signature at `at`, its checksum fixed.
static void table(size_t at, const char sig[4], uint32_t len) {
  memset(blob + at, 0, len);
  memcpy(blob + at, sig, 4);
  blob[at + 4] = (uint8_t)len, blob[at + 5] = (uint8_t)(len >> 8);
}

static void seal(size_t at, uint32_t len) {
  uint8_t sum = 0;
  blob[at + 9] = 0;
  for (uint32_t i = 0; i < len; i++) sum = (uint8_t)(sum + blob[at + i]);
  blob[at + 9] = (uint8_t)-sum;
}

static void test_tables(void) {
  table(0, "FACP", 40);
  seal(0, 40);
  table(40, "MCFG", 76); // two regions
  uint8_t *e = blob + 40 + 44;
  e[3] = 0xe0;                       // base 0xe0000000
  e[10] = 0, e[11] = 0xff;           // buses 0..255
  e[16 + 4] = 0x40, e[16 + 8] = 1;   // base 0x40_0000_0000 (byte 4: bits 32..39), segment 1
  e[16 + 10] = 0, e[16 + 11] = 0x0f; // buses 0..15
  seal(40, 76);
  table(116, "APIC", 36);
  seal(116, 36);
  table(152, "APIC", 36);
  seal(152, 36);
  size_t size = 188;

  vx_acpi_table t;
  CHECK(vx_acpi_find(blob, size, "MCFG", 0, &t) == VX_OK && t.len == 76 && t.ptr == blob + 40);
  CHECK(vx_acpi_find(blob, size, "APIC", 1, &t) == VX_OK && t.ptr == blob + 152);
  CHECK(vx_acpi_find(blob, size, "APIC", 2, &t) == VX_ERR_NOT_FOUND);
  CHECK(vx_acpi_find(blob, size, "SSDT", 0, &t) == VX_ERR_NOT_FOUND);
  vx_ecam r;
  vx_acpi_find(blob, size, "MCFG", 0, &t);
  CHECK(vx_acpi_mcfg(t, 0, &r) == VX_OK && r.base == 0xe000'0000 && r.segment == 0 && r.end_bus == 0xff);
  CHECK(vx_acpi_mcfg(t, 1, &r) == VX_OK && r.base == 0x40'0000'0000 && r.segment == 1 && r.end_bus == 0x0f);
  CHECK(vx_acpi_mcfg(t, 2, &r) == VX_ERR_NOT_FOUND);

  blob[50] ^= 1; // a bad checksum: the MCFG is not found, but the tables after it still are
  CHECK(vx_acpi_find(blob, size, "MCFG", 0, &t) == VX_ERR_NOT_FOUND);
  CHECK(vx_acpi_find(blob, size, "APIC", 0, &t) == VX_OK);
  blob[50] ^= 1;
  blob[44] = 0xff; // a length that runs past the end: nothing after it can be trusted
  CHECK(vx_acpi_find(blob, size, "APIC", 0, &t) == VX_ERR_INVALID);
  blob[44] = 76;
  CHECK(vx_acpi_find(blob, size - 1, "APIC", 1, &t) == VX_ERR_INVALID); // cut short
  blob[4] = 10;                                                         // shorter than a header
  CHECK(vx_acpi_find(blob, size, "FACP", 0, &t) == VX_ERR_INVALID);
}

static void test_capabilities(void) {
  static uint32_t space[1024]; // a function's 4 KiB of configuration space
  uint8_t *cfg = (uint8_t *)space;
  vx_pci_fn f = {.cfg = cfg, .bus = 1, .dev = 2, .fn = 3};
  CHECK(vx_pci_rid(&f) == (1u << 8 | 2u << 3 | 3u));
  CHECK(vx_pci_cap(&f, 0x11, 0) == 0); // no list: the status bit is clear
  cfg[0x06] = 1 << 4, cfg[0x34] = 0x40;
  cfg[0x40] = 0x09, cfg[0x41] = 0x50; // vendor-specific, then
  cfg[0x50] = 0x11, cfg[0x51] = 0x60; // MSI-X, then
  cfg[0x60] = 0x09, cfg[0x61] = 0x00; // vendor-specific, the end
  CHECK(vx_pci_cap(&f, 0x11, 0) == 0x50);
  CHECK(vx_pci_cap(&f, 0x09, 0) == 0x40 && vx_pci_cap(&f, 0x09, 1) == 0x60 && vx_pci_cap(&f, 0x09, 2) == 0);
  cfg[0x61] = 0x40; // a loop: the walk still ends
  CHECK(vx_pci_cap(&f, 0x05, 0) == 0);
  cfg[0x61] = 0x10; // into the header: the walk stops
  CHECK(vx_pci_cap(&f, 0x05, 0) == 0);
  CHECK(vx_pci_read16(&f, 0x50) == (0x60 << 8 | 0x11) && vx_pci_read8(&f, 0x51) == 0x60);
}

int main(void) {
  test_tables();
  test_capabilities();
  return check_result();
}
