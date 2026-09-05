/*
virtio-rng over modern PCI: the machine's source of entropy.

The third virtio device, after the disk and the card, and the simplest. It has
one virtqueue. The driver posts a buffer the device may write, rings the
doorbell, and the device fills the buffer with random bytes and returns it on
the used ring. There is no configuration and no feature but VERSION_1.

`docs/FLEET.md` step 2's handshake needs a fresh ephemeral key per session, and
a key that is not random is no key. `/dev/random` in `kernel/devfs` reads
through here, and every architecture the fleet runs gets the same source,
because QEMU presents `virtio-rng-pci` on each. On a board a hardware generator
sits behind the same device.

The register access and the queue setup are the disk's and the card's, the same
transport. When this became the third driver to write them, the shared half was
still small enough to leave in place; a fourth is the time to lift it out.
*/
package virtio

import "kernel:arch"
import "kernel:drivers/pci"
import "kernel:mem"
import "kernel:sync"

// The device id of a modern virtio entropy source: 0x1040 plus device type 4.
VIRTIO_RNG_DEVICE :: u16(0x1044)

MAX_RNGS :: 1
RNG_BUF_SIZE :: 64

Rng_Queue :: struct {
	desc:       [^]Virtq_Desc,
	avail:      [^]u16,
	used_ring:  [^]u16,
	desc_phys:  u64,
	avail_phys: u64,
	used_phys:  u64,
	last_used:  u16,
	avail_idx:  u16,
	size:       u16, // The queue's entries: the device's maximum, or ours if smaller
	doorbell:   rawptr,
}

Rng :: struct {
	used:        bool,
	at:          pci.Address,
	common:      rawptr,
	notify:      rawptr,
	notify_mult: u32,
	q:           Rng_Queue,
	buf_phys:    u64,
	buf_virt:    rawptr,
	lock:        sync.Spinlock,
}

@(private = "file")
rngs: [MAX_RNGS]Rng


rng_present :: proc "contextless" () -> bool {
	return rngs[0].used
}

@(private = "file")
r_set_status :: proc "contextless" (rng: ^Rng, bit: u8) {
	now := r8(rng.common, COMMON_DEVICE_STATUS)
	w8(rng.common, COMMON_DEVICE_STATUS, now | bit)
}

/*
rng_fill asks the device for up to `len(out)` random bytes, and answers how
many it wrote. One buffer, posted and waited on, the polled shape the disk and
the card use. A caller that wants more than one buffer's worth calls again.
*/
rng_fill :: proc "contextless" (out: []u8) -> int #no_bounds_check {
	if !rngs[0].used || len(out) == 0 {
		return 0
	}
	rng := &rngs[0]
	g := sync.acquire(&rng.lock)
	defer sync.release(&rng.lock, g)

	want := min(len(out), RNG_BUF_SIZE)
	q := &rng.q
	q.desc[0] = Virtq_Desc {
		addr  = rng.buf_phys,
		len   = u32(want),
		flags = VIRTQ_DESC_WRITE, // the device writes the entropy
		next  = 0,
	}
	q.avail[2 + (q.avail_idx % q.size)] = 0
	q.avail_idx += 1
	fence()
	q.avail[1] = q.avail_idx
	fence()
	w16(q.doorbell, 0, 0)

	// Bounded: a device that never answers must not hang the machine. The
	// spin is generous, and a timeout returns nothing rather than never.
	got_used := false
	for _ in 0 ..< 100_000_000 {
		fence()
		if q.used_ring[1] != q.last_used {
			got_used = true
			break
		}
		arch.spin_hint()
	}
	if !got_used {
		return 0
	}
	// The used element at `last_used`: id then the byte count the device wrote.
	slot := int(q.last_used % q.size)
	base := 2 + slot * 4
	wrote := int(u32(q.used_ring[base + 2]) | u32(q.used_ring[base + 3]) << 16)
	q.last_used += 1

	n := min(wrote, want)
	src := cast([^]u8)rng.buf_virt
	for i in 0 ..< n {
		out[i] = src[i]
	}
	return n
}

// -- Bring-up -----------------------------------------------------------------

