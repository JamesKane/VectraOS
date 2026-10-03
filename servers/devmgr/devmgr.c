// devmgr: the device manager (docs/01 §7.2). It finds the PCI functions,
// through the MCFG's ECAM regions, matches them against the drivers'
// manifests in /boot/drv/*.ndb, and starts each matched driver with only its
// device: the function's configuration space, its memory BARs, its MSIs and a
// DMA domain, minted from the root Resource; and the server end of the post
// the driver serves, which svcd gave devmgr (claim=). It restarts a driver
// that exits, up to a limit.
//
// A driver manifest:
//
//   match=pci vendor=0x1af4 device=0x1041 program=/boot/bin/drv-virtio-net post=ether0 msi=2
//   match=pci vendor=0x1af4 device=0x1042 program=/boot/bin/drv-virtio-blk post=disk# msi=1
//
// A post ending in # is numbered: the record's matches get disk0, disk1, ...,
// in the order the functions were found.
//
// svcd gives it the root Resource, the ACPI tables, a namespace with the boot
// image at /, and the claims. Configuration space is mapped one bus (1 MiB) at
// a time, as buses are found: the first in each region, then whatever bridges
// lead to.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-rt/spawn.c"
#include "../../lib/vx-acpi/acpi.c"
#include "../../lib/vx-pci/pci.c"
#include "../../lib/vx-ns/spawn.c"

static vx_handle resource, port;
static vx_ns ns;

// Every function found, for matching.
typedef struct function {
  vx_pci_fn fn;
  uint64_t config_pa; // its 4 KiB of configuration space
  uint16_t vendor, device;
  uint32_t class; // class, subclass and programming interface: 0x010802, an NVMe controller
} function;

static function functions[64];
static uint32_t function_count;

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
      if ((header & 0x7f) == 0 && function_count < sizeof functions / sizeof functions[0])
        functions[function_count++] = (function){
            .fn = f,
            .config_pa = e->base + ((uint64_t)bus << 20 | (uint64_t)dev << 15 | (uint64_t)fn << 12),
            .vendor = vendor,
            .device = vx_pci_read16(&f, 0x02),
            .class = class};
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

// --- Drivers ---

static constexpr uint32_t MAX_DRIVERS = 16, MAX_STARTS = 5;

typedef struct driver {
  const function *f;
  char program[64], post[32];
  uint32_t msis;
  uint8_t prefix;   // a numbered post's (disk# is "disk"): its length; 0 if not numbered
  vx_handle listen; // the post's server end; each start gets a duplicate
  vx_handle task;
  uint32_t starts;
} driver;

static driver drivers[MAX_DRIVERS];
static uint32_t driver_count;
static uint8_t image[2 << 20];

static void say(vx_str a, vx_str b, vx_str c) {
  vx_print(VX_STR("devmgr: "));
  vx_print(a), vx_print(b), vx_print(c);
}

// Reads a whole file through the namespace into buf; its length, or 0.
static size_t read_whole(vx_str path, uint8_t *buf, size_t cap) {
  vx_ns_file f;
  if (vx_ns_open(&ns, path, P9_OREAD, &f) != VX_OK) return 0;
  size_t n = 0;
  int64_t got;
  while (n < cap && (got = vx_ns_read(&f, buf + n, (uint32_t)(cap - n > 65536 ? 65536 : cap - n))) > 0)
    n += (size_t)got;
  vx_ns_close(&f);
  return n;
}

