// Interrupt objects (K9c): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's values
// (zircon/types.h, syscalls/port.h), plus croi's affinity call.
//
// An interrupt's number is its GSI on amd64 (IOAPIC pins; with REMAP_IRQ,
// an ISA IRQ the MADT's overrides map), its INTID on arm64 (GICv3 SPIs,
// 32 and up) and its GSI on rv64 (PLIC sources). interrupt_create needs an
// IRQ resource covering it. A bound port is the one way to wait for it,
// and closing its last handle destroys it: V1 cut interrupt_wait,
// interrupt_destroy and virtual interrupts (interrupt_trigger; a counter
// is one), D29.
//
// interrupt_set_affinity(interrupt, cpu mask) routes it to one CPU of the
// mask (the lowest-numbered one taking interrupts); until it is called,
// to the boot CPU. Statuses: INVALID_ARGS (no CPU of the mask takes
// interrupts), NOT_SUPPORTED (plain MSI, or a CPU the controller can't
// target), ACCESS_DENIED (no WRITE right).
//
// MSI (K9d, Zircon's calls): msi_allocate(MSI system resource, count: a
// power of two up to 32) gives an allocation (object type 32) of
// contiguous vectors on the boot CPU; object_get_info(CROI_INFO_MSI) says
// what the device must write. msi_create(allocation, options, id, vmo,
// offset) makes interrupt object `id` of it: with CROI_MSI_MODE_MSI_X,
// `vmo` holds the MSI-X table at `offset` and the kernel programs and
// masks entry `id` (and moves it to another CPU on set_affinity);
// without, `vmo` is the function's config space with the MSI capability
// at `offset`, which the driver programs from the info (the kernel only
// masks through per-vector masking if the capability has it). The VMO
// must be physical and uncached. arm64 needs the ITS, rv64 the IMSICs:
// NOT_SUPPORTED without them.
//
// MSI frames (croi's, D156): msi_allocate(MSI system resource, 0, out,
// desc, desc_size), count 0, gives the kernel a block outside the interrupt controller
// that latches the vector a device writes to its target address and
// raises one wired interrupt for them all: DesignWare PCIe's integrated
// MSI receiver (CROI_MSI_FRAME_DWC: 8 groups of 32 vectors, each group's
// enable, mask and status registers 12 bytes apart after the target
// address's two). The kernel programs the target, owns the wired number
// from then on, and fires the vectors' interrupt objects from it.
// msi_allocate given the frame (object type 64) instead of the resource
// allocates its vectors; msi_create, info and masking are as above, the
// message the frame's target and the vector's number, and set_affinity
// is NOT_SUPPORTED (the wired number moves them all). A frame lasts until
// the kernel restarts.
#pragma once
#include <stdint.h>

enum : uint32_t {
  // interrupt_create options.
  CROI_INTERRUPT_REMAP_IRQ = 0x1,
  CROI_INTERRUPT_MODE_DEFAULT = 0u << 1,  // what firmware says (amd64: MADT overrides,
                                          // else ISA edge-high, PCI level-low)
  CROI_INTERRUPT_MODE_EDGE_LOW = 1u << 1,
  CROI_INTERRUPT_MODE_EDGE_HIGH = 2u << 1,
  CROI_INTERRUPT_MODE_LEVEL_LOW = 3u << 1,
  CROI_INTERRUPT_MODE_LEVEL_HIGH = 4u << 1,
  CROI_INTERRUPT_MODE_EDGE_BOTH = 5u << 1,  // NOT_SUPPORTED
  CROI_INTERRUPT_MODE_MASK = 0xe,
  CROI_INTERRUPT_TIMESTAMP_MONO = 1u << 6,  // accepted: croi's boot time is monotonic time

  // port_create option: the port may be bound to interrupts (object_bind
  // INTERRUPT, port.h; port_cancel unbinds).
  CROI_PORT_BIND_TO_INTERRUPT = 1,

  // Port packet type: payload[0] is the timestamp (ns).
  CROI_PKT_TYPE_INTERRUPT = 7,

  // msi_create options.
  CROI_MSI_MODE_MSI_X = 1,

  // object_get_info topic on an MSI allocation.
  CROI_INFO_MSI = 28,

  // MSI frame kinds.
  CROI_MSI_FRAME_DWC = 1,
};

// An MSI frame's descriptor (msi_allocate with count 0).
typedef struct {
  uint32_t kind;        // CROI_MSI_FRAME_DWC
  uint32_t irq;         // an IRQ resource covering `number`
  uint32_t number;      // the wired interrupt the frame raises (level, active high)
  uint32_t vmo;         // physical and uncached, over the frame's registers (MAP)
  uint64_t vmo_offset;  // its first register: DWC's PCIE_MSI_ADDR_LO
  uint64_t target;      // the bus address devices write a vector's number to
} croi_msi_frame_desc_t;

_Static_assert(sizeof(croi_msi_frame_desc_t) == 32);

// zx_info_msi_t.
typedef struct {
  // The device writes target_data + n for id n to target_addr. With
  // interrupt remapping (amd64 VT-d, K12f) the address is in the
  // remappable format (bit 4) naming the kernel's entry for id 0 and the
  // data is 0; else the compatibility format with the vector as data.
  uint64_t target_addr;      // the address the device writes
  uint32_t target_data;      // the data for id 0; id n writes target_data + n
  uint32_t base_irq_id;      // the first vector
  uint32_t num_irq;
  uint32_t interrupt_count;  // ids with an interrupt object
} croi_info_msi_t;

_Static_assert(sizeof(croi_info_msi_t) == 24);

// interrupt_ack(croi_interrupt_ack_item_t *items, count) (D40) re-arms
// each item's bound interrupt (WRITE): an IRQ thread serving several
// vectors acks the ones it has handled at once. As counter_add, it goes
// on past an item that fails, writes each item's status back, and returns
// how many succeeded; a bad pointer or count fails the whole call first.
// croi_interrupt_ack in syscall.h is the one-interrupt form.
enum : uint32_t { CROI_INTERRUPT_ACK_MAX_ITEMS = 64 };

typedef struct {
  uint32_t interrupt;  // the interrupt's handle
  int32_t status;      // out: 0, or why this item failed
} croi_interrupt_ack_item_t;

_Static_assert(sizeof(croi_interrupt_ack_item_t) == 8);
