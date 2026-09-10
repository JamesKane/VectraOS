/*
The virtio-pci transport: what every modern virtio function here shares.

`blk.odin` wrote the capability walk, the status handshake, the feature
negotiation and the split virtqueue first. `net.odin`, `rng.odin` and
`sound.odin` each wrote them again, and each said the next driver was the
time to lift the common half out. This file is that half. A driver keeps what
is its own: the device id, its feature words, the queues it fills and what it
puts in them.

A `Transport` is the mapped register structures of one function, and every
driver's record embeds one. A `Virtq` is one split virtqueue: the three rings,
where the device reaches them, the two indexes the driver keeps, and the
queue's doorbell. `kick` and `wait_used` are the two halves of every polled
request, and `used_elem` reads what came back.

The register accessors are `arch.mmio_*`. `w64` is the one this transport
adds: two 32-bit stores, low half first, as the specification requires for a
register a 32-bit transport might split.
*/
package virtio

import "base:intrinsics"

import "kernel:arch"
import "kernel:drivers/pci"
import "kernel:mem"

// -- PCI identity ------------------------------------------------------------

// The virtio vendor. A modern device's id is the transitional base 0x1040
// plus its device type, and each driver names its own.
VIRTIO_VENDOR :: u16(0x1AF4)

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

// Small on purpose. A driver here issues one request and waits for it. A ring
// of sixteen descriptors is more than it needs, and each of the three rings
// still fits in well under a page.
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

// A virtqueue: the three rings, and where the device reaches them. Then the
// used index the driver last took, the available index it last wrote, and the
// queue's doorbell.
Virtq :: struct {
	desc:       [^]Virtq_Desc,
	avail:      [^]u16, // flags, idx, ring[size]
	used_ring:  [^]u16, // flags, idx, then (id u32, len u32) pairs
	desc_phys:  u64,
	avail_phys: u64,
	used_phys:  u64,
	last_used:  u16, // The used index this driver has already seen
	avail_idx:  u16, // The available index this driver has published
	size:       u16, // The queue's entries: the device's maximum, or ours if smaller
	doorbell:   rawptr,
}

// The mapped register structures of one function. A queue's doorbell is the
// notify structure plus its own notify offset scaled by the multiplier.
// `setup_queue` computes it once, because it does not change.
Transport :: struct {
	at:          pci.Address,
	common:      rawptr,
	notify:      rawptr,
	notify_mult: u32,
	device:      rawptr,
}

// The patience of a caller that waits for the device however long it takes.
UNBOUNDED :: -1

// -- Register access ----------------------------------------------------------

w64 :: proc "contextless" (base: rawptr, off: uintptr, v: u64) {
	// Two 32-bit stores, low half first, as the specification requires for a
	// register a 32-bit transport might split.
	arch.mmio_write32(base, off, u32(v))
	arch.mmio_write32(base, off + 4, u32(v >> 32))
}

// fence orders the driver's ring writes against the device's reads. The
// rings are ordinary memory and the device is another bus master. A store
// that lands out of order lets the device see an index before the
// descriptor it points at.
fence :: proc "contextless" () {
	intrinsics.atomic_thread_fence(.Seq_Cst)
}

// -- The bus ------------------------------------------------------------------

@(private = "file")
found: [32]pci.Device
@(private = "file")
found_count: int
@(private = "file")
scanned: bool

// functions lists the functions on bus 0, in bus order, once for every
// driver's init. The bus is read at boot on one core, which is the reason
// `kernel/drivers/pci` gives for not locking, and it does not change after.
functions :: proc "contextless" () -> []pci.Device {
	if !scanned {
		found_count = min(pci.scan(found[:]), len(found))
		scanned = true
	}
	return found[:found_count]
}

// -- The handshake ------------------------------------------------------------

set_status :: proc "contextless" (t: ^Transport, bit: u8) {
	now := arch.mmio_read8(t.common, COMMON_DEVICE_STATUS)
	arch.mmio_write8(t.common, COMMON_DEVICE_STATUS, now | bit)
}

