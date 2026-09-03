/*
virtio-blk over modern PCI: a disk the machine can read and write.

virtio is the one device model QEMU speaks on every board this kernel runs
on. A `virtio-blk-pci` function is a block device whose registers are found
through PCI capabilities and whose requests travel through a *virtqueue*: a
ring of descriptors in memory the driver fills and the device drains. One
transport, one driver, and the same code on amd64, arm64 and riscv64,
because what differs between the boards -- how configuration space is
reached -- `kernel/drivers/pci` already hid.

## Modern, not legacy

The 1.0 ("modern") layout only. A capability of type `COMMON_CFG` points at
the control registers, `NOTIFY_CFG` at the doorbell, `ISR_CFG` at the
interrupt-cause byte, and `DEVICE_CFG` at the block-specific registers where
the capacity is. Legacy virtio put these in a BAR's I/O ports with a fixed
layout; nothing here reads that, because QEMU's `virtio-blk-pci` is modern
by default and the boards have no legacy path.

## One request at a time, polled

A request is three descriptors: a header the device reads, a data buffer it
reads or writes, and a status byte it writes. The driver puts them in the
ring, rings the doorbell, and spins on the used ring until the device hands
the chain back. Nothing else on the core has anything to do while a boot
waits for its disk, so a poll is the whole mechanism and an interrupt is the
optimisation `docs/SHELL.md` names for the day a second thread does.

`request` holds a lock for the whole exchange: the queue is size one as far
as this driver drives it, and two callers must not fill the same descriptors.
The lock is a spinlock and the poll does not sleep, so a disk read may be
issued from anywhere, including a device handler that already holds one.
*/
package virtio

import "base:intrinsics"

import "kernel:arch"
import "kernel:drivers/pci"
import "kernel:mem"
import "kernel:sync"

// -- PCI identity ------------------------------------------------------------

// The virtio vendor, and the device id of a modern block device: the
// transitional base 0x1040 plus the block device type 2.
VIRTIO_VENDOR :: u16(0x1AF4)
VIRTIO_BLK_DEVICE :: u16(0x1042)

// The virtio-pci vendor capability's `cfg_type` byte.
CAP_COMMON :: u8(1)
CAP_NOTIFY :: u8(2)
CAP_ISR :: u8(3)
CAP_DEVICE :: u8(4)

// Where a virtio-pci vendor capability keeps its fields, past the two bytes
// every capability has.
CAP_LEN :: u16(2)
CAP_CFG_TYPE :: u16(3)
CAP_BAR :: u16(4)
CAP_OFFSET :: u16(8)
CAP_LENGTH :: u16(12)
CAP_NOTIFY_MULT :: u16(16) // NOTIFY_CFG only

// -- The common configuration structure --------------------------------------

COMMON_DEVICE_FEATURE_SELECT :: uintptr(0)
COMMON_DEVICE_FEATURE :: uintptr(4)
COMMON_DRIVER_FEATURE_SELECT :: uintptr(8)
COMMON_DRIVER_FEATURE :: uintptr(12)
COMMON_NUM_QUEUES :: uintptr(18)
COMMON_DEVICE_STATUS :: uintptr(20)
COMMON_QUEUE_SELECT :: uintptr(22)
COMMON_QUEUE_SIZE :: uintptr(24)
COMMON_QUEUE_ENABLE :: uintptr(28)
COMMON_QUEUE_NOTIFY_OFF :: uintptr(30)
COMMON_QUEUE_DESC :: uintptr(32)
COMMON_QUEUE_DRIVER :: uintptr(40)
COMMON_QUEUE_DEVICE :: uintptr(48)

// Status bits, written to COMMON_DEVICE_STATUS as the handshake proceeds.
STATUS_ACKNOWLEDGE :: u8(1)
STATUS_DRIVER :: u8(2)
STATUS_DRIVER_OK :: u8(4)
STATUS_FEATURES_OK :: u8(8)
STATUS_FAILED :: u8(128)

