// acpi_fuzz.c: arbitrary bytes as the kernel's ACPI export, into vx-acpi.
// Every table it finds must lie inside the input, with a checksum of zero,
// and every MCFG region it reads must lie inside its table.

#include <stdlib.h>

#include "../../lib/vx-acpi/acpi.c"

// libFuzzer calls it by name, so it cannot be static.
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(misc-use-internal-linkage)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  static const char *const SIGS[] = {"APIC", "MCFG", "FACP", "DSDT"};
  for (size_t s = 0; s < sizeof SIGS / sizeof SIGS[0]; s++) {
    vx_acpi_table t;
    for (uint32_t n = 0; n < 8 && vx_acpi_find(data, size, SIGS[s], n, &t) == VX_OK; n++) {
      if (t.ptr < data || t.len < 36 || t.ptr + t.len > data + size) abort();
      uint8_t sum = 0;
      for (uint32_t i = 0; i < t.len; i++) sum = (uint8_t)(sum + t.ptr[i]);
      if (sum) abort();
      vx_ecam e;
      for (uint32_t r = 0; r < 64 && vx_acpi_mcfg(t, r, &e) == VX_OK; r++)
        if (44 + (uint64_t)r * 16 + 16 > t.len || e.end_bus < e.start_bus) abort();
    }
  }
  return 0;
}
