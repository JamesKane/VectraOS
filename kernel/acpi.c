// acpi.c: the firmware's ACPI tables (both architectures; edk2 provides them
// on arm64 QEMU too). The kernel reads the MADT itself, for the interrupt
// controllers, and copies every table into one read-only VMO for the root
// task, so that devmgr can read the rest (MCFG for PCI, and the AML later)
// in user space (01 §7.2).

static uint32_t read32(const uint8_t *p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}

static uint64_t read64(const uint8_t *p) {
  uint64_t v;
  memcpy(&v, p, 8);
  return v;
}

// An ACPI table by signature, through the RSDT or XSDT; nullptr if there is none.
static const uint8_t *acpi_table(const char sig[4]) {
  uint64_t rsdp_pa = boot.rsdp;
  if (!rsdp_pa || !in_direct_map(rsdp_pa, 36)) return nullptr;
  const uint8_t *rsdp = phys_to_virt(rsdp_pa);
  bool xsdt = rsdp[15] >= 2;
  uint64_t root = xsdt ? read64(rsdp + 24) : read32(rsdp + 16);
  if (!in_direct_map(root, 36)) return nullptr;
  const uint8_t *sdt = phys_to_virt(root);
  uint32_t len = read32(sdt + 4), entry = xsdt ? 8 : 4;
  if (!in_direct_map(root, len)) return nullptr;
  for (uint32_t off = 36; off + entry <= len; off += entry) {
    uint64_t pa = xsdt ? read64(sdt + off) : read32(sdt + off);
    if (!in_direct_map(pa, 36)) continue;
    const uint8_t *t = phys_to_virt(pa);
    if (memcmp(t, sig, 4) == 0 && in_direct_map(pa, read32(t + 4))) return t;
  }
  return nullptr;
}

// A table at a physical address, if it is whole and in the direct map.
static const uint8_t *acpi_at(uint64_t pa) {
  if (!pa || !in_direct_map(pa, 36)) return nullptr;
  const uint8_t *t = phys_to_virt(pa);
  return read32(t + 4) >= 36 && in_direct_map(pa, read32(t + 4)) ? t : nullptr;
}

// Every table the RSDT or XSDT lists, and the DSDT the FADT points to, end
// to end in one VMO: each starts with its own header, whose length says where
// the next begins. Its size goes in *size; nullptr if there is no ACPI.
static vmo *acpi_export(uint64_t *size) {
  uint64_t rsdp_pa = boot.rsdp;
  if (!rsdp_pa || !in_direct_map(rsdp_pa, 36)) return nullptr;
  const uint8_t *rsdp = phys_to_virt(rsdp_pa);
  bool xsdt = rsdp[15] >= 2;
  const uint8_t *sdt = acpi_at(xsdt ? read64(rsdp + 24) : read32(rsdp + 16));
  if (!sdt) return nullptr;
  const uint8_t *tables[64];
  uint32_t count = 0, entry = xsdt ? 8 : 4, len = read32(sdt + 4);
  for (uint32_t off = 36; off + entry <= len && count < 63; off += entry) {
    const uint8_t *t = acpi_at(xsdt ? read64(sdt + off) : read32(sdt + off));
    if (t) tables[count++] = t;
  }
  const uint8_t *fadt = acpi_table("FACP");
  if (fadt) { // the DSDT: X_DSDT where the FADT is long enough to have it, else DSDT
    uint32_t flen = read32(fadt + 4);
    uint64_t pa = flen >= 44 ? read32(fadt + 40) : 0;
    if (flen >= 148 && read64(fadt + 140)) pa = read64(fadt + 140);
    const uint8_t *dsdt = acpi_at(pa);
    if (dsdt) tables[count++] = dsdt;
  }
  uint64_t total = 0;
  for (uint32_t i = 0; i < count; i++) total += read32(tables[i] + 4);
  vmo *v;
  if (!total || vmo_create(total, &v) != VX_OK) return nullptr;
  uint64_t at = 0;
  for (uint32_t i = 0; i < count; i++) {
    vmo_write(v, at, tables[i], read32(tables[i] + 4));
    at += read32(tables[i] + 4);
  }
  *size = total;
  return v;
}