// The one feature the modern handshake requires the driver to accept: that
// this is a 1.0 device and not a legacy one. Bit 32, hence feature word 1.
VIRTIO_F_VERSION_1 :: u32(1) // bit 0 of feature word 1

// -- The split virtqueue ------------------------------------------------------

// Small on purpose. This driver issues one request and waits for it, so a
// ring of sixteen descriptors is fifteen more than it needs and still fits
// each of the three rings in well under a page.
VIRTQ_SIZE :: u16(16)

// Descriptor flags.
VIRTQ_DESC_NEXT :: u16(1) // Another descriptor follows in `next`
VIRTQ_DESC_WRITE :: u16(2) // The device writes this buffer, rather than reads

Virtq_Desc :: struct {
	addr:  u64,
	len:   u32,
	flags: u16,
	next:  u16,
}

// -- The block protocol -------------------------------------------------------

VIRTIO_BLK_T_IN :: u32(0) // Read from the device into memory
VIRTIO_BLK_T_OUT :: u32(1) // Write memory to the device

VIRTIO_BLK_S_OK :: u8(0)

// The capacity, in 512-byte sectors, is the first register of DEVICE_CFG.
BLK_CAPACITY :: uintptr(0)

SECTOR_SIZE :: 512

Blk_Header :: struct {
	type:     u32,
	reserved: u32,
	sector:   u64,
}

// -- A disk -------------------------------------------------------------------

MAX_DISKS :: 4

Disk :: struct {
	used:      bool,
	at:        pci.Address,

	// The mapped register structures.
	common:    rawptr,
	notify:    rawptr,
	notify_mult: u32,
	device:    rawptr,

	// The doorbell for the one queue, precomputed from its notify offset.
	doorbell:  rawptr,

	capacity:  u64, // In 512-byte sectors

	// The virtqueue, in RAM the device reaches by physical address.
	desc:      [^]Virtq_Desc,
	avail:     [^]u16, // flags, idx, ring[VIRTQ_SIZE]
	used_ring: [^]u16, // flags, idx, then (id u32, len u32) pairs
	desc_phys: u64,
	avail_phys: u64,
	used_phys: u64,
	last_used: u16, // The used index this driver has already seen

	// One request's header and status byte, reused. The data buffer is the
	// caller's, mapped by physical address.
	header:      ^Blk_Header,
	header_phys: u64,
	status:      ^u8,
	status_phys: u64,

	lock:      sync.Spinlock,
}

@(private = "file")
disks: [MAX_DISKS]Disk

// count reports how many disks came up, for the boot line.
count :: proc "contextless" () -> int {
	n := 0
	for i in 0 ..< MAX_DISKS {
		if disks[i].used {
			n += 1
		}
	}
	return n
}

// capacity reports disk `n`'s size in 512-byte sectors, or zero for a disk
// that is not there.
capacity :: proc "contextless" (n: int) -> u64 {
	if n < 0 || n >= MAX_DISKS || !disks[n].used {
		return 0
	}
	return disks[n].capacity
}

present :: proc "contextless" (n: int) -> bool {
	return n >= 0 && n < MAX_DISKS && disks[n].used
}

// -- Register access ----------------------------------------------------------

@(private = "file")
r8 :: proc "contextless" (base: rawptr, off: uintptr) -> u8 {
	return intrinsics.volatile_load(cast(^u8)(uintptr(base) + off))
}

@(private = "file")
w8 :: proc "contextless" (base: rawptr, off: uintptr, v: u8) {
	intrinsics.volatile_store(cast(^u8)(uintptr(base) + off), v)
}

@(private = "file")
r16 :: proc "contextless" (base: rawptr, off: uintptr) -> u16 {
	return intrinsics.volatile_load(cast(^u16)(uintptr(base) + off))
}

@(private = "file")
w16 :: proc "contextless" (base: rawptr, off: uintptr, v: u16) {
	intrinsics.volatile_store(cast(^u16)(uintptr(base) + off), v)
}

@(private = "file")
r32 :: proc "contextless" (base: rawptr, off: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(uintptr(base) + off))
}