// Starts (or starts again) a driver: makes its device objects, loads its
// program, and spawns it with them.
static vx_status start_driver(driver *d) {
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1] = {};
  vx_str names[VX_CHANNEL_MAX_HANDLES - 1];
  static char name_buf[VX_CHANNEL_MAX_HANDLES][8];
  uint32_t count = 0;
  static char records[4096];
  vx_ndb_writer w = {.buf = records, .cap = sizeof records};
  vx_status st = vx_vmo_create_physical(resource, d->f->config_pa, 4096, &handles[count]);
  names[count++] = VX_STR("config");
  for (uint32_t i = 0; st == VX_OK && i < 6; i++) { // memory BARs, mapped whole
    bool wide = (vx_pci_read32(&d->f->fn, 0x10 + 4 * i) & 7) == 4;
    vx_pci_bar b = vx_pci_bar_read(&d->f->fn, i);
    if (wide) i++;
    if (!b.size || b.io || b.base & 4095) continue;
    uint32_t n = wide ? i - 1 : i;
    uint64_t size = (b.size + 4095) & ~4095ull;
    st = vx_vmo_create_physical(resource, b.base, size, &handles[count]);
    char *nm = name_buf[count];
    nm[0] = 'b', nm[1] = 'a', nm[2] = 'r', nm[3] = (char)('0' + n), nm[4] = 0;
    names[count++] = (vx_str){nm, 4};
    vx_ndb_put_u64(&w, "bar", n);
    vx_ndb_put_u64(&w, "size", size);
    vx_ndb_end(&w);
  }
  for (uint32_t i = 0; st == VX_OK && i < d->msis && i < 8; i++) {
    vx_msi msi;
    st = vx_irq_create_msi(resource, vx_pci_rid(&d->f->fn), &handles[count], &msi);
    char *nm = name_buf[count];
    nm[0] = 'm', nm[1] = 's', nm[2] = 'i', nm[3] = (char)('0' + i), nm[4] = 0;
    names[count++] = (vx_str){nm, 4};
    vx_ndb_put_u64(&w, "msi", i);
    vx_ndb_put_u64(&w, "address", msi.address);
    vx_ndb_put_u64(&w, "data", msi.data);
    vx_ndb_end(&w);
  }
  if (st == VX_OK) st = vx_dma_domain_create(resource, &handles[count]);
  names[count++] = VX_STR("dma");
  if (st == VX_OK) st = vx_handle_dup(d->listen, VX_RIGHTS_SAME, &handles[count]);
  names[count++] = VX_STR("listen");
  if (st == VX_OK && vx_console.connector &&
      vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[count]) == VX_OK)
    names[count++] = VX_STR("console");
  if (vx_spawn.cmdline.len) { // a driver's options: PROGRAM.KEY=VALUE words, its to read
    vx_ndb_put(&w, "cmdline", vx_spawn.cmdline);
    vx_ndb_end(&w);
  }
  size_t size = st == VX_OK ? read_whole(vx_cstr(d->program), image, sizeof image) : 0;
  if (st == VX_OK && !size) st = VX_ERR_NOT_FOUND;
  if (st == VX_OK && w.failed) st = VX_ERR_RANGE;
  if (st != VX_OK) {
    for (uint32_t i = 0; i < count; i++)
      if (handles[i]) vx_handle_close(handles[i]);
    return st;
  }
  vx_str base = vx_cstr(d->program);
  for (size_t i = base.len; i-- > 0;)
    if (base.ptr[i] == '/') base = (vx_str){base.ptr + i + 1, base.len - i - 1};
  vx_spawn_args a = {.name = base.len < 24 ? base : (vx_str){base.ptr, 23},
                     .image = image,
                     .image_size = size,
                     .handles = handles,
                     .handle_names = names,
                     .handle_count = count,
                     .records = {records, w.len}};
  st = vx_spawn_elf(&a, &d->task);
  if (st == VX_OK) st = vx_port_bind(port, d->task, VX_TRIGGER_EXIT, (uint64_t)(d - drivers), 0);
  if (st == VX_OK) {
    d->starts++;
    say(VX_STR("started "), base, VX_STR("\n"));
  }
  return st;
}

static void driver_exited(driver *d) {
  // The device may still hold addresses of the dead driver's DMA memory, which
  // the kernel has freed: stop it reaching memory at all. (Until the IOMMU,
  // M5, it could write there between the driver's death and now.)
  uint16_t command = vx_pci_read16(&d->f->fn, 0x04);
  vx_pci_write16(&d->f->fn, 0x04, (uint16_t)(command & ~(1u << 2)));
  vx_task_summary info;
  vx_str why = vx_task_info(d->task, &info) == VX_OK ? (vx_str){info.exit, info.exit_len} : VX_STR("?");
  vx_handle_close(d->task);
  d->task = VX_HANDLE_NONE;
  say(vx_cstr(d->program), VX_STR(" exited"), why.len ? VX_STR(": ") : VX_STR(""));
  vx_print(why);
  vx_print(VX_STR("\n"));
  if (d->starts >= MAX_STARTS) {
    say(vx_cstr(d->program), VX_STR(" keeps exiting; it is not started again"), VX_STR("\n"));
    return;
  }
  if (start_driver(d) != VX_OK) say(VX_STR("cannot restart "), vx_cstr(d->program), VX_STR("\n"));
}

