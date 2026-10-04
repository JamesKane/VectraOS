// bus-acpi: ACPI in user space (docs/01 §7.2, ADR-0024, ADR-0030). It runs
// ACPICA over the firmware's tables: the DSDT and SSDTs loaded, their AML
// run, and the devices listed with their resources (M5 step 7a). Later steps
// mint its operation regions (7b), power off through S5 (7c), and turn the
// devices' resources into grants for their drivers (7d).
//
// devmgr starts it with the kernel's copy of every table (`acpi`, one
// read-only VMO, each table after the last) and the console. ACPICA finds
// tables through an RSDP and an XSDT at physical addresses; the firmware's
// memory they came from may have been reclaimed since, so this OS layer lays
// the copies out in an address range of its own (TABLES_AT, never a real
// one), behind an RSDP and an XSDT it makes, and ACPICA's "physical" mappings
// of that range are into the copies. The FADT's copy names the DSDT's copy;
// there is no FACS among the copies, so the FADT's copy names none (ADR-0030).
//
// The OS layer (AcpiOs*, acpiosxf.h) is this file's: one thread, so locks and
// semaphores are counters and deferred work runs at once; memory from a heap
// of its own (ACPICA frees without saying how much); the few string and
// character functions ACPICA calls, since it is told the C library is the
// system's (vx-mem gives memcpy and its kin). Operation regions, I/O ports
// and PCI configuration space are refused until devmgr mints them (7b), and
// each refusal is said once.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-acpi/acpi.c"
#include "../../lib/vx-acpi/mint.h"

#include "acpi.h"

// ACPICA's own (utprint.c), which it declares only for its own C library.
int vsnprintf(char *buf, ACPI_SIZE size, const char *fmt, va_list args);
int snprintf(char *buf, ACPI_SIZE size, const char *fmt, ...);

// --- A heap: free lists by power of two, over one VMO ---

static constexpr uint64_t HEAP_BYTES = 8ull << 20;
static constexpr uint32_t HEAP_CLASSES = 17; // 16 bytes to 1 MiB
static uint8_t *heap, *heap_top;
static void *heap_free[HEAP_CLASSES];

typedef struct block { // before each allocation
  uint32_t cls, magic;
  uint64_t pad;
} block;
static constexpr uint32_t BLOCK_MAGIC = 0x6b6c'6261;

void *AcpiOsAllocate(ACPI_SIZE Size) {
  uint32_t cls = 0;
  while ((16ull << cls) < Size + sizeof(block)) cls++;
  if (cls >= HEAP_CLASSES) return nullptr;
  block *b = heap_free[cls];
  if (b) {
    heap_free[cls] = *(void **)(b + 1);
  } else {
    uint64_t want = 16ull << cls;
    if ((uint64_t)(heap + HEAP_BYTES - heap_top) < want) return nullptr;
    b = (block *)heap_top;
    heap_top += want;
  }
  *b = (block){.cls = cls, .magic = BLOCK_MAGIC};
  return b + 1;
}

void AcpiOsFree(void *Memory) {
  if (!Memory) return;
  block *b = (block *)Memory - 1;
  if (b->magic != BLOCK_MAGIC) return; // not ours: kept rather than corrupt the lists
  b->magic = 0;
  *(void **)Memory = heap_free[b->cls];
  heap_free[b->cls] = b;
}

// --- The C library functions ACPICA calls (acclib.h declares them) ---

size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}

int strcmp(const char *a, const char *b) {
  while (*a && *a == *b) a++, b++;
  return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (a[i] != b[i] || !a[i]) return (unsigned char)a[i] - (unsigned char)b[i];
  }
  return 0;
}

char *strcpy(char *d, const char *s) {
  char *r = d;
  while ((*d++ = *s++)) {}
  return r;
}

char *strncpy(char *d, const char *s, size_t n) {
  size_t i = 0;
  for (; i < n && s[i]; i++) d[i] = s[i];
  for (; i < n; i++) d[i] = 0;
  return d;
}

char *strcat(char *d, const char *s) {
  strcpy(d + strlen(d), s);
  return d;
}

char *strchr(const char *s, int c) {
  for (;; s++) {
    if (*s == (char)c) return (char *)s;
    if (!*s) return nullptr;
  }
}

int toupper(int c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
int tolower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }

int isdigit(int c) { return c >= '0' && c <= '9'; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int isalpha(int c) { return isupper(c) || islower(c); }
int isxdigit(int c) { return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
int isspace(int c) { return c == ' ' || (c >= 9 && c <= 13); }
int isprint(int c) { return c >= 32 && c < 127; }

// --- The tables, at addresses of their own ---

static constexpr uint64_t TABLES_AT = 0x0000'7f00'0000'0000; // the RSDP and XSDT, then the copies
static constexpr uint64_t COPIES_AT = TABLES_AT + 0x1'0000;
static uint8_t roots[0x1'0000]; // the RSDP at 0, the XSDT at 64
static uint8_t *copies;         // the kernel's tables, end to end, writable (the FADT is changed)
static uint64_t copies_size;

static void put32(uint8_t *p, uint32_t v) {
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> 8 * i);
}
static void put64(uint8_t *p, uint64_t v) { put32(p, (uint32_t)v), put32(p + 4, (uint32_t)(v >> 32)); }

static void checksum(uint8_t *t, uint32_t len, uint32_t at) {
  uint8_t sum = 0;
  t[at] = 0;
  for (uint32_t i = 0; i < len; i++) sum = (uint8_t)(sum + t[i]);
  t[at] = (uint8_t)-sum;
}

// The RSDP and XSDT naming each copy (but the DSDT, which the FADT names,
// and any FACS), and the FADT's copy pointing at the DSDT's copy.
static bool lay_out_tables(void) {
  uint8_t *x = roots + 64;
  for (int i = 0; i < 4; i++) x[i] = (uint8_t)"XSDT"[i];
  for (int i = 0; i < 6; i++) x[10 + i] = (uint8_t)"VECTRA"[i];
  x[8] = 1;
  uint32_t n = 0;
  uint64_t dsdt = 0;
  for (uint64_t at = 0; at + 36 <= copies_size;) {
    uint8_t *t = copies + at;
    uint32_t len = acpi_u32(t + 4);
    if (len < 36 || len > copies_size - at) return false;
    if (memcmp(t, "DSDT", 4) == 0)
      dsdt = COPIES_AT + at;
    else if (memcmp(t, "FACS", 4) != 0 && 36 + 8 * (n + 1) <= sizeof roots - 64)
      put64(x + 36 + (size_t)8 * n++, COPIES_AT + at);
    at += len;
  }
  put32(x + 4, 36 + 8 * n);
  checksum(x, 36 + 8 * n, 9);
  for (uint64_t at = 0; at + 36 <= copies_size; at += acpi_u32(copies + at + 4)) {
    uint8_t *f = copies + at;
    uint32_t len = acpi_u32(f + 4);
    if (memcmp(f, "FACP", 4) != 0) continue;
    if (len >= 44) put32(f + 36, 0), put32(f + 40, 0); // FIRMWARE_CTRL, DSDT
    if (len >= 140) put64(f + 132, 0);                 // X_FIRMWARE_CTRL
    if (len >= 148)
      put64(f + 140, dsdt); // X_DSDT
    else if (len >= 44 && dsdt < (1ull << 32))
      put32(f + 40, (uint32_t)dsdt);
    checksum(f, len, 9);
  }
  uint8_t *r = roots;
  for (int i = 0; i < 8; i++) r[i] = (uint8_t)"RSD PTR "[i];
  for (int i = 0; i < 6; i++) r[9 + i] = (uint8_t)"VECTRA"[i];
  r[15] = 2;
  put32(r + 20, 36);
  put64(r + 24, TABLES_AT + 64);
  checksum(r, 20, 8);
  checksum(r, 36, 32);
  return true;
}

ACPI_PHYSICAL_ADDRESS AcpiOsGetRootPointer(void) { return TABLES_AT; }

// --- What the AML reaches: asked of devmgr, kept (ADR-0024 item 4) ---
//
// Each region, port range and configuration space is asked for when AML
// first touches it, and kept: devmgr refuses what is RAM, the kernel's or a
// driver's, and a refusal is said once.

static vx_handle devmgr; // the channel to ask on

typedef struct range_t {
  uint64_t base, size;
} range_t;

static const char *vx_status_name(vx_status st) {
  switch (st) {
  case VX_ERR_ACCESS: return "refused (RAM, the kernel's, or a driver's)";
  case VX_ERR_RANGE: return "out of range";
  case VX_ERR_UNSUPPORTED: return "no such thing here";
  case VX_ERR_NO_MEMORY: return "no room";
  case VX_ERR_PEER_CLOSED: return "devmgr is gone";
  default: return "refused";
  }
}

static void said_once(const char *what, uint64_t at, vx_status st) {
  static uint64_t seen[64];
  static uint32_t nseen;
  for (uint32_t i = 0; i < nseen; i++)
    if (seen[i] == at) return;
  if (nseen < 64) seen[nseen++] = at;
  char line[96];
  int n = snprintf(line, sizeof line, "bus-acpi: no %s at 0x%llx: %s\n", what, (unsigned long long)at,
                   vx_status_name(st));
  vx_print((vx_str){line, n > 0 && (size_t)n < sizeof line ? (size_t)n : 0});
}

// What devmgr gives for a request: a handle, or the status of its refusal.
static vx_status ask(uint32_t kind, uint64_t base, uint64_t size, vx_handle *out) {
  vx_acpi_mint m = {.h = {.ordinal = VX_ACPI_MINT}, .kind = kind, .base = base, .size = size};
  vx_msg_header rep;
  *out = VX_HANDLE_NONE;
  vx_call call = {.wr_bytes = &m,
                  .wr_len = sizeof m,
                  .rd_bytes = &rep,
                  .rd_cap = sizeof rep,
                  .rd_handles = out,
                  .rd_count_cap = 1};
  vx_status st =
      devmgr ? vx_channel_call(devmgr, &call, vx_clock_read() + 5'000'000'000) : VX_ERR_PEER_CLOSED;
  if (st == VX_OK && rep.flags) st = (vx_status)(int32_t)rep.flags;
  if (st == VX_OK && call.actual.handles != 1) st = VX_ERR_INVALID;
  if (st != VX_OK && *out) vx_handle_close(*out), *out = VX_HANDLE_NONE;
  return st;
}

typedef struct mapped {
  uint64_t base, size; // physical, page-aligned
  uint8_t *at;
} mapped;
static mapped maps[64];
static uint32_t nmaps;

// Physical memory [where, where + length), mapped: devmgr's VMO, kept.
static void *map_physical(uint64_t where, uint64_t length) {
  for (uint32_t i = 0; i < nmaps; i++)
    if (where >= maps[i].base && where + length <= maps[i].base + maps[i].size)
      return maps[i].at + (where - maps[i].base);
  uint64_t base = where & ~4095ull, end = (where + length + 4095) & ~4095ull;
  vx_handle vmo;
  uint64_t at = 0;
  vx_status st = nmaps < 64 ? ask(VX_ACPI_MEMORY, base, end - base, &vmo) : VX_ERR_NO_MEMORY;
  if (st == VX_OK) {
    st = vx_as_map(vx_self, vmo, 0, end - base, VX_MAP_WRITE, &at);
    vx_handle_close(vmo);
  }
  if (st != VX_OK) {
    said_once("memory", where, st);
    return nullptr;
  }
  maps[nmaps++] = (mapped){base, end - base, (uint8_t *)at};
  return (uint8_t *)at + (where - base);
}

void *AcpiOsMapMemory(ACPI_PHYSICAL_ADDRESS Where, ACPI_SIZE Length) {
  if (Where >= TABLES_AT && Where + Length <= TABLES_AT + sizeof roots) return roots + (Where - TABLES_AT);
  if (Where >= COPIES_AT && Where - COPIES_AT <= copies_size && Length <= copies_size - (Where - COPIES_AT))
    return copies + (Where - COPIES_AT);
  return map_physical(Where, Length);
}

void AcpiOsUnmapMemory(void *LogicalAddress, ACPI_SIZE Size) { (void)LogicalAddress, (void)Size; } // kept

static uint64_t load(const volatile void *p, uint32_t width) {
  switch (width) {
  case 8: return *(const volatile uint8_t *)p;
  case 16: return *(const volatile uint16_t *)p;
  case 32: return *(const volatile uint32_t *)p;
  default: return *(const volatile uint64_t *)p;
  }
}

static void store(volatile void *p, uint64_t v, uint32_t width) {
  switch (width) {
  case 8: *(volatile uint8_t *)p = (uint8_t)v; break;
  case 16: *(volatile uint16_t *)p = (uint16_t)v; break;
  case 32: *(volatile uint32_t *)p = (uint32_t)v; break;
  default: *(volatile uint64_t *)p = v; break;
  }
}

ACPI_STATUS AcpiOsReadMemory(ACPI_PHYSICAL_ADDRESS Address, UINT64 *Value, UINT32 Width) {
  void *p = AcpiOsMapMemory(Address, Width / 8);
  *Value = p ? load(p, Width) : 0;
  return p ? AE_OK : AE_NOT_EXIST;
}

ACPI_STATUS AcpiOsWriteMemory(ACPI_PHYSICAL_ADDRESS Address, UINT64 Value, UINT32 Width) {
  void *p = AcpiOsMapMemory(Address, Width / 8);
  if (p) store(p, Value, Width);
  return p ? AE_OK : AE_NOT_EXIST;
}

// I/O ports (x86_64): the ranges devmgr gave, each mapped into this task.
static range_t ports[64];
static uint32_t nports;

[[maybe_unused]] static bool have_ports(uint64_t base, uint64_t count) { // x86_64's
  for (uint32_t i = 0; i < nports; i++)
    if (base >= ports[i].base && base + count <= ports[i].base + ports[i].size) return true;
  vx_handle io;
  uint64_t ignored = 0;
  vx_status st = nports < 64 ? ask(VX_ACPI_IO, base, count, &io) : VX_ERR_NO_MEMORY;
  if (st == VX_OK) st = vx_as_map(vx_self, io, 0, 0, 0, &ignored); // kept: the mapping holds it
  if (st != VX_OK) {
    said_once("I/O port", base, st);
    return false;
  }
  ports[nports++] = (range_t){base, count};
  return true;
}

ACPI_STATUS AcpiOsReadPort(ACPI_IO_ADDRESS Address, UINT32 *Value, UINT32 Width) {
  *Value = 0xffff'ffff;
#ifdef __x86_64__
  if (!have_ports(Address, Width / 8)) return AE_NOT_EXIST;
  uint16_t port = (uint16_t)Address;
  if (Width == 8) {
    uint8_t v;
    __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
    *Value = v;
  } else if (Width == 16) {
    uint16_t v;
    __asm__ volatile("inw %1, %0" : "=a"(v) : "Nd"(port));
    *Value = v;
  } else {
    uint32_t v;
    __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(port));
    *Value = v;
  }
  return AE_OK;
#else
  (void)Width;
  said_once("I/O port", Address, VX_ERR_UNSUPPORTED);
  return AE_NOT_EXIST;
#endif
}

ACPI_STATUS AcpiOsWritePort(ACPI_IO_ADDRESS Address, UINT32 Value, UINT32 Width) {
#ifdef __x86_64__
  if (!have_ports(Address, Width / 8)) return AE_NOT_EXIST;
  uint16_t port = (uint16_t)Address;
  if (Width == 8)
    __asm__ volatile("outb %0, %1" : : "a"((uint8_t)Value), "Nd"(port));
  else if (Width == 16)
    __asm__ volatile("outw %0, %1" : : "a"((uint16_t)Value), "Nd"(port));
  else
    __asm__ volatile("outl %0, %1" : : "a"(Value), "Nd"(port));
  return AE_OK;
#else
  (void)Value, (void)Width;
  said_once("I/O port", Address, VX_ERR_UNSUPPORTED);
  return AE_NOT_EXIST;
#endif
}

// PCI configuration space: a function's 4 KiB of ECAM, kept.
typedef struct config {
  uint32_t id; // segment << 16 | requester ID
  volatile uint8_t *at;
} config;
static config configs[64];
static uint32_t nconfigs;

static volatile uint8_t *config_of(const ACPI_PCI_ID *PciId) {
  uint32_t id = (uint32_t)PciId->Segment << 16 | (uint32_t)PciId->Bus << 8 | (uint32_t)PciId->Device << 3 |
                PciId->Function;
  for (uint32_t i = 0; i < nconfigs; i++)
    if (configs[i].id == id) return configs[i].at;
  vx_handle vmo;
  uint64_t at = 0;
  vx_status st = nconfigs < 64 ? ask(VX_ACPI_PCI, id, 4096, &vmo) : VX_ERR_NO_MEMORY;
  if (st == VX_OK) {
    st = vx_as_map(vx_self, vmo, 0, 4096, VX_MAP_WRITE, &at);
    vx_handle_close(vmo);
  }
  if (st != VX_OK) {
    said_once("PCI configuration for", id, st);
    return nullptr;
  }
  configs[nconfigs++] = (config){id, (volatile uint8_t *)at};
  return (volatile uint8_t *)at;
}

ACPI_STATUS AcpiOsReadPciConfiguration(ACPI_PCI_ID *PciId, UINT32 Reg, UINT64 *Value, UINT32 Width) {
  volatile uint8_t *c = Reg + Width / 8 <= 4096 ? config_of(PciId) : nullptr;
  *Value = c ? load(c + Reg, Width) : ~0ull;
  return c ? AE_OK : AE_NOT_EXIST;
}

ACPI_STATUS AcpiOsWritePciConfiguration(ACPI_PCI_ID *PciId, UINT32 Reg, UINT64 Value, UINT32 Width) {
  volatile uint8_t *c = Reg + Width / 8 <= 4096 ? config_of(PciId) : nullptr;
  if (c) store(c + Reg, Value, Width);
  return c ? AE_OK : AE_NOT_EXIST;
}

// --- Power (M5 step 7c) ---

// The machine off: S5 through ACPICA where the firmware has it (_S5, and
// the fixed hardware's sleep registers); else, as on a hardware-reduced
// firmware with no sleep registers (QEMU's aarch64), PSCI, which devmgr
// asks the kernel for. Returns only if the machine is still on.
static vx_status power_off(void) {
  vx_print(VX_STR("bus-acpi: powering off\n"));
  AcpiOsSleep(1000); // what the console has, out first: power off does not wait for it
  UINT8 a, b;
  if (!AcpiGbl_ReducedHardware && ACPI_SUCCESS(AcpiGetSleepTypeData(ACPI_STATE_S5, &a, &b))) {
    vx_print(VX_STR("bus-acpi: S5\n"));
    if (ACPI_SUCCESS(AcpiEnterSleepStatePrep(ACPI_STATE_S5))) AcpiEnterSleepState(ACPI_STATE_S5);
    vx_print(VX_STR("bus-acpi: S5 did not power off; PSCI then\n"));
  }
  vx_print(VX_STR("bus-acpi: PSCI, through devmgr\n"));
  vx_handle h;
  vx_status st = ask(VX_ACPI_OFF, 0, 0, &h);
  return st == VX_OK ? VX_ERR_IO : st;
}

// /srv/acpi: one request a message, by channel_call (lib/vx-acpi/mint.h).
static void serve(vx_handle listen, vx_handle port) {
  for (;;) {
    vx_port_bind(port, listen, VX_TRIGGER_READABLE, 1, 0);
    vx_packet pk;
    if (vx_port_wait(port, VX_INFINITE, 0, &pk, 1) != 1) continue;
    vx_msg_header req;
    vx_msg_size got;
    while (vx_channel_read(listen, &req, sizeof req, nullptr, 0, &got) == VX_OK) {
      vx_status st =
          got.bytes == sizeof req && req.ordinal == VX_ACPI_POWER_OFF ? power_off() : VX_ERR_INVALID;
      vx_msg_header rep = {.txid = req.txid, .ordinal = req.ordinal, .flags = (uint32_t)(int32_t)st};
      vx_channel_write(listen, &rep, sizeof rep, nullptr, 0);
    }
  }
}

// bus-acpi.probe=1 on the command line: asks devmgr for what it must refuse
// (the interrupt controller's page, RAM, the console's ports) and says what
// it got (the acpi scenarios check it).
static void probe(void) {
  vx_str c = vx_spawn.cmdline;
  static const char key[] = "bus-acpi.probe=1";
  bool asked = false;
  for (size_t i = 0; i + sizeof key - 1 <= c.len; i++)
    asked = asked || ((!i || c.ptr[i - 1] == ' ') && memcmp(c.ptr + i, key, sizeof key - 1) == 0);
  if (!asked) return;
#ifdef __x86_64__
  uint64_t controller = 0xfee0'0000, ram = 0x10'0000; // the local APIC; the first MiB past the BIOS's
#else
  uint64_t controller = 0x0800'0000, ram = 0x4000'0000; // QEMU virt's GIC distributor; its RAM
#endif
  vx_handle h;
  vx_status a = ask(VX_ACPI_MEMORY, controller, 4096, &h), b = ask(VX_ACPI_MEMORY, ram, 4096, &h),
            p = ask(VX_ACPI_IO, 0x3f8, 8, &h);
  char line[160];
  int n = snprintf(
      line, sizeof line, "bus-acpi: probe: the interrupt controller %s, RAM %s, the console's ports %s\n",
      a == VX_OK ? "given" : "refused", b == VX_OK ? "given" : "refused", p == VX_OK ? "given" : "refused");
  vx_print((vx_str){line, n > 0 && (size_t)n < sizeof line ? (size_t)n : 0});
}

// --- One thread: locks, semaphores, threads, time ---

ACPI_STATUS AcpiOsInitialize(void) { return AE_OK; }
ACPI_STATUS AcpiOsTerminate(void) { return AE_OK; }

ACPI_STATUS AcpiOsCreateLock(ACPI_SPINLOCK *OutHandle) {
  static int lock;
  *OutHandle = &lock;
  return AE_OK;
}
void AcpiOsDeleteLock(ACPI_SPINLOCK Handle) { (void)Handle; }
ACPI_CPU_FLAGS AcpiOsAcquireLock(ACPI_SPINLOCK Handle) {
  (void)Handle;
  return 0;
}
void AcpiOsReleaseLock(ACPI_SPINLOCK Handle, ACPI_CPU_FLAGS Flags) { (void)Handle, (void)Flags; }

ACPI_STATUS AcpiOsCreateSemaphore(UINT32 MaxUnits, UINT32 InitialUnits, ACPI_SEMAPHORE *OutHandle) {
  (void)MaxUnits;
  UINT32 *count = AcpiOsAllocate(sizeof *count);
  if (!count) return AE_NO_MEMORY;
  *count = InitialUnits;
  *OutHandle = count;
  return AE_OK;
}

ACPI_STATUS AcpiOsDeleteSemaphore(ACPI_SEMAPHORE Handle) {
  AcpiOsFree(Handle);
  return AE_OK;
}

ACPI_STATUS AcpiOsWaitSemaphore(ACPI_SEMAPHORE Handle, UINT32 Units, UINT16 Timeout) {
  (void)Timeout; // one thread: what is not there now never comes
  UINT32 *count = Handle;
  if (*count < Units) return AE_TIME;
  *count -= Units;
  return AE_OK;
}

ACPI_STATUS AcpiOsSignalSemaphore(ACPI_SEMAPHORE Handle, UINT32 Units) {
  *(UINT32 *)Handle += Units;
  return AE_OK;
}

ACPI_THREAD_ID AcpiOsGetThreadId(void) { return 1; }

ACPI_STATUS AcpiOsExecute(ACPI_EXECUTE_TYPE Type, ACPI_OSD_EXEC_CALLBACK Function, void *Context) {
  (void)Type;
  Function(Context); // at once: there is no other thread to give it to
  return AE_OK;
}

void AcpiOsWaitEventsComplete(void) {}

void AcpiOsSleep(UINT64 Milliseconds) {
  static _Atomic uint32_t never;
  vx_futex_wait(&never, 0, vx_clock_read() + (vx_instant)Milliseconds * 1'000'000);
}

void AcpiOsStall(UINT32 Microseconds) {
  vx_instant until = vx_clock_read() + (vx_instant)Microseconds * 1000;
  while (vx_clock_read() < until) {}
}

UINT64 AcpiOsGetTimer(void) { return (UINT64)vx_clock_read() / 100; } // 100 ns units

ACPI_STATUS AcpiOsInstallInterruptHandler(UINT32 InterruptNumber, ACPI_OSD_HANDLER ServiceRoutine,
                                          void *Context) {
  (void)InterruptNumber, (void)ServiceRoutine, (void)Context; // the SCI: no events yet
  return AE_OK;
}

ACPI_STATUS AcpiOsRemoveInterruptHandler(UINT32 InterruptNumber, ACPI_OSD_HANDLER ServiceRoutine) {
  (void)InterruptNumber, (void)ServiceRoutine;
  return AE_OK;
}

ACPI_STATUS AcpiOsSignal(UINT32 Function, void *Info) {
  (void)Function, (void)Info;
  return AE_OK;
}

ACPI_STATUS AcpiOsEnterSleep(UINT8 SleepState, UINT32 RegaValue, UINT32 RegbValue) {
  (void)SleepState, (void)RegaValue, (void)RegbValue;
  return AE_OK;
}

ACPI_STATUS AcpiOsPredefinedOverride(const ACPI_PREDEFINED_NAMES *InitVal, ACPI_STRING *NewVal) {
  (void)InitVal;
  *NewVal = nullptr;
  return AE_OK;
}

ACPI_STATUS AcpiOsTableOverride(ACPI_TABLE_HEADER *ExistingTable, ACPI_TABLE_HEADER **NewTable) {
  (void)ExistingTable;
  *NewTable = nullptr;
  return AE_OK;
}

ACPI_STATUS AcpiOsPhysicalTableOverride(ACPI_TABLE_HEADER *ExistingTable, ACPI_PHYSICAL_ADDRESS *NewAddress,
                                        UINT32 *NewTableLength) {
  (void)ExistingTable;
  *NewAddress = 0, *NewTableLength = 0;
  return AE_OK;
}

// --- Output ---

void AcpiOsVprintf(const char *Format, va_list Args) {
  char buf[256];
  int n = vsnprintf(buf, sizeof buf, Format, Args);
  if (n > 0) vx_print((vx_str){buf, (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1});
}

void ACPI_INTERNAL_VAR_XFACE AcpiOsPrintf(const char *Format, ...) {
  va_list args;
  va_start(args, Format);
  AcpiOsVprintf(Format, args);
  va_end(args);
}

// --- The devices ---

static uint32_t devices, present;

static void add_res(vx_acpi_device *d, uint32_t kind, uint64_t base, uint64_t size) {
  if (d->count < VX_ACPI_MAX_RES)
    d->res[d->count++] = (vx_acpi_res){.kind = kind, .base = base, .size = size};
}

// One _CRS resource: said, and added to the device's report (ctx).
static ACPI_STATUS print_resource(ACPI_RESOURCE *r, void *ctx) {
  vx_acpi_device *d = ctx;
  char buf[64];
  int n = 0;
  switch (r->Type) {
  case ACPI_RESOURCE_TYPE_IO:
    if (r->Data.Io.AddressLength) {
      n = snprintf(buf, sizeof buf, " io=0x%x/%u", r->Data.Io.Minimum, r->Data.Io.AddressLength);
      add_res(d, VX_ACPI_RES_IO, r->Data.Io.Minimum, r->Data.Io.AddressLength);
    }
    break;
  case ACPI_RESOURCE_TYPE_FIXED_IO:
    n = snprintf(buf, sizeof buf, " io=0x%x/%u", r->Data.FixedIo.Address, r->Data.FixedIo.AddressLength);
    add_res(d, VX_ACPI_RES_IO, r->Data.FixedIo.Address, r->Data.FixedIo.AddressLength);
    break;
  case ACPI_RESOURCE_TYPE_MEMORY32:
    n = snprintf(buf, sizeof buf, " mem=0x%x/0x%x", r->Data.Memory32.Minimum, r->Data.Memory32.AddressLength);
    add_res(d, VX_ACPI_RES_MEMORY, r->Data.Memory32.Minimum, r->Data.Memory32.AddressLength);
    break;
  case ACPI_RESOURCE_TYPE_FIXED_MEMORY32:
    n = snprintf(buf, sizeof buf, " mem=0x%x/0x%x", r->Data.FixedMemory32.Address,
                 r->Data.FixedMemory32.AddressLength);
    add_res(d, VX_ACPI_RES_MEMORY, r->Data.FixedMemory32.Address, r->Data.FixedMemory32.AddressLength);
    break;
  case ACPI_RESOURCE_TYPE_IRQ: // the first line: a device with a choice of lines takes it
    if (r->Data.Irq.InterruptCount) {
      n = snprintf(buf, sizeof buf, " irq=%u", r->Data.Irq.Interrupts[0]);
      add_res(d, VX_ACPI_RES_IRQ, r->Data.Irq.Interrupts[0], 1);
    }
    break;
  case ACPI_RESOURCE_TYPE_EXTENDED_IRQ:
    if (r->Data.ExtendedIrq.InterruptCount) {
      n = snprintf(buf, sizeof buf, " irq=%u", r->Data.ExtendedIrq.Interrupts[0]);
      add_res(d, VX_ACPI_RES_IRQ, r->Data.ExtendedIrq.Interrupts[0], 1);
    }
    break;
  default: break;
  }
  if (n > 0) vx_print((vx_str){buf, (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1});
  return AE_OK;
}

// A device's _STA: present unless it says not (one without _STA is present).
static bool is_present(ACPI_HANDLE dev) {
  ACPI_OBJECT obj;
  ACPI_BUFFER out = {.Length = sizeof obj, .Pointer = &obj};
  ACPI_STATUS st = AcpiEvaluateObject(dev, (ACPI_STRING) "_STA", nullptr, &out);
  if (st == AE_NOT_FOUND) return true;
  return ACPI_SUCCESS(st) && obj.Type == ACPI_TYPE_INTEGER && (obj.Integer.Value & ACPI_STA_DEVICE_PRESENT);
}

static ACPI_STATUS print_device(ACPI_HANDLE dev, UINT32 depth, void *ctx, void **ret) {
  (void)depth, (void)ctx, (void)ret;
  devices++;
  ACPI_DEVICE_INFO *info = nullptr;
  if (ACPI_FAILURE(AcpiGetObjectInfo(dev, &info))) return AE_OK;
  bool here = is_present(dev);
  if (here && (info->Valid & ACPI_VALID_HID)) {
    present++;
    char path[128] = "";
    ACPI_BUFFER name = {.Length = sizeof path, .Pointer = path};
    vx_print(VX_STR("bus-acpi: "));
    if (ACPI_SUCCESS(AcpiGetName(dev, ACPI_FULL_PATHNAME_NO_TRAILING, &name))) vx_print(vx_cstr(path));
    vx_print(VX_STR(" "));
    vx_print(vx_cstr(info->HardwareId.String));
    vx_acpi_device d = {.h = {.ordinal = VX_ACPI_DEVICE}};
    strncpy(d.hid, info->HardwareId.String, sizeof d.hid - 1);
    strncpy(d.path, path, sizeof d.path - 1);
    AcpiWalkResources(dev, METHOD_NAME__CRS, print_resource, &d);
    vx_print(VX_STR("\n"));
    if (devmgr) vx_channel_write(devmgr, &d, sizeof d, nullptr, 0); // devmgr matches it to a driver
  }
  AcpiOsFree(info);
  return AE_OK;
}

[[noreturn]] static void fail(const char *what, ACPI_STATUS st) {
  vx_print(VX_STR("bus-acpi: FAILED: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(AcpiFormatException(st)));
  vx_print(VX_STR("\n"));
  vx_exits(what);
}

const char *vx_main(void) {
  vx_handle acpi = vx_spawn_take("acpi"), heapvmo;
  devmgr = vx_spawn_take("devmgr");
  vx_ndb_record rec;
  uint64_t size = 0, at = 0, hat = 0;
  if (!acpi || !vx_spawn_record("acpi", &rec) || !vx_ndb_get_u64(&rec, "size", &size) || !size ||
      vx_as_map(vx_self, acpi, 0, (size + 4095) & ~4095ull, 0, &at) != VX_OK)
    fail("no ACPI tables", AE_NOT_FOUND);
  if (vx_vmo_create(HEAP_BYTES, 0, &heapvmo) != VX_OK ||
      vx_as_map(vx_self, heapvmo, 0, HEAP_BYTES, VX_MAP_WRITE, &hat) != VX_OK)
    fail("no memory", AE_NO_MEMORY);
  heap = heap_top = (uint8_t *)hat;
  copies_size = size;
  if (!(copies = AcpiOsAllocate(size))) fail("no memory for the tables", AE_NO_MEMORY);
  memcpy(copies, (const void *)at, size);
  if (!lay_out_tables()) fail("malformed tables", AE_BAD_DATA);

  probe();
  ACPI_STATUS st = AcpiInitializeSubsystem();
  if (ACPI_FAILURE(st)) fail("AcpiInitializeSubsystem", st);
  if (ACPI_FAILURE(st = AcpiInitializeTables(nullptr, 32, FALSE))) fail("AcpiInitializeTables", st);
  if (ACPI_FAILURE(st = AcpiLoadTables())) fail("AcpiLoadTables", st);
  // The hardware on too (ACPI mode, its fixed registers, its events), all
  // reached through devmgr's grants. Events are set up but not delivered:
  // there is no SCI handler yet.
  if (ACPI_FAILURE(st = AcpiEnableSubsystem(ACPI_FULL_INITIALIZATION))) fail("AcpiEnableSubsystem", st);
  if (ACPI_FAILURE(st = AcpiInitializeObjects(ACPI_FULL_INITIALIZATION))) fail("AcpiInitializeObjects", st);
  AcpiGetDevices(nullptr, print_device, nullptr, nullptr);
  vx_print(VX_STR("bus-acpi: "));
  vx_print_u64(devices);
  vx_print(VX_STR(" devices, "));
  vx_print_u64(present);
  vx_print(VX_STR(" present with a hardware ID; "));
  vx_print_u64((uint64_t)(heap_top - heap) >> 10);
  vx_print(VX_STR(" KiB of heap\n"));
  vx_handle port, listen = vx_spawn_take("listen");
  vx_port_create(0, &port);
  if (listen) {
    vx_print(VX_STR("bus-acpi: serving /srv/acpi\n"));
    serve(listen, port);
  }
  for (;;) { // no post: nothing to serve
    vx_packet pk;
    vx_port_wait(port, VX_INFINITE, 0, &pk, 1);
  }
}