@(private = "file")
w32 :: proc "contextless" (base: rawptr, off: uintptr, v: u32) {
	intrinsics.volatile_store(cast(^u32)(uintptr(base) + off), v)
}

@(private = "file")
w64 :: proc "contextless" (base: rawptr, off: uintptr, v: u64) {
	// Two 32-bit stores, low half first, as the specification requires for a
	// register a 32-bit transport might split.
	w32(base, off, u32(v))
	w32(base, off + 4, u32(v >> 32))
}

// -- Bring-up -----------------------------------------------------------------

Error :: enum {
	None,
	No_Slot, // MAX_DISKS already in use
	No_Caps, // The device is missing a capability the driver needs
	Map_Failed, // A BAR would not map
	No_Memory, // The virtqueue would not allocate
	Handshake, // The device refused the feature negotiation
	No_Queue, // Queue zero has size zero
}

/*
attach brings up one virtio-blk function and gives it the next disk number.

The modern handshake, in the order the specification sets: acknowledge the
device, say a driver is present, read and accept features, mark features
accepted and check the device still agrees, set up the one queue, and only
then say the driver is ready. A step the device disagrees with sets the
FAILED bit and returns, so a half-configured device is never left looking
live.
*/
attach :: proc(at: pci.Address) -> (n: int, err: Error) {
	slot := -1
	for i in 0 ..< MAX_DISKS {
		if !disks[i].used {
			slot = i
			break
		}
	}
	if slot < 0 {
		return -1, .No_Slot
	}
	d := &disks[slot]
	d^ = Disk {
		at = at,
	}

	pci.enable(at)
	if !map_structures(d) {
		return -1, .No_Caps
	}

	// Reset, then acknowledge.
	w8(d.common, COMMON_DEVICE_STATUS, 0)
	set_status(d, STATUS_ACKNOWLEDGE)
	set_status(d, STATUS_DRIVER)

	if !negotiate(d) {
		fail(d)
		return -1, .Handshake
	}

	if !setup_queue(d) {
		fail(d)
		return -1, .No_Queue
	}

	if !setup_request(d) {
		fail(d)
		return -1, .No_Memory
	}

	set_status(d, STATUS_DRIVER_OK)

	d.capacity = read_capacity(d)
	d.used = true
	return slot, .None
}

@(private = "file")
set_status :: proc "contextless" (d: ^Disk, bit: u8) {
	now := r8(d.common, COMMON_DEVICE_STATUS)
	w8(d.common, COMMON_DEVICE_STATUS, now | bit)
}

@(private = "file")
fail :: proc "contextless" (d: ^Disk) {
	set_status(d, STATUS_FAILED)
	d^ = Disk{}
}

@(private = "file")
read_capacity :: proc "contextless" (d: ^Disk) -> u64 {
	lo := u64(r32(d.device, BLK_CAPACITY))
	hi := u64(r32(d.device, BLK_CAPACITY + 4))
	return hi << 32 | lo
}

/*
map_structures walks the capability list and maps the four register
structures the driver uses. Each vendor capability names a BAR and an offset
into it; the BAR's physical base plus that offset is a page of MMIO to map.
COMMON, NOTIFY and DEVICE are required; a device missing any is not one this
driver can drive.
*/
@(private = "file")
map_structures :: proc(d: ^Disk) -> bool {
	cap := pci.first_cap(d.at)
	for cap != 0 {
		if pci.cap_id(d.at, cap) == pci.CAP_VENDOR {
			read_cap(d, cap)
		}
		cap = pci.next_cap(d.at, cap)
	}
	if d.common == nil || d.notify == nil || d.device == nil {
		return false
	}
	return true
}