// Reads the driver manifests and starts a driver for each function one matches.
static void match_drivers(void) {
  vx_ns_file dir;
  if (vx_ns_open(&ns, VX_STR("/boot/drv"), P9_OREAD, &dir) != VX_OK) return;
  static uint8_t listing[4096], text[8192];
  static char scratch[8192];
  int64_t n;
  while ((n = vx_ns_read(&dir, listing, sizeof listing)) > 0) {
    p9_stat entry;
    for (size_t off = 0; p9_dir_next(listing, (size_t)n, &off, &entry);) {
      char path[96] = "/boot/drv/";
      if (entry.name.len > sizeof path - 11) continue;
      memcpy(path + 10, entry.name.ptr, entry.name.len);
      size_t len = read_whole((vx_str){path, 10 + entry.name.len}, text, sizeof text);
      vx_ndb_reader r = {.src = {(const char *)text, len}, .scratch = scratch, .scratch_cap = sizeof scratch};
      vx_ndb_record rec;
      while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
        // A match names a vendor and device, or a class (a standard
        // interface: NVMe's, whoever makes the controller).
        uint64_t vendor = 0, device = 0, class = 0, msis = 0;
        vx_str program = vx_ndb_get(&rec, "program"), post = vx_ndb_get(&rec, "post");
        bool by_id = vx_ndb_get_u64(&rec, "vendor", &vendor) && vx_ndb_get_u64(&rec, "device", &device);
        bool by_class = !by_id && vx_ndb_get_u64(&rec, "class", &class);
        if (!vx_ndb_has(&rec, "match") || (!by_id && !by_class) || !program.len || program.len >= 64 ||
            post.len >= 26)
          continue;
        vx_ndb_get_u64(&rec, "msi", &msis);
        bool numbered = post.len && post.ptr[post.len - 1] == '#';
        for (uint32_t i = 0; i < function_count && driver_count < MAX_DRIVERS; i++) {
          if (by_id ? functions[i].vendor != vendor || functions[i].device != device
                    : functions[i].class != class)
            continue;
          driver *d = &drivers[driver_count++];
          *d = (driver){.f = &functions[i], .msis = (uint32_t)msis};
          memcpy(d->program, program.ptr, program.len);
          memcpy(d->post, post.ptr, post.len);
          if (numbered) d->prefix = (uint8_t)(post.len - 1);
        }
      }
    }
  }
  vx_ns_close(&dir);
  // Numbered posts in bus order, whichever drivers serve them: disk0 is the
  // first disk found, virtio or NVMe; then each claimed and started.
  for (uint32_t k = 0; k < driver_count; k++) {
    driver *d = &drivers[k];
    size_t plen = d->prefix ? d->prefix : vx_cstr(d->post).len;
    if (d->prefix) { // disk# is disk0, disk1, ...
      uint32_t v = 0;
      for (uint32_t j = 0; j < driver_count; j++)
        v += drivers[j].prefix == d->prefix && memcmp(drivers[j].post, d->post, d->prefix) == 0 &&
             drivers[j].f < d->f;
      char digits[10];
      size_t nd = 0;
      do digits[nd++] = (char)('0' + v % 10);
      while (v /= 10);
      while (nd && plen < sizeof d->post - 1) d->post[plen++] = digits[--nd];
      d->post[plen] = 0;
    }
    char claim[40] = "claim:";
    memcpy(claim + 6, d->post, plen);
    d->listen = vx_spawn_take(claim); // one device to a post: the first match takes it
    if (!d->listen) {
      say(VX_STR("no claim on /srv/"), vx_cstr(d->post), VX_STR(" for its driver\n"));
      continue;
    }
    if (start_driver(d) != VX_OK) say(VX_STR("cannot start "), vx_cstr(d->program), VX_STR("\n"));
  }
}

const char *vx_main(void) {
  resource = vx_spawn_take("resource");
  vx_handle acpi = vx_spawn_take("acpi");
  vx_ndb_record rec;
  uint64_t size = 0, at = 0;
  if (!resource || !acpi || !vx_spawn_record("acpi", &rec) || !vx_ndb_get_u64(&rec, "size", &size) ||
      vx_as_map(vx_self, acpi, 0, (size + 4095) & ~4095ull, 0, &at) != VX_OK) {
    vx_print(VX_STR("devmgr: FAILED: no Resource or ACPI tables\n"));
    return "no Resource or ACPI tables";
  }
  vx_acpi_table mcfg;
  if (vx_acpi_find((const uint8_t *)at, size, "MCFG", 0, &mcfg) != VX_OK) {
    vx_print(VX_STR("devmgr: no MCFG, so no PCI\n"));
    return nullptr;
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

  if (vx_ns_from_spawn(&ns) != VX_OK || vx_port_create(0, &port) != VX_OK) {
    vx_print(VX_STR("devmgr: FAILED: no namespace, so no drivers\n"));
    return "no namespace";
  }
  match_drivers();
  for (;;) { // drivers that exit are started again, up to a limit
    vx_packet pk[8];
    int64_t n = vx_port_wait(port, VX_INFINITE, 0, pk, 8);
    for (int64_t i = 0; i < n; i++)
      if (pk[i].trigger == VX_TRIGGER_EXIT && pk[i].key < driver_count) driver_exited(&drivers[pk[i].key]);
  }
}