// fail sets the FAILED bit and forgets the record, so a half-configured
// device is never left looking live. Every driver's record embeds its
// `Transport` as `t`.
fail :: proc "contextless" (rec: ^$T) {
	set_status(&rec.t, STATUS_FAILED)
	rec^ = T{}
}

/*
map_structures walks the capability list and maps the register structures the
driver uses. Each vendor capability names a BAR and an offset into it. The
BAR's physical base plus that offset is a page of MMIO to map. COMMON and
NOTIFY are required, and DEVICE when the driver reads device configuration. A
device missing any is not one the driver can drive.
*/
map_structures :: proc(t: ^Transport, need_device: bool) -> bool {
	cap := pci.first_cap(t.at)
	for cap != 0 {
		if pci.cap_id(t.at, cap) == pci.CAP_VENDOR {
			read_cap(t, cap)
		}
		cap = pci.next_cap(t.at, cap)
	}
	return t.common != nil && t.notify != nil && (!need_device || t.device != nil)
}

@(private = "file")
read_cap :: proc(t: ^Transport, cap: u8) {
	cfg_type := pci.read8(t.at, u16(cap) + CAP_CFG_TYPE)
	bar_index := int(pci.read8(t.at, u16(cap) + CAP_BAR))
	offset := pci.read32(t.at, u16(cap) + CAP_OFFSET)
	length := pci.read32(t.at, u16(cap) + CAP_LENGTH)

	bar, ok := pci.bar(t.at, bar_index)
	if !ok {
		return
	}
	virt, merr := mem.map_mmio(bar.phys + uintptr(offset), u64(length))
	if merr != .None {
		return
	}
	switch cfg_type {
	case CAP_COMMON:
		t.common = virt
	case CAP_NOTIFY:
		t.notify = virt
		t.notify_mult = pci.read32(t.at, u16(cap) + CAP_NOTIFY_MULT)
	case CAP_ISR:
		// Read to acknowledge an interrupt. Polled bring-up never reads it.
	case CAP_DEVICE:
		t.device = virt
	}
}

// device_features reads one word of what the device offers, for a driver
// that accepts a feature only when it is offered.
device_features :: proc "contextless" (t: ^Transport, word: u32) -> u32 {
	arch.mmio_write32(t.common, COMMON_DEVICE_FEATURE_SELECT, word)
	return arch.mmio_read32(t.common, COMMON_DEVICE_FEATURE)
}

/*
negotiate accepts exactly the features the driver understands, `w0` and `w1`
being its two words. It writes its acceptance, sets FEATURES_OK, and reads
the status to see the device did not clear it. A cleared bit means the device
cannot work with what the driver accepted. For sets this small that should not
happen, and is a failure if it does.
*/
negotiate :: proc "contextless" (t: ^Transport, w0, w1: u32) -> bool {
	arch.mmio_write32(t.common, COMMON_DRIVER_FEATURE_SELECT, 0)
	arch.mmio_write32(t.common, COMMON_DRIVER_FEATURE, w0)
	arch.mmio_write32(t.common, COMMON_DRIVER_FEATURE_SELECT, 1)
	arch.mmio_write32(t.common, COMMON_DRIVER_FEATURE, w1)

	set_status(t, STATUS_FEATURES_OK)
	return arch.mmio_read8(t.common, COMMON_DEVICE_STATUS) & STATUS_FEATURES_OK != 0
}