@(private = "file")
read_cap :: proc(d: ^Disk, cap: u8) {
	cfg_type := pci.read8(d.at, u16(cap) + CAP_CFG_TYPE)
	bar_index := int(pci.read8(d.at, u16(cap) + CAP_BAR))
	offset := pci.read32(d.at, u16(cap) + CAP_OFFSET)
	length := pci.read32(d.at, u16(cap) + CAP_LENGTH)

	bar, ok := pci.bar(d.at, bar_index)
	if !ok {
		return
	}
	virt, merr := mem.map_mmio(bar.phys + uintptr(offset), u64(length))
	if merr != .None {
		return
	}
	switch cfg_type {
	case CAP_COMMON:
		d.common = virt
	case CAP_NOTIFY:
		d.notify = virt
		d.notify_mult = pci.read32(d.at, u16(cap) + CAP_NOTIFY_MULT)
	case CAP_ISR:
		// Read to acknowledge an interrupt; polled bring-up never reads it.
	case CAP_DEVICE:
		d.device = virt
	}
}

/*
negotiate accepts exactly the features the driver understands. The device
offers two 32-bit words; the driver reads them, keeps only VERSION_1 in the
high word, writes its acceptance back, sets FEATURES_OK, and reads the status
to see the device did not clear it. A cleared bit means the device cannot
work with what the driver accepted, which for a set this small should not
happen and is a failure if it does.
*/
@(private = "file")
negotiate :: proc "contextless" (d: ^Disk) -> bool {
	// Word 0: nothing this driver needs. Word 1: VERSION_1.
	w32(d.common, COMMON_DRIVER_FEATURE_SELECT, 0)
	w32(d.common, COMMON_DRIVER_FEATURE, 0)
	w32(d.common, COMMON_DRIVER_FEATURE_SELECT, 1)
	w32(d.common, COMMON_DRIVER_FEATURE, VIRTIO_F_VERSION_1)

	set_status(d, STATUS_FEATURES_OK)
	return r8(d.common, COMMON_DEVICE_STATUS) & STATUS_FEATURES_OK != 0
}

/*
setup_queue selects queue zero, shrinks it to VIRTQ_SIZE, allocates the three
rings and hands the device their physical addresses, then enables it. The
doorbell address is the notify structure plus the queue's own notify offset
scaled by the multiplier, computed once here because it does not change.
*/
@(private = "file")
setup_queue :: proc "contextless" (d: ^Disk) -> bool {
	w16(d.common, COMMON_QUEUE_SELECT, 0)
	if r16(d.common, COMMON_QUEUE_SIZE) == 0 {
		return false
	}
	w16(d.common, COMMON_QUEUE_SIZE, VIRTQ_SIZE)

	desc_phys, ok1 := mem.alloc_page_zeroed()
	avail_phys, ok2 := mem.alloc_page_zeroed()
	used_phys, ok3 := mem.alloc_page_zeroed()
	if !ok1 || !ok2 || !ok3 {
		return false
	}
	d.desc = cast([^]Virtq_Desc)mem.phys_to_virt(desc_phys)
	d.avail = cast([^]u16)mem.phys_to_virt(avail_phys)
	d.used_ring = cast([^]u16)mem.phys_to_virt(used_phys)
	d.desc_phys = u64(desc_phys)
	d.avail_phys = u64(avail_phys)
	d.used_phys = u64(used_phys)

	w64(d.common, COMMON_QUEUE_DESC, d.desc_phys)
	w64(d.common, COMMON_QUEUE_DRIVER, d.avail_phys)
	w64(d.common, COMMON_QUEUE_DEVICE, d.used_phys)

	notify_off := r16(d.common, COMMON_QUEUE_NOTIFY_OFF)
	d.doorbell = rawptr(uintptr(d.notify) + uintptr(u32(notify_off) * d.notify_mult))

	w16(d.common, COMMON_QUEUE_ENABLE, 1)
	return true
}

@(private = "file")
setup_request :: proc "contextless" (d: ^Disk) -> bool {
	phys, ok := mem.alloc_page_zeroed()
	if !ok {
		return false
	}
	// The header at the start of the page, the status byte after it. Both
	// are tiny and share the one page.
	d.header = cast(^Blk_Header)mem.phys_to_virt(phys)
	d.header_phys = u64(phys)
	d.status = cast(^u8)(uintptr(mem.phys_to_virt(phys)) + size_of(Blk_Header))
	d.status_phys = u64(phys) + u64(size_of(Blk_Header))
	return true
}

