/*
virtio-net over modern PCI: the card the machine sends and receives frames on.

The twin of `blk.odin`, on the same transport. A `virtio-net-pci` function has
two virtqueues rather than one. The device fills a receive queue, and the driver
fills a transmit queue. Every buffer on either carries a twelve-byte header the
offloads would use, ahead of the frame. This driver negotiates no offloads, so
the header is twelve zeroes it writes and skips.

**Polled, like the disk.** The receive queue is posted with buffers at bring-up
and refilled as frames arrive. `send` fills one transmit descriptor and spins on
the used ring. `recv` reads the used ring and hands back one frame, or nothing.
`docs/FLEET.md` step 0's `netfs` will drive this from a proc that parks on an
interrupt. The polled shape is what the kernel's own self-test needs, and what
proves the card before a stack sits on it.

The register access, the capability walk and the feature handshake are
virtio-pci's, the same as the disk's. They are written again here rather than
shared. A factoring would serve only these two drivers, and a shared file would
couple the disk to the card. When a third virtio device arrives, the common half
is worth lifting out.
*/
package virtio

import "base:intrinsics"

import "kernel:arch"
import "kernel:drivers/pci"
import "kernel:mem"
import "kernel:sync"

// The device id of a modern virtio network card. The vendor and the
// capability, status and feature constants are the disk's, in `blk.odin`.
VIRTIO_NET_DEVICE :: u16(0x1041)

// The one device feature this driver asks for: that the card report its own
// MAC address in device configuration. Bit 5 of feature word zero.
VIRTIO_NET_F_MAC :: u32(1 << 5)

// The two queues a network card has. The receive queue is even, the transmit
// queue next, as the specification numbers them.
NET_QUEUE_RX :: u16(0)
NET_QUEUE_TX :: u16(1)

// The header every buffer carries ahead of the frame. Twelve bytes, because
// VERSION_1 makes `num_buffers` always present, and this driver zeroes it.
NET_HDR_LEN :: 12

// One receive buffer holds a header and a frame, with room for the largest
// ethernet frame this driver accepts. A page each, posted at bring-up.
NET_BUF_SIZE :: 2048
NET_RX_BUFS :: int(VIRTQ_SIZE)

MAX_NICS :: 2

// A virtqueue, the three rings and where the device reaches them, plus the
// used index this driver has already accounted for and the queue's doorbell.
Net_Queue :: struct {
	desc:       [^]Virtq_Desc,
	avail:      [^]u16,
	used_ring:  [^]u16,
	desc_phys:  u64,
	avail_phys: u64,
	used_phys:  u64,
	last_used:  u16,
	avail_idx:  u16,
	doorbell:   rawptr,
}

Nic :: struct {
	used:        bool,
	at:          pci.Address,
	common:      rawptr,
	notify:      rawptr,
	notify_mult: u32,
	device:      rawptr,
	mac:         [6]u8,
	rx:          Net_Queue,
	tx:          Net_Queue,
	// The receive buffers, by physical address the device writes into and the
	// virtual address this driver reads out of.
	rx_phys:     [NET_RX_BUFS]u64,
	rx_virt:     [NET_RX_BUFS]rawptr,
	// One transmit buffer, refilled per send.
	tx_phys:     u64,
	tx_virt:     rawptr,
	lock:        sync.Spinlock,
}

@(private = "file")
nics: [MAX_NICS]Nic

// count reports how many cards came up, for the boot line.
net_count :: proc "contextless" () -> int {
	n := 0
	for i in 0 ..< MAX_NICS {
		if nics[i].used {
			n += 1
		}
	}
	return n
}

net_present :: proc "contextless" (n: int) -> bool {
	return n >= 0 && n < MAX_NICS && nics[n].used
}

// mac copies card `n`'s hardware address into `out`, and answers whether it
// did. The address is the card's own, read from device configuration.
mac :: proc "contextless" (n: int, out: []u8) -> bool #no_bounds_check {
	if n < 0 || n >= MAX_NICS || !nics[n].used || len(out) < 6 {
		return false
	}
	for i in 0 ..< 6 {
		out[i] = nics[n].mac[i]
	}
	return true
}

// -- Register access ----------------------------------------------------------
//
// `blk.odin`'s, which are the same registers on the same transport. The disk
// wrote them first and this driver shares them rather than writing them again.

@(private = "file")
n_set_status :: proc "contextless" (nic: ^Nic, bit: u8) {
	now := r8(nic.common, COMMON_DEVICE_STATUS)
	w8(nic.common, COMMON_DEVICE_STATUS, now | bit)
}

// -- Bring-up -----------------------------------------------------------------

