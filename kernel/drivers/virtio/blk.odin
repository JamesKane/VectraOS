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
by default and the boards have no legacy path. The capability walk, the
handshake and the virtqueue are `transport.odin`'s, shared with the card, the
entropy source and the sound card.

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

import "kernel:arch"
import "kernel:drivers/pci"
import "kernel:mem"
import "kernel:smmu"
import "kernel:sync"

// The device id of a modern block device: the transitional base 0x1040 plus
// the block device type 2.
VIRTIO_BLK_DEVICE :: u16(0x1042)

// ACCESS_PLATFORM, bit 33: the device's addresses go through the platform's
// walker rather than straight to memory. A device behind the SMMU offers it
// and requires it accepted. For this driver, whose stream is in bypass, the
// addresses it hands over are still physical. `docs/SMMU.md` section 8.
VIRTIO_F_ACCESS_PLATFORM :: u32(1) << 1 // bit 1 of feature word 1

// How many spins a request is waited for. A disk answers in microseconds.
// This is seconds, and past it the device is not answering at all.
POLL_PATIENCE :: 200_000_000

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
	using t:   Transport,

	capacity:  u64, // In 512-byte sectors

	// The one virtqueue, in RAM the device reaches by physical address.
	q:         Virtq,

	// One request's header and status byte, reused. The data buffer is the
	// caller's, mapped by physical address.
	header:      ^Blk_Header,
	header_phys: u64,
	status:      ^u8,
	status_phys: u64,

	lock:      sync.Spinlock,

	// The walker's attach count this driver last saw. A change means a
	// program held some device's stream since, and may have reset this
	// one and rebuilt its queue. So the next transfer brings it up again
	// on this driver's own rings first. `docs/SMMU.md` section 8.
	generation: u64,
}

@(private = "file")
disks: [MAX_DISKS]Disk

// owned answers whether a program holds disk `n`'s stream, section 8's
// rule. A disk a program attached is no longer the kernel's, and `#S` says
// so.
owned :: proc "contextless" (n: int) -> bool {
	if n < 0 || n >= MAX_DISKS || !disks[n].used {
		return false
	}
	return smmu.stream_owned(pci.requester_id(disks[n].at))
}

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

// -- Bring-up -----------------------------------------------------------------

/*
attach brings up one virtio-blk function and gives it the next disk number.

The modern handshake, in the order the specification sets: acknowledge the
device, say a driver is present, read and accept features, mark features
accepted and check the device still agrees, set up the one queue, and only
then say the driver is ready. A step the device disagrees with sets the
FAILED bit and returns, so a half-configured device is never left looking
live.
*/
attach :: proc(at: pci.Address) -> bool {
	slot := -1
	for i in 0 ..< MAX_DISKS {
		if !disks[i].used {
			slot = i
			break
		}
	}
	if slot < 0 {
		return false
	}
	d := &disks[slot]
	d^ = Disk {
		t = {at = at},
	}

	pci.enable(at)
	if !map_structures(&d.t, true) {
		return false
	}

	// Reset, then acknowledge.
	arch.mmio_write8(d.common, COMMON_DEVICE_STATUS, 0)
	set_status(&d.t, STATUS_ACKNOWLEDGE)
	set_status(&d.t, STATUS_DRIVER)

	if !blk_negotiate(d) {
		fail(d)
		return false
	}

	if !setup_queue(&d.t, 0, &d.q) {
		fail(d)
		return false
	}

	if !setup_request(d) {
		fail(d)
		return false
	}

	set_status(&d.t, STATUS_DRIVER_OK)

	d.capacity = read_capacity(d)
	d.used = true
	return true
}

@(private = "file")
read_capacity :: proc "contextless" (d: ^Disk) -> u64 {
	lo := u64(arch.mmio_read32(d.device, BLK_CAPACITY))
	hi := u64(arch.mmio_read32(d.device, BLK_CAPACITY + 4))
	return hi << 32 | lo
}