/*
rng_attach brings up one virtio-rng function. The handshake is the disk's: it
acknowledges the device, names a driver, negotiates VERSION_1, sets up the one
queue and its buffer, and says the driver is ready.
*/
rng_attach :: proc(at: pci.Address) -> bool #no_bounds_check {
	if rngs[0].used {
		return false
	}
	rng := &rngs[0]
	rng^ = Rng{at = at}

	pci.enable(at)
	if !rng_map_structures(rng) {
		return false
	}
	w8(rng.common, COMMON_DEVICE_STATUS, 0)
	r_set_status(rng, STATUS_ACKNOWLEDGE)
	r_set_status(rng, STATUS_DRIVER)
	if !rng_negotiate(rng) {
		r_set_status(rng, STATUS_FAILED)
		rng^ = Rng{}
		return false
	}
	if !rng_setup_queue(rng) {
		r_set_status(rng, STATUS_FAILED)
		rng^ = Rng{}
		return false
	}
	buf, ok := mem.alloc_page_zeroed()
	if !ok {
		r_set_status(rng, STATUS_FAILED)
		rng^ = Rng{}
		return false
	}
	rng.buf_phys = u64(buf)
	rng.buf_virt = mem.phys_to_virt(buf)
	r_set_status(rng, STATUS_DRIVER_OK)
	rng.used = true
	return true
}

@(private = "file")
rng_negotiate :: proc "contextless" (rng: ^Rng) -> bool {
	w32(rng.common, COMMON_DRIVER_FEATURE_SELECT, 0)
	w32(rng.common, COMMON_DRIVER_FEATURE, 0)
	w32(rng.common, COMMON_DRIVER_FEATURE_SELECT, 1)
	w32(rng.common, COMMON_DRIVER_FEATURE, VIRTIO_F_VERSION_1)
	r_set_status(rng, STATUS_FEATURES_OK)
	return r8(rng.common, COMMON_DEVICE_STATUS) & STATUS_FEATURES_OK != 0
}

@(private = "file")
rng_map_structures :: proc(rng: ^Rng) -> bool {
	cap := pci.first_cap(rng.at)
	for cap != 0 {
		if pci.cap_id(rng.at, cap) == pci.CAP_VENDOR {
			rng_read_cap(rng, cap)
		}
		cap = pci.next_cap(rng.at, cap)
	}
	return rng.common != nil && rng.notify != nil
}

@(private = "file")
rng_read_cap :: proc(rng: ^Rng, cap: u8) {
	cfg_type := pci.read8(rng.at, u16(cap) + CAP_CFG_TYPE)
	bar_index := int(pci.read8(rng.at, u16(cap) + CAP_BAR))
	offset := pci.read32(rng.at, u16(cap) + CAP_OFFSET)
	length := pci.read32(rng.at, u16(cap) + CAP_LENGTH)
	bar, ok := pci.bar(rng.at, bar_index)
	if !ok {
		return
	}
	virt, merr := mem.map_mmio(bar.phys + uintptr(offset), u64(length))
	if merr != .None {
		return
	}
	switch cfg_type {
	case CAP_COMMON:
		rng.common = virt
	case CAP_NOTIFY:
		rng.notify = virt
		rng.notify_mult = pci.read32(rng.at, u16(cap) + CAP_NOTIFY_MULT)
	}
}

@(private = "file")
rng_setup_queue :: proc "contextless" (rng: ^Rng) -> bool {
	q := &rng.q
	w16(rng.common, COMMON_QUEUE_SELECT, 0)
	// The device names the most entries its queue holds, and a driver may ask
	// for fewer but never more. The entropy device's queue is eight deep,
	// half the size the disk and the card take, and QEMU treats a request
	// past the maximum as a broken driver: it flags the device NEEDS_RESET and
	// drops every notification after, silently. So the smaller of the two.
	most := r16(rng.common, COMMON_QUEUE_SIZE)
	if most == 0 {
		return false
	}
	q.size = min(VIRTQ_SIZE, most)
	w16(rng.common, COMMON_QUEUE_SIZE, q.size)
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
	w64(rng.common, COMMON_QUEUE_DESC, q.desc_phys)
	w64(rng.common, COMMON_QUEUE_DRIVER, q.avail_phys)
	w64(rng.common, COMMON_QUEUE_DEVICE, q.used_phys)
	notify_off := r16(rng.common, COMMON_QUEUE_NOTIFY_OFF)
	q.doorbell = rawptr(uintptr(rng.notify) + uintptr(u32(notify_off) * rng.notify_mult))
	w16(rng.common, COMMON_QUEUE_ENABLE, 1)
	return true
}

/*
rng_init scans the PCI bus for a virtio entropy source and brings the first up.
A machine with none has no `/dev/random`, and the handshake cannot run there.
*/
rng_init :: proc() -> int #no_bounds_check {
	found: [32]pci.Device
	total := pci.scan(found[:])
	for i in 0 ..< total {
		dev := found[i]
		if dev.vendor == VIRTIO_VENDOR && dev.device == VIRTIO_RNG_DEVICE {
			if rng_attach(dev.at) {
				return 1
			}
		}
	}
	return 0
}
