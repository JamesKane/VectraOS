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

static void said_once(const char *what, uint64_t at) { // a refused region, port or PCI access
  static uint64_t seen[32];
  static uint32_t nseen;
  for (uint32_t i = 0; i < nseen; i++)
    if (seen[i] == at) return;
  if (nseen < 32) seen[nseen++] = at;
  vx_print(VX_STR("bus-acpi: no "));
  vx_print(vx_cstr(what));
  char hex[24];
  int n = snprintf(hex, sizeof hex, " at 0x%llx", (unsigned long long)at);
  vx_print((vx_str){hex, n > 0 ? (size_t)n : 0});
  vx_print(VX_STR(" yet (M5 step 7b)\n"));
}

void *AcpiOsMapMemory(ACPI_PHYSICAL_ADDRESS Where, ACPI_SIZE Length) {
  if (Where >= TABLES_AT && Where + Length <= TABLES_AT + sizeof roots) return roots + (Where - TABLES_AT);
  if (Where >= COPIES_AT && Where - COPIES_AT <= copies_size && Length <= copies_size - (Where - COPIES_AT))
    return copies + (Where - COPIES_AT);
  said_once("memory", Where);
  return nullptr;
}

void AcpiOsUnmapMemory(void *LogicalAddress, ACPI_SIZE Size) { (void)LogicalAddress, (void)Size; }

ACPI_STATUS AcpiOsReadMemory(ACPI_PHYSICAL_ADDRESS Address, UINT64 *Value, UINT32 Width) {
  (void)Width;
  said_once("memory", Address);
  *Value = 0;
  return AE_SUPPORT;
}

ACPI_STATUS AcpiOsWriteMemory(ACPI_PHYSICAL_ADDRESS Address, UINT64 Value, UINT32 Width) {
  (void)Value, (void)Width;
  said_once("memory", Address);
  return AE_SUPPORT;
}

ACPI_STATUS AcpiOsReadPort(ACPI_IO_ADDRESS Address, UINT32 *Value, UINT32 Width) {
  (void)Width;
  said_once("I/O port", Address);
  *Value = 0xffff'ffff;
  return AE_SUPPORT;
}

ACPI_STATUS AcpiOsWritePort(ACPI_IO_ADDRESS Address, UINT32 Value, UINT32 Width) {
  (void)Value, (void)Width;
  said_once("I/O port", Address);
  return AE_SUPPORT;
}

ACPI_STATUS AcpiOsReadPciConfiguration(ACPI_PCI_ID *PciId, UINT32 Reg, UINT64 *Value, UINT32 Width) {
  (void)Width;
  said_once("PCI configuration",
            (uint64_t)PciId->Bus << 16 | PciId->Device << 8 | PciId->Function | (uint64_t)Reg << 24);
  *Value = ~0ull;
  return AE_SUPPORT;
}

ACPI_STATUS AcpiOsWritePciConfiguration(ACPI_PCI_ID *PciId, UINT32 Reg, UINT64 Value, UINT32 Width) {
  (void)Value, (void)Width;
  said_once("PCI configuration",
            (uint64_t)PciId->Bus << 16 | PciId->Device << 8 | PciId->Function | (uint64_t)Reg << 24);
  return AE_SUPPORT;
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

static ACPI_STATUS print_resource(ACPI_RESOURCE *r, void *ctx) {
  (void)ctx;
  char buf[64];
  int n = 0;
  switch (r->Type) {
  case ACPI_RESOURCE_TYPE_IO:
    if (r->Data.Io.AddressLength)
      n = snprintf(buf, sizeof buf, " io=0x%x/%u", r->Data.Io.Minimum, r->Data.Io.AddressLength);
    break;
  case ACPI_RESOURCE_TYPE_FIXED_IO:
    n = snprintf(buf, sizeof buf, " io=0x%x/%u", r->Data.FixedIo.Address, r->Data.FixedIo.AddressLength);
    break;
  case ACPI_RESOURCE_TYPE_MEMORY32:
    n = snprintf(buf, sizeof buf, " mem=0x%x/0x%x", r->Data.Memory32.Minimum, r->Data.Memory32.AddressLength);
    break;
  case ACPI_RESOURCE_TYPE_FIXED_MEMORY32:
    n = snprintf(buf, sizeof buf, " mem=0x%x/0x%x", r->Data.FixedMemory32.Address,
                 r->Data.FixedMemory32.AddressLength);
    break;
  case ACPI_RESOURCE_TYPE_IRQ:
    if (r->Data.Irq.InterruptCount) n = snprintf(buf, sizeof buf, " irq=%u", r->Data.Irq.Interrupts[0]);
    break;
  case ACPI_RESOURCE_TYPE_EXTENDED_IRQ:
    if (r->Data.ExtendedIrq.InterruptCount)
      n = snprintf(buf, sizeof buf, " irq=%u", r->Data.ExtendedIrq.Interrupts[0]);
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
    char path[128];
    ACPI_BUFFER name = {.Length = sizeof path, .Pointer = path};
    vx_print(VX_STR("bus-acpi: "));
    if (ACPI_SUCCESS(AcpiGetName(dev, ACPI_FULL_PATHNAME_NO_TRAILING, &name))) vx_print(vx_cstr(path));
    vx_print(VX_STR(" "));
    vx_print(vx_cstr(info->HardwareId.String));
    AcpiWalkResources(dev, METHOD_NAME__CRS, print_resource, nullptr);
    vx_print(VX_STR("\n"));
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

  ACPI_STATUS st = AcpiInitializeSubsystem();
  if (ACPI_FAILURE(st)) fail("AcpiInitializeSubsystem", st);
  if (ACPI_FAILURE(st = AcpiInitializeTables(nullptr, 32, FALSE))) fail("AcpiInitializeTables", st);
  if (ACPI_FAILURE(st = AcpiLoadTables())) fail("AcpiLoadTables", st);
  // No hardware yet (its registers come with step 7b): the namespace, run.
  if (ACPI_FAILURE(st = AcpiEnableSubsystem(ACPI_NO_HARDWARE_INIT | ACPI_NO_ACPI_ENABLE | ACPI_NO_EVENT_INIT |
                                            ACPI_NO_HANDLER_INIT)))
    fail("AcpiEnableSubsystem", st);
  if (ACPI_FAILURE(st = AcpiInitializeObjects(ACPI_FULL_INITIALIZATION))) fail("AcpiInitializeObjects", st);
  AcpiGetDevices(nullptr, print_device, nullptr, nullptr);
  vx_print(VX_STR("bus-acpi: "));
  vx_print_u64(devices);
  vx_print(VX_STR(" devices, "));
  vx_print_u64(present);
  vx_print(VX_STR(" present with a hardware ID; "));
  vx_print_u64((uint64_t)(heap_top - heap) >> 10);
  vx_print(VX_STR(" KiB of heap\n"));
  vx_handle port;
  vx_port_create(0, &port);
  for (;;) { // its service comes with the next steps
    vx_packet pk;
    vx_port_wait(port, VX_INFINITE, 0, &pk, 1);
  }
}