/*
blk_negotiate accepts exactly the features the driver understands. The device
offers two 32-bit words; the driver reads them, keeps only VERSION_1 in the
high word, and `negotiate` writes its acceptance back and checks the device
still agrees.
*/
@(private = "file")
blk_negotiate :: proc "contextless" (d: ^Disk) -> bool {
	// Word 0: nothing this driver needs. Word 1: VERSION_1, and
	// ACCESS_PLATFORM when the device offers it, which a device behind the
	// walker does and refuses to work without.
	offered := device_features(&d.t, 1)
	return negotiate(&d.t, 0, VIRTIO_F_VERSION_1 | (offered & VIRTIO_F_ACCESS_PLATFORM))
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

	// A program that held a stream since the last transfer may have reset
	// this device and named its own rings to it. The handshake again, on
	// this driver's rings, before the request goes on them.
	if gen := smmu.attach_generation(); gen != d.generation {
		d.generation = gen
		if !reinit(d) {
			return false
		}
	}

	d.header^ = Blk_Header {
		type   = write ? VIRTIO_BLK_T_OUT : VIRTIO_BLK_T_IN,
		sector = sector,
	}
	d.status^ = 0xFF

	// The device reads a data buffer on a write and writes it on a read.
	data_flags := write ? u16(VIRTQ_DESC_NEXT) : u16(VIRTQ_DESC_NEXT | VIRTQ_DESC_WRITE)
	q := &d.q
	q.desc[0] = Virtq_Desc {
		addr  = d.header_phys,
		len   = u32(size_of(Blk_Header)),
		flags = VIRTQ_DESC_NEXT,
		next  = 1,
	}
	q.desc[1] = Virtq_Desc {
		addr  = u64(uintptr(mem.virt_to_phys(raw_data(buf)))),
		len   = u32(len(buf)),
		flags = data_flags,
		next  = 2,
	}
	q.desc[2] = Virtq_Desc {
		addr  = d.status_phys,
		len   = 1,
		flags = VIRTQ_DESC_WRITE,
		next  = 0,
	}

	// Publish descriptor 0 and ring the doorbell with the queue index.
	kick(q, 0, 0)

	// Poll the used ring until it moves. Bounded, because a device a program
	// held and gave back may be broken past this driver's rebuilding of it.
	// A request it never answers is an I/O error rather than a machine that
	// stops here.
	if !wait_used(q, POLL_PATIENCE) {
		return false
	}
	q.last_used = q.used_ring[1]

	// A read barrier between seeing the used index advance and reading what the
	// device wrote -- the status byte here, the sector bytes in the caller's
	// bounce page next. Without it a weakly-ordered core (every target but
	// amd64) may satisfy those loads from before the device's stores: a stale
	// `0xFF` status read as an I/O error, or worse, stale sector data read as
	// good. `sound.control` keeps the same barrier; this path had dropped it.
	fence()
	return d.status^ == VIRTIO_BLK_S_OK
}

/*
reinit is the handshake again on a device a program reset. Status zero,
the stream back to bypass, acknowledge, driver, the one feature,
features-ok, the queue named by the rings this driver already holds, and
driver-ok. The rings are zeroed and the used index forgotten, because the
device's indexes restart at zero.
*/
@(private = "file")
reinit :: proc "contextless" (d: ^Disk) -> bool {
	arch.mmio_write8(d.common, COMMON_DEVICE_STATUS, 0)
	for arch.mmio_read8(d.common, COMMON_DEVICE_STATUS) != 0 {}
	// Reset, so nothing is in flight, and only now the stream back to
	// bypass. A program that held it left the entry `abort`, and this
	// driver's physical addresses need it gone. A stream a program still
	// holds stays as it is, and `owned` keeps every transfer off it.
	_ = smmu.stream_release(pci.requester_id(d.at))
	set_status(&d.t, STATUS_ACKNOWLEDGE)
	set_status(&d.t, STATUS_DRIVER)
	if !blk_negotiate(d) {
		return false
	}
	rings := [3][^]u8{cast([^]u8)d.q.desc, cast([^]u8)d.q.avail, cast([^]u8)d.q.used_ring}
	for ring in rings {
		for i in 0 ..< mem.PAGE_SIZE {
			ring[i] = 0
		}
	}
	d.q.last_used = 0
	d.q.avail_idx = 0
	program_queue(&d.t, 0, &d.q)
	set_status(&d.t, STATUS_DRIVER_OK)
	return true
}

// read fills `buf` from `sector` onward; write does the reverse. Both are
// `transfer` with the direction named, kept as the two verbs a caller wants.
read :: proc "contextless" (n: int, sector: u64, buf: []u8) -> bool {
	return transfer(n, sector, buf, false)
}

write :: proc "contextless" (n: int, sector: u64, buf: []u8) -> bool {
	return transfer(n, sector, buf, true)
}

/*
init brings up every virtio-blk function on the bus as a disk, in bus order.
Answers how many came up. A machine with none still boots; it just has no
`/dev/sd0`.
*/
init :: proc() -> int {
	for dev in functions() {
		if dev.vendor == VIRTIO_VENDOR && dev.device == VIRTIO_BLK_DEVICE {
			attach(dev.at)
		}
	}
	return count()
}
