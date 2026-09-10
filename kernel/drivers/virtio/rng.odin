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
still small enough to leave in place; the fourth was the time to lift it out,
and `transport.odin` is where it went.
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

Rng :: struct {
	used:        bool,
	using t:     Transport,
	q:           Virtq,
	buf_phys:    u64,
	buf_virt:    rawptr,
	lock:        sync.Spinlock,
}

@(private = "file")
rngs: [MAX_RNGS]Rng

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
	kick(q, 0, 0)

	// Bounded: a device that never answers must not hang the machine. The
	// spin is generous, and a timeout returns nothing rather than never.
	if !wait_used(q, 100_000_000) {
		return 0
	}
	// A read barrier between seeing the used index advance and reading the byte
	// count and the entropy the device wrote: on a weakly-ordered core those
	// loads may otherwise come from before the device's stores, handing back
	// stale or zeroed bytes -- and this feeds key material. See `sound.control`.
	fence()
	// The used element at `last_used`: id then the byte count the device wrote.
	_, wrote := used_elem(q)
	q.last_used += 1

	n := min(int(wrote), want)
	src := cast([^]u8)rng.buf_virt
	copy(out[:n], src[:n])
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
	rng^ = Rng{t = {at = at}}

	pci.enable(at)
	if !map_structures(&rng.t, false) {
		return false
	}
	arch.mmio_write8(rng.common, COMMON_DEVICE_STATUS, 0)
	set_status(&rng.t, STATUS_ACKNOWLEDGE)
	set_status(&rng.t, STATUS_DRIVER)
	if !negotiate(&rng.t, 0, VIRTIO_F_VERSION_1) {
		fail(rng)
		return false
	}
	if !setup_queue(&rng.t, 0, &rng.q) {
		fail(rng)
		return false
	}
	buf, ok := mem.alloc_page_zeroed()
	if !ok {
		fail(rng)
		return false
	}
	rng.buf_phys = u64(buf)
	rng.buf_virt = mem.phys_to_virt(buf)
	set_status(&rng.t, STATUS_DRIVER_OK)
	rng.used = true
	return true
}

/*
rng_init brings up the first virtio entropy source on the bus. A machine with
none has no `/dev/random`, and the handshake cannot run there.
*/
rng_init :: proc() -> int #no_bounds_check {
	for dev in functions() {
		if dev.vendor == VIRTIO_VENDOR && dev.device == VIRTIO_RNG_DEVICE {
			if rng_attach(dev.at) {
				return 1
			}
		}
	}
	return 0
}
