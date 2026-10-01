// devmgr: the device manager (docs/01 §7.2). M3's first part: it finds the
// PCI functions, through the MCFG's ECAM regions, and reports them. (Matching
// them to drivers, and starting the drivers, come next.)
//
// svcd gives it the root Resource, to map configuration space, and the ACPI
// tables. Configuration space is mapped one bus (1 MiB) at a time, as buses
// are found: the first in each region, then whatever bridges lead to.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-acpi/acpi.c"
#include "../../lib/vx-pci/pci.c"

static vx_handle resource;

static const char *class_name(uint8_t c) {
  static const char *const NAMES[] = {"old",   "storage", "net",   "display", "media", "memory",    "bridge",
                                      "comms", "system",  "input", "dock",    "cpu",   "serial-bus"};
  return c < sizeof NAMES / sizeof NAMES[0] ? NAMES[c] : "other";
}

static void hex(uint64_t v, int digits) {
  char buf[16];
  for (int i = digits - 1; i >= 0; i--, v >>= 4) buf[i] = "0123456789abcdef"[v & 15];
  vx_print((vx_str){buf, (size_t)digits});
}

static uint32_t found;

// Maps a bus's configuration space; nullptr if it cannot.
static volatile uint8_t *map_bus(const vx_ecam *e, uint8_t bus) {
  vx_handle vmo;
  uint64_t at = 0;
  if (vx_vmo_create_physical(resource, e->base + ((uint64_t)bus << 20), 1 << 20, &vmo) != VX_OK)
    return nullptr;
  vx_status st = vx_as_map(vx_self, vmo, 0, 1 << 20, VX_MAP_WRITE, &at);
  vx_handle_close(vmo);
  return st == VX_OK ? (volatile uint8_t *)at : nullptr;
}

// Buses to scan: the first, and those bridges lead to. A worklist rather than
// recursion, since the device decides how deep the bridges go.
static uint8_t pending[256];
static uint32_t pending_count;
static bool seen_bus[256];

static void scan_bus(const vx_ecam *e, uint8_t bus) {
  volatile uint8_t *space = map_bus(e, bus);
  if (!space) return;
  for (uint8_t dev = 0; dev < 32; dev++) {
    for (uint8_t fn = 0; fn < 8; fn++) {
      vx_pci_fn f = {
          .cfg = space + ((uint32_t)dev << 15 | (uint32_t)fn << 12), .bus = bus, .dev = dev, .fn = fn};
      uint16_t vendor = vx_pci_read16(&f, 0x00);
      if (vendor == 0xffff) {
        if (fn == 0) break; // no device here
        continue;
      }
      uint32_t class = vx_pci_read32(&f, 0x08) >> 8;
      uint8_t header = vx_pci_read8(&f, 0x0e);
      found++;
      vx_print(VX_STR("devmgr: "));
      hex(bus, 2), vx_print(VX_STR(":")), hex(dev, 2), vx_print(VX_STR(".")), hex(fn, 1);
      vx_print(VX_STR(" ")), hex(vendor, 4), vx_print(VX_STR(":")), hex(vx_pci_read16(&f, 0x02), 4);
      vx_print(VX_STR(" ")), vx_print(vx_cstr(class_name((uint8_t)(class >> 16))));
      if (vx_pci_cap(&f, 0x11, 0)) vx_print(VX_STR(" msi-x"));
      for (uint32_t i = 0; (header & 0x7f) == 0 && i < 6; i++) {
        bool wide =
            (vx_pci_read32(&f, 0x10 + 4 * i) & 7) == 4; // a 64-bit memory BAR: i + 1 is its upper half
        vx_pci_bar b = vx_pci_bar_read(&f, i);
        if (b.size) {
          vx_print(VX_STR(" bar")), hex(i, 1), vx_print(b.io ? VX_STR("=io:") : VX_STR("="));
          if (b.size >= 1024)
            vx_print_u64(b.size >> 10), vx_print(VX_STR("K"));
          else
            vx_print_u64(b.size);
        }
        if (wide) i++;
      }
      vx_print(VX_STR("\n"));
      if ((header & 0x7f) == 1) { // a bridge: the bus behind it
        uint8_t secondary = vx_pci_read8(&f, 0x19);
        if (secondary > bus && secondary <= e->end_bus && !seen_bus[secondary]) {
          seen_bus[secondary] = true;
          pending[pending_count++] = secondary;
        }
      }
      if (fn == 0 && !(header & 0x80)) break; // a single-function device
    }
  }
}

int vx_main(void) {
  resource = vx_spawn_take("resource");
  vx_handle acpi = vx_spawn_take("acpi");
  vx_ndb_record rec;
  uint64_t size = 0, at = 0;
  if (!resource || !acpi || !vx_spawn_record("acpi", &rec) || !vx_ndb_get_u64(&rec, "size", &size) ||
      vx_as_map(vx_self, acpi, 0, (size + 4095) & ~4095ull, 0, &at) != VX_OK) {
    vx_print(VX_STR("devmgr: FAILED: no Resource or ACPI tables\n"));
    return 1;
  }
  vx_acpi_table mcfg;
  if (vx_acpi_find((const uint8_t *)at, size, "MCFG", 0, &mcfg) != VX_OK) {
    vx_print(VX_STR("devmgr: no MCFG, so no PCI\n"));
    return 0;
  }
  vx_ecam e;
  for (uint32_t n = 0; vx_acpi_mcfg(mcfg, n, &e) == VX_OK; n++)
    if (e.segment == 0) { // other segments: when hardware has them
      pending_count = 0;
      for (uint32_t b = 0; b < 256; b++) seen_bus[b] = false;
      seen_bus[e.start_bus] = true;
      pending[pending_count++] = e.start_bus;
      while (pending_count) scan_bus(&e, pending[--pending_count]);
    }
  vx_print(VX_STR("devmgr: "));
  vx_print_u64(found);
  vx_print(VX_STR(" PCI functions\n"));
  for (;;) vx_port_wait(vx_self, VX_INFINITE, 0, &(vx_packet){}, 1); // drivers to watch, from step 2
}