/*
attach brings up one virtio-net function as the next card. The handshake is the
disk's. It acknowledges the device, names a driver, negotiates features, sets up
the two queues, and posts the receive buffers. Only then does it say the driver
is ready, and a step the device disagrees with sets FAILED and returns.
*/
net_attach :: proc(at: pci.Address) -> bool #no_bounds_check {
	slot := -1
	for i in 0 ..< MAX_NICS {
		if !nics[i].used {
			slot = i
			break
		}
	}
	if slot < 0 {
		return false
	}
	nic := &nics[slot]
	nic^ = Nic {
		at = at,
	}

	pci.enable(at)
	if !net_map_structures(nic) {
		return false
	}

	w8(nic.common, COMMON_DEVICE_STATUS, 0)
	n_set_status(nic, STATUS_ACKNOWLEDGE)
	n_set_status(nic, STATUS_DRIVER)

	if !net_negotiate(nic) {
		net_fail(nic)
		return false
	}

	if !net_setup_queue(nic, NET_QUEUE_RX, &nic.rx) {
		net_fail(nic)
		return false
	}
	if !net_setup_queue(nic, NET_QUEUE_TX, &nic.tx) {
		net_fail(nic)
		return false
	}
	if !net_setup_buffers(nic) {
		net_fail(nic)
		return false
	}

	// The card's own address, from device configuration the feature unlocked.
	for i in 0 ..< 6 {
		nic.mac[i] = r8(nic.device, uintptr(i))
	}

	n_set_status(nic, STATUS_DRIVER_OK)

	// Post every receive buffer, then tell the card they are there.
	net_post_all_rx(nic)

	nic.used = true
	return true
}

@(private = "file")
net_fail :: proc "contextless" (nic: ^Nic) {
	n_set_status(nic, STATUS_FAILED)
	nic^ = Nic{}
}

@(private = "file")
net_negotiate :: proc "contextless" (nic: ^Nic) -> bool {
	// Word 0: the MAC feature. Word 1: VERSION_1. Nothing else is accepted,
	// so the card runs without checksum or segmentation offload.
	w32(nic.common, COMMON_DRIVER_FEATURE_SELECT, 0)
	w32(nic.common, COMMON_DRIVER_FEATURE, VIRTIO_NET_F_MAC)
	w32(nic.common, COMMON_DRIVER_FEATURE_SELECT, 1)
	w32(nic.common, COMMON_DRIVER_FEATURE, VIRTIO_F_VERSION_1)

	n_set_status(nic, STATUS_FEATURES_OK)
	return r8(nic.common, COMMON_DEVICE_STATUS) & STATUS_FEATURES_OK != 0
}

@(private = "file")
net_map_structures :: proc(nic: ^Nic) -> bool {
	cap := pci.first_cap(nic.at)
	for cap != 0 {
		if pci.cap_id(nic.at, cap) == pci.CAP_VENDOR {
			net_read_cap(nic, cap)
		}
		cap = pci.next_cap(nic.at, cap)
	}
	return nic.common != nil && nic.notify != nil && nic.device != nil
}

@(private = "file")
net_read_cap :: proc(nic: ^Nic, cap: u8) {
	cfg_type := pci.read8(nic.at, u16(cap) + CAP_CFG_TYPE)
	bar_index := int(pci.read8(nic.at, u16(cap) + CAP_BAR))
	offset := pci.read32(nic.at, u16(cap) + CAP_OFFSET)
	length := pci.read32(nic.at, u16(cap) + CAP_LENGTH)

	bar, ok := pci.bar(nic.at, bar_index)
	if !ok {
		return
	}
	virt, merr := mem.map_mmio(bar.phys + uintptr(offset), u64(length))
	if merr != .None {
		return
	}
	switch cfg_type {
	case CAP_COMMON:
		nic.common = virt
	case CAP_NOTIFY:
		nic.notify = virt
		nic.notify_mult = pci.read32(nic.at, u16(cap) + CAP_NOTIFY_MULT)
	case CAP_ISR:
	case CAP_DEVICE:
		nic.device = virt
	}
}

@(private = "file")
net_setup_queue :: proc "contextless" (nic: ^Nic, index: u16, q: ^Net_Queue) -> bool {
	w16(nic.common, COMMON_QUEUE_SELECT, index)
	if r16(nic.common, COMMON_QUEUE_SIZE) == 0 {
		return false
	}
	w16(nic.common, COMMON_QUEUE_SIZE, VIRTQ_SIZE)

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

	w64(nic.common, COMMON_QUEUE_DESC, q.desc_phys)
	w64(nic.common, COMMON_QUEUE_DRIVER, q.avail_phys)
	w64(nic.common, COMMON_QUEUE_DEVICE, q.used_phys)

	notify_off := r16(nic.common, COMMON_QUEUE_NOTIFY_OFF)
	q.doorbell = rawptr(uintptr(nic.notify) + uintptr(u32(notify_off) * nic.notify_mult))

	w16(nic.common, COMMON_QUEUE_ENABLE, 1)
	return true
}

@(private = "file")
net_setup_buffers :: proc "contextless" (nic: ^Nic) -> bool {
	for i in 0 ..< NET_RX_BUFS {
		phys, ok := mem.alloc_page_zeroed()
		if !ok {
			return false
		}
		nic.rx_phys[i] = u64(phys)
		nic.rx_virt[i] = mem.phys_to_virt(phys)
	}
	tx, ok := mem.alloc_page_zeroed()
	if !ok {
		return false
	}
	nic.tx_phys = u64(tx)
	nic.tx_virt = mem.phys_to_virt(tx)
	return true
}