// -- The one operation --------------------------------------------------------

/*
transfer moves one sector-aligned run between disk `n` and `buf`, in the
direction `write` names, and reports whether the device answered OK. `buf`'s
length must be a multiple of the sector size, and `sector` counts 512-byte
sectors from the start of the disk.

The three descriptors are laid out at indices 0, 1 and 2 every time: the
header the device reads, the data buffer, and the status byte the device
writes. The available ring is advanced by one, the doorbell rung, and the
used ring polled until its index moves. One request is outstanding, so the
used entry is this request's.
*/
transfer :: proc "contextless" (n: int, sector: u64, buf: []u8, write: bool) -> bool {
	if n < 0 || n >= MAX_DISKS || !disks[n].used {
		return false
	}
	if len(buf) == 0 || len(buf) % SECTOR_SIZE != 0 {
		return false
	}
	d := &disks[n]
	if sector + u64(len(buf) / SECTOR_SIZE) > d.capacity {
		return false
	}

	g := sync.acquire(&d.lock)
	defer sync.release(&d.lock, g)

	d.header^ = Blk_Header {
		type   = write ? VIRTIO_BLK_T_OUT : VIRTIO_BLK_T_IN,
		sector = sector,
	}
	d.status^ = 0xFF

	// The device reads a data buffer on a write and writes it on a read.
	data_flags := write ? u16(VIRTQ_DESC_NEXT) : u16(VIRTQ_DESC_NEXT | VIRTQ_DESC_WRITE)
	d.desc[0] = Virtq_Desc {
		addr  = d.header_phys,
		len   = u32(size_of(Blk_Header)),
		flags = VIRTQ_DESC_NEXT,
		next  = 1,
	}
	d.desc[1] = Virtq_Desc {
		addr  = u64(uintptr(mem.virt_to_phys(raw_data(buf)))),
		len   = u32(len(buf)),
		flags = data_flags,
		next  = 2,
	}
	d.desc[2] = Virtq_Desc {
		addr  = d.status_phys,
		len   = 1,
		flags = VIRTQ_DESC_WRITE,
		next  = 0,
	}

	// The available ring: index 1 is idx, the ring starts at index 2. Put
	// descriptor 0 at the ring slot the next idx names, then publish idx.
	avail_idx := d.avail[1]
	d.avail[2 + (avail_idx % VIRTQ_SIZE)] = 0
	fence()
	d.avail[1] = avail_idx + 1
	fence()

	// Ring the doorbell with the queue index.
	w16(d.doorbell, 0, 0)

	// Poll the used ring's idx, at index 1, until it passes what we have seen.
	for {
		fence()
		if d.used_ring[1] != d.last_used {
			break
		}
		arch.spin_hint()
	}
	d.last_used = d.used_ring[1]

	return d.status^ == VIRTIO_BLK_S_OK
}

// read fills `buf` from `sector` onward; write does the reverse. Both are
// `transfer` with the direction named, kept as the two verbs a caller wants.
read :: proc "contextless" (n: int, sector: u64, buf: []u8) -> bool {
	return transfer(n, sector, buf, false)
}

write :: proc "contextless" (n: int, sector: u64, buf: []u8) -> bool {
	return transfer(n, sector, buf, true)
}

// fence orders the driver's ring writes against the device's reads. The
// rings are ordinary memory and the device is another bus master, so a
// store that lands out of order lets the device see an index before the
// descriptor it points at.
@(private = "file")
fence :: proc "contextless" () {
	intrinsics.atomic_thread_fence(.Seq_Cst)
}

/*
init scans the PCI bus for every virtio-blk function and brings each up as a
disk, in bus order. Answers how many came up. A machine with none still
boots; it just has no `/dev/sd0`.
*/
init :: proc() -> int {
	found: [32]pci.Device
	total := pci.scan(found[:])
	seen := min(total, len(found))
	for i in 0 ..< seen {
		dev := found[i]
		if dev.vendor == VIRTIO_VENDOR && dev.device == VIRTIO_BLK_DEVICE {
			attach(dev.at)
		}
	}
	return count()
}