/*
setup_queue selects queue `index`, sizes it, allocates the three rings and
hands the device their physical addresses, then enables it. The doorbell
address is the notify structure plus the queue's own notify offset scaled by
the multiplier, computed once here because it does not change.

The device names the most entries its queue holds, and a driver may ask for
fewer but never more. The entropy device's queue is eight deep, half the size
the disk and the card take. QEMU treats a request past the maximum as a broken
driver. It flags the device NEEDS_RESET and drops every notification after,
silently. So the smaller of the two.
*/
setup_queue :: proc "contextless" (t: ^Transport, index: u16, q: ^Virtq) -> bool {
	arch.mmio_write16(t.common, COMMON_QUEUE_SELECT, index)
	most := arch.mmio_read16(t.common, COMMON_QUEUE_SIZE)
	if most == 0 {
		return false
	}
	q.size = min(VIRTQ_SIZE, most)
	arch.mmio_write16(t.common, COMMON_QUEUE_SIZE, q.size)

	desc_phys, ok1 := mem.alloc_page_zeroed()
	avail_phys, ok2 := mem.alloc_page_zeroed()
	used_phys, ok3 := mem.alloc_page_zeroed()
	if !ok1 || !ok2 || !ok3 {
		return false
	}
	q.desc = cast([^]Virtq_Desc)mem.phys_to_virt(desc_phys)
	q.avail = cast([^]u16)mem.phys_to_virt(avail_phys)
	q.used_ring = cast([^]u16)mem.phys_to_virt(used_phys)
	q.desc_phys = u64(desc_phys)
	q.avail_phys = u64(avail_phys)
	q.used_phys = u64(used_phys)
	q.last_used = 0
	q.avail_idx = 0

	w64(t.common, COMMON_QUEUE_DESC, q.desc_phys)
	w64(t.common, COMMON_QUEUE_DRIVER, q.avail_phys)
	w64(t.common, COMMON_QUEUE_DEVICE, q.used_phys)

	notify_off := arch.mmio_read16(t.common, COMMON_QUEUE_NOTIFY_OFF)
	q.doorbell = rawptr(uintptr(t.notify) + uintptr(u32(notify_off) * t.notify_mult))

	arch.mmio_write16(t.common, COMMON_QUEUE_ENABLE, 1)
	return true
}

// program_queue names a queue the driver already holds to a device that was
// reset: select it, size it, the three rings, and enable it.
program_queue :: proc "contextless" (t: ^Transport, index: u16, q: ^Virtq) {
	arch.mmio_write16(t.common, COMMON_QUEUE_SELECT, index)
	arch.mmio_write16(t.common, COMMON_QUEUE_SIZE, q.size)
	w64(t.common, COMMON_QUEUE_DESC, q.desc_phys)
	w64(t.common, COMMON_QUEUE_DRIVER, q.avail_phys)
	w64(t.common, COMMON_QUEUE_DEVICE, q.used_phys)
	arch.mmio_write16(t.common, COMMON_QUEUE_ENABLE, 1)
}

// -- One request ----------------------------------------------------------------

// kick publishes the chain at descriptor `head` and rings the doorbell with
// the queue's index. The available ring: index 1 is idx, the ring starts at
// index 2. Put the head at the ring slot the next idx names, then publish idx.
kick :: proc "contextless" (q: ^Virtq, head: u16, index: u16) #no_bounds_check {
	q.avail[2 + (q.avail_idx % q.size)] = head
	q.avail_idx += 1
	fence()
	q.avail[1] = q.avail_idx
	fence()
	arch.mmio_write16(q.doorbell, 0, index)
}

// wait_used spins on a queue's used ring, at index 1, until it moves past the
// last value taken. It spins `patience` turns at most, or forever for
// UNBOUNDED. True if the ring moved. The caller reads what the device wrote after a
// second barrier, see `sound.control`.
wait_used :: proc "contextless" (q: ^Virtq, patience: int) -> bool #no_bounds_check {
	for spins := 0; patience == UNBOUNDED || spins < patience; spins += 1 {
		fence()
		if q.used_ring[1] != q.last_used {
			return true
		}
		arch.spin_hint()
	}
	return false
}

// used_elem reads the used element at `last_used`: the head descriptor the
// device handed back, and the byte count it wrote. Each is a u32 in the ring
// of u16s that starts at index 2, four u16s to an element.
used_elem :: proc "contextless" (q: ^Virtq) -> (id: u32, wrote: u32) #no_bounds_check {
	slot := int(q.last_used % q.size)
	base := 2 + slot * 4
	id = u32(q.used_ring[base]) | u32(q.used_ring[base + 1]) << 16
	wrote = u32(q.used_ring[base + 2]) | u32(q.used_ring[base + 3]) << 16
	return id, wrote
}