// net_post_all_rx lays every receive buffer into its own descriptor, fills the
// available ring with all of them, and rings the receive doorbell once.
@(private = "file")
net_post_all_rx :: proc "contextless" (nic: ^Nic) #no_bounds_check {
	q := &nic.rx
	for i in 0 ..< NET_RX_BUFS {
		q.desc[i] = Virtq_Desc {
			addr  = nic.rx_phys[i],
			len   = u32(NET_BUF_SIZE),
			flags = VIRTQ_DESC_WRITE,
			next  = 0,
		}
		q.avail[2 + i] = u16(i)
	}
	q.avail_idx = u16(NET_RX_BUFS)
	fence()
	q.avail[1] = q.avail_idx
	fence()
	w16(q.doorbell, 0, NET_QUEUE_RX)
}

// -- Sending and receiving ----------------------------------------------------

/*
send transmits one ethernet frame. The twelve-byte header and the frame go into
the one transmit buffer, and a single descriptor points at both. The driver then
spins on the transmit used ring until the card takes it. It answers whether the
frame fit and left.
*/
send :: proc "contextless" (n: int, frame: []u8) -> bool #no_bounds_check {
	if n < 0 || n >= MAX_NICS || !nics[n].used {
		return false
	}
	if len(frame) == 0 || len(frame) > NET_BUF_SIZE - NET_HDR_LEN {
		return false
	}
	nic := &nics[n]
	g := sync.acquire(&nic.lock)
	defer sync.release(&nic.lock, g)

	dst := cast([^]u8)nic.tx_virt
	for i in 0 ..< NET_HDR_LEN {
		dst[i] = 0
	}
	copy(dst[NET_HDR_LEN:NET_HDR_LEN + len(frame)], frame)

	q := &nic.tx
	q.desc[0] = Virtq_Desc {
		addr  = nic.tx_phys,
		len   = u32(NET_HDR_LEN + len(frame)),
		flags = 0,
		next  = 0,
	}
	q.avail[2 + (q.avail_idx % VIRTQ_SIZE)] = 0
	q.avail_idx += 1
	fence()
	q.avail[1] = q.avail_idx
	fence()
	w16(q.doorbell, 0, NET_QUEUE_TX)

	for {
		fence()
		if q.used_ring[1] != q.last_used {
			break
		}
		arch.spin_hint()
	}
	q.last_used = q.used_ring[1]
	return true
}

/*
recv hands back one received frame, without its header, or zero when none is
there yet. The used ring names the buffer and the byte count the card wrote into
it. The header is skipped and the frame copied to `out`. The buffer is then
posted again, so the card always has somewhere to write.
*/
recv :: proc "contextless" (n: int, out: []u8) -> int #no_bounds_check {
	if n < 0 || n >= MAX_NICS || !nics[n].used {
		return 0
	}
	nic := &nics[n]
	g := sync.acquire(&nic.lock)
	defer sync.release(&nic.lock, g)

	q := &nic.rx
	fence()
	if q.used_ring[1] == q.last_used {
		return 0
	}
	// The used element at `last_used` holds an id and a len. Each is a u32 in
	// the ring of u16s that starts at index 2, four u16s to an element.
	slot := int(q.last_used % VIRTQ_SIZE)
	base := 2 + slot * 4
	id := int(u32(q.used_ring[base]) | u32(q.used_ring[base + 1]) << 16)
	wrote := int(u32(q.used_ring[base + 2]) | u32(q.used_ring[base + 3]) << 16)
	if id < 0 || id >= NET_RX_BUFS {
		q.last_used += 1
		return 0
	}

	frame_len := wrote - NET_HDR_LEN
	copied := 0
	if frame_len > 0 {
		src := cast([^]u8)nic.rx_virt[id]
		copied = min(frame_len, len(out))
		copy(out[:copied], src[NET_HDR_LEN:NET_HDR_LEN + copied])
	}

	// Post the buffer again for the next frame.
	q.avail[2 + (q.avail_idx % VIRTQ_SIZE)] = u16(id)
	q.avail_idx += 1
	fence()
	q.avail[1] = q.avail_idx
	fence()
	w16(q.doorbell, 0, NET_QUEUE_RX)

	q.last_used += 1
	return copied
}

/*
net_init scans the PCI bus for every virtio-net function and brings each up as
a card, in bus order. Answers how many came up. A machine with none still
boots, and simply has no network.
*/
net_init :: proc() -> int {
	found: [32]pci.Device
	total := pci.scan(found[:])
	seen := min(total, len(found))
	for i in 0 ..< seen {
		dev := found[i]
		if dev.vendor == VIRTIO_VENDOR && dev.device == VIRTIO_NET_DEVICE {
			net_attach(dev.at)
		}
	}
	return net_count()
}

