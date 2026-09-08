/*
virtio-sound over modern PCI: the card `/dev/audio` plays samples on.

The third twin of `blk.odin`, on the same transport, `docs/DEVTOOLS.md` step 1.
A `virtio-sound-pci` function has four virtqueues -- control, event, transmit
and receive, as the specification numbers them. This driver plays, so it drives
two: the control queue to set a stream up and start it, and the transmit queue
to hand it samples. The event queue reports jack changes nobody here watches,
and the receive queue is capture, which this does not do; both are set up empty
so the device is content, and neither is fed.

**Message-based, and polled.** A stream is prepared and started with a request
on the control queue and its one-word answer. Samples then go on the transmit
queue as I/O messages: a four-byte header naming the stream, the frames, and an
eight-byte status the device writes back. The driver spins on the used ring for
each, the way the disk and the card do -- but under a deadline read from the
fast counter, because a playback backend drains at real time and a wedged one
must not hang the boot. `sound_play` answers how many bytes the device took.

The register access, the capability walk and the feature handshake are
virtio-pci's, written again here as `net.odin` and `blk.odin` write them. The
common half across four drivers is now worth lifting into its own file; that is
a tidy this driver does not do, so as to land the sound path on its own.
*/
package virtio

import "base:intrinsics"

import "kernel:arch"
import "kernel:drivers/pci"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"

// The device id of a modern virtio sound card: the base 0x1040 plus the sound
// device type, 25. The vendor and the transport constants are the disk's.
VIRTIO_SND_DEVICE :: u16(0x1059)

// The four queues, as the specification numbers them. This driver uses the
// control and transmit queues; it sets the other two up and leaves them empty.
SND_VQ_CONTROL :: u16(0)
SND_VQ_EVENT :: u16(1)
SND_VQ_TX :: u16(2)
SND_VQ_RX :: u16(3)
SND_VQ_COUNT :: 4

// Device configuration: three counts, the first of which the driver reads.
SND_CFG_JACKS :: uintptr(0)
SND_CFG_STREAMS :: uintptr(4)
SND_CFG_CHMAPS :: uintptr(8)

// Control request codes, and the one status the driver hopes to read back.
VIRTIO_SND_R_PCM_SET_PARAMS :: u32(0x0101)
VIRTIO_SND_R_PCM_PREPARE :: u32(0x0102)
VIRTIO_SND_R_PCM_RELEASE :: u32(0x0103)
VIRTIO_SND_R_PCM_START :: u32(0x0104)
VIRTIO_SND_R_PCM_STOP :: u32(0x0105)
VIRTIO_SND_S_OK :: u32(0x8000)

// The one PCM format and rate this driver asks for: signed sixteen-bit, two
// channels, forty-eight thousand a second. The codes are the specification's
// enumerations, not the values themselves.
VIRTIO_SND_PCM_FMT_S16 :: u8(5)
VIRTIO_SND_PCM_RATE_48000 :: u8(7)
SND_CHANNELS :: u8(2)
SND_RATE_HZ :: 48000
SND_FRAME_BYTES :: 4 // two channels, two bytes each

// The device's ring, and the largest samples one transmit message carries. A
// period is the grain the device notifies on; the driver hands it whole periods
// and a shorter final piece.
SND_BUFFER_BYTES :: u32(16384)
SND_PERIOD_BYTES :: u32(4096)

// The transmit header the device reads ahead of the frames: the stream id.
SND_XFER_HDR :: 4
// The status the device writes after: a code and a latency, two words.
SND_STATUS_LEN :: 8

// The stream this driver plays, the first the card reports.
SND_STREAM :: u32(0)

// How long to wait for one transmit message before giving the buffer up as
// undrained, in milliseconds of the fast counter. A period at the rate above is
// about eighty milliseconds; a healthy backend beats this comfortably, and a
// wedged one is abandoned rather than spun on forever.
SND_TX_TIMEOUT_MS :: 400

MAX_CARDS :: 1

@(private = "file")
Snd_Queue :: struct {
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

@(private = "file")
Card :: struct {
	used:        bool,
	at:          pci.Address,
	common:      rawptr,
	notify:      rawptr,
	notify_mult: u32,
	device:      rawptr,
	streams:     u32,
	started:     bool,
	control:     Snd_Queue,
	tx:          Snd_Queue,
	// The control request and response, reused under the lock.
	req_phys:    u64,
	req_virt:    rawptr,
	resp_phys:   u64,
	resp_virt:   rawptr,
	// One transmit buffer: the header and a period of frames, and the status
	// the device writes back.
	tx_phys:     u64,
	tx_virt:     rawptr,
	st_phys:     u64,
	st_virt:     rawptr,
	lock:        sync.Spinlock,
}

@(private = "file")
cards: [MAX_CARDS]Card

// sound_present reports whether a card came up, for the boot line and the
// device file that will not open without one.
sound_present :: proc "contextless" () -> bool {
	return cards[0].used && cards[0].started
}

// sound_rate answers the format `/dev/audio` plays at: the rate in hertz, the
// channel count, and the bits a sample carries. Fixed, this first cut.
sound_rate :: proc "contextless" () -> (hz: int, channels: int, bits: int) {
	return SND_RATE_HZ, int(SND_CHANNELS), 16
}

// -- Register access ----------------------------------------------------------
//
// `blk.odin`'s, the same registers on the same transport.

@(private = "file")
s_set_status :: proc "contextless" (c: ^Card, bit: u8) {
	now := r8(c.common, COMMON_DEVICE_STATUS)
	w8(c.common, COMMON_DEVICE_STATUS, now | bit)
}

// -- Bring-up -----------------------------------------------------------------

/*
sound_attach brings up one virtio-sound function. The handshake is the disk's:
acknowledge, name a driver, negotiate VERSION_1, set the four queues up, say the
driver is ready. It then prepares and starts the one stream, so that a write to
`/dev/audio` is only ever samples on a running stream. A step the device
disagrees with sets FAILED and gives up on the card.
*/
@(private = "file")
sound_attach :: proc(at: pci.Address) -> bool #no_bounds_check {
	if cards[0].used {
		return false
	}
	c := &cards[0]
	c^ = Card {
		at = at,
	}

	pci.enable(at)
	if !sound_map_structures(c) {
		return false
	}

	w8(c.common, COMMON_DEVICE_STATUS, 0)
	s_set_status(c, STATUS_ACKNOWLEDGE)
	s_set_status(c, STATUS_DRIVER)

	if !sound_negotiate(c) {
		sound_fail(c)
		return false
	}

	// All four queues, so the device sees the ring it expects at each index.
	// Only the control and transmit rings are ever fed.
	if !sound_setup_queue(c, SND_VQ_CONTROL, &c.control) {
		sound_fail(c)
		return false
	}
	dead: Snd_Queue
	if !sound_setup_queue(c, SND_VQ_EVENT, &dead) {
		sound_fail(c)
		return false
	}
	if !sound_setup_queue(c, SND_VQ_TX, &c.tx) {
		sound_fail(c)
		return false
	}
	if !sound_setup_queue(c, SND_VQ_RX, &dead) {
		sound_fail(c)
		return false
	}
	if !sound_setup_buffers(c) {
		sound_fail(c)
		return false
	}

	c.streams = r32(c.device, SND_CFG_STREAMS)

	s_set_status(c, STATUS_DRIVER_OK)

	if c.streams == 0 {
		sound_fail(c)
		return false
	}
	if !sound_start_stream(c) {
		sound_fail(c)
		return false
	}

	c.used = true
	c.started = true
	return true
}

@(private = "file")
sound_fail :: proc "contextless" (c: ^Card) {
	s_set_status(c, STATUS_FAILED)
	c^ = Card{}
}

@(private = "file")
sound_negotiate :: proc "contextless" (c: ^Card) -> bool {
	// Only VERSION_1, in word 1. No sound feature is asked for: message-based
	// transfer, which this driver uses, is the device's baseline.
	w32(c.common, COMMON_DRIVER_FEATURE_SELECT, 0)
	w32(c.common, COMMON_DRIVER_FEATURE, 0)
	w32(c.common, COMMON_DRIVER_FEATURE_SELECT, 1)
	w32(c.common, COMMON_DRIVER_FEATURE, VIRTIO_F_VERSION_1)

	s_set_status(c, STATUS_FEATURES_OK)
	return r8(c.common, COMMON_DEVICE_STATUS) & STATUS_FEATURES_OK != 0
}

@(private = "file")
sound_map_structures :: proc(c: ^Card) -> bool {
	cap := pci.first_cap(c.at)
	for cap != 0 {
		if pci.cap_id(c.at, cap) == pci.CAP_VENDOR {
			sound_read_cap(c, cap)
		}
		cap = pci.next_cap(c.at, cap)
	}
	return c.common != nil && c.notify != nil && c.device != nil
}

@(private = "file")
sound_read_cap :: proc(c: ^Card, cap: u8) {
	cfg_type := pci.read8(c.at, u16(cap) + CAP_CFG_TYPE)
	bar_index := int(pci.read8(c.at, u16(cap) + CAP_BAR))
	offset := pci.read32(c.at, u16(cap) + CAP_OFFSET)
	length := pci.read32(c.at, u16(cap) + CAP_LENGTH)

	bar, ok := pci.bar(c.at, bar_index)
	if !ok {
		return
	}
	virt, merr := mem.map_mmio(bar.phys + uintptr(offset), u64(length))
	if merr != .None {
		return
	}
	switch cfg_type {
	case CAP_COMMON:
		c.common = virt
	case CAP_NOTIFY:
		c.notify = virt
		c.notify_mult = pci.read32(c.at, u16(cap) + CAP_NOTIFY_MULT)
	case CAP_ISR:
	case CAP_DEVICE:
		c.device = virt
	}
}

@(private = "file")
sound_setup_queue :: proc "contextless" (c: ^Card, index: u16, q: ^Snd_Queue) -> bool {
	w16(c.common, COMMON_QUEUE_SELECT, index)
	if r16(c.common, COMMON_QUEUE_SIZE) == 0 {
		return false
	}
	w16(c.common, COMMON_QUEUE_SIZE, VIRTQ_SIZE)

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

	w64(c.common, COMMON_QUEUE_DESC, q.desc_phys)
	w64(c.common, COMMON_QUEUE_DRIVER, q.avail_phys)
	w64(c.common, COMMON_QUEUE_DEVICE, q.used_phys)

	notify_off := r16(c.common, COMMON_QUEUE_NOTIFY_OFF)
	q.doorbell = rawptr(uintptr(c.notify) + uintptr(u32(notify_off) * c.notify_mult))

	w16(c.common, COMMON_QUEUE_ENABLE, 1)
	return true
}

@(private = "file")
sound_setup_buffers :: proc "contextless" (c: ^Card) -> bool {
	req, ok1 := mem.alloc_page_zeroed()
	resp, ok2 := mem.alloc_page_zeroed()
	// Two pages for the transmit buffer: a whole period of frames and the
	// four-byte header ahead of them do not fit in one.
	tx, ok3 := mem.alloc_pages_zeroed(2)
	st, ok4 := mem.alloc_page_zeroed()
	if !ok1 || !ok2 || !ok3 || !ok4 {
		return false
	}
	c.req_phys = u64(req)
	c.req_virt = mem.phys_to_virt(req)
	c.resp_phys = u64(resp)
	c.resp_virt = mem.phys_to_virt(resp)
	c.tx_phys = u64(tx)
	c.tx_virt = mem.phys_to_virt(tx)
	c.st_phys = u64(st)
	c.st_virt = mem.phys_to_virt(st)
	return true
}

// -- The control queue --------------------------------------------------------

/*
control sends one request already laid into the request buffer, of `req_len`
bytes, and waits for the device's answer. It returns the status word the device
wrote, or a non-OK value if the wait ran out. Head descriptor zero points at the
request, descriptor one at the response the device fills.
*/
@(private = "file")
control :: proc "contextless" (c: ^Card, req_len: u32) -> u32 #no_bounds_check {
	q := &c.control
	// Zero the response, so a device that writes nothing is not read as OK.
	resp := cast([^]u8)c.resp_virt
	for i in 0 ..< 8 {
		resp[i] = 0
	}
	q.desc[0] = Virtq_Desc {
		addr  = c.req_phys,
		len   = req_len,
		flags = VIRTQ_DESC_NEXT,
		next  = 1,
	}
	q.desc[1] = Virtq_Desc {
		addr  = c.resp_phys,
		len   = 64,
		flags = VIRTQ_DESC_WRITE,
		next  = 0,
	}
	q.avail[2 + (q.avail_idx % VIRTQ_SIZE)] = 0
	q.avail_idx += 1
	fence()
	q.avail[1] = q.avail_idx
	fence()
	w16(q.doorbell, 0, SND_VQ_CONTROL)

	if !wait_used(q, SND_TX_TIMEOUT_MS) {
		return 0
	}
	q.last_used = q.used_ring[1]
	fence()
	return u32(resp[0]) | u32(resp[1]) << 8 | u32(resp[2]) << 16 | u32(resp[3]) << 24
}

// put32 writes a little-endian word into a byte buffer at an offset.
@(private = "file")
put32 :: proc "contextless" (b: [^]u8, off: int, v: u32) #no_bounds_check {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
	b[off + 2] = u8(v >> 16)
	b[off + 3] = u8(v >> 24)
}

/*
sound_start_stream sets the stream's parameters, prepares it, and starts it.
Three control requests, each of which must answer OK. After this a transmit
message is samples the device will play.
*/
@(private = "file")
sound_start_stream :: proc "contextless" (c: ^Card) -> bool #no_bounds_check {
	req := cast([^]u8)c.req_virt

	// SET_PARAMS: code, stream, buffer_bytes, period_bytes, features, then the
	// channel count, format and rate as three bytes and a pad. Twenty-four
	// bytes, the specification's `virtio_snd_pcm_set_params`.
	put32(req, 0, VIRTIO_SND_R_PCM_SET_PARAMS)
	put32(req, 4, SND_STREAM)
	put32(req, 8, SND_BUFFER_BYTES)
	put32(req, 12, SND_PERIOD_BYTES)
	put32(req, 16, 0) // no features
	req[20] = SND_CHANNELS
	req[21] = VIRTIO_SND_PCM_FMT_S16
	req[22] = VIRTIO_SND_PCM_RATE_48000
	req[23] = 0
	if control(c, 24) != VIRTIO_SND_S_OK {
		return false
	}

	// PREPARE and START: code and stream, the specification's
	// `virtio_snd_pcm_hdr`, eight bytes.
	put32(req, 0, VIRTIO_SND_R_PCM_PREPARE)
	put32(req, 4, SND_STREAM)
	if control(c, 8) != VIRTIO_SND_S_OK {
		return false
	}
	put32(req, 0, VIRTIO_SND_R_PCM_START)
	put32(req, 4, SND_STREAM)
	if control(c, 8) != VIRTIO_SND_S_OK {
		return false
	}
	return true
}

// -- The transmit queue -------------------------------------------------------

/*
wait_used spins on a queue's used ring until it moves past what the driver last
saw, or the fast-counter deadline passes. True if the ring moved. The deadline
is what keeps a backend that never drains from hanging the boot.
*/
@(private = "file")
wait_used :: proc "contextless" (q: ^Snd_Queue, timeout_ms: u64) -> bool {
	hz := sched.fast_clock_hz()
	deadline := sched.fast_ticks() + hz * timeout_ms / 1000
	// A raw spin cap for the degraded boot where the timer never calibrated and
	// the fast clock reads zero: a large number, so it never fires on a healthy
	// machine, but the boot cannot hang here on a card that will not drain.
	spins: u64 = 0
	for {
		fence()
		if q.used_ring[1] != q.last_used {
			return true
		}
		if hz != 0 {
			if sched.fast_ticks() >= deadline {
				return false
			}
		} else {
			spins += 1
			if spins > 2_000_000_000 {
				return false
			}
		}
		arch.spin_hint()
	}
}

/*
sound_play hands the device a run of samples and answers how many bytes it took.
The run is sent a period at a time: the stream header and the frames into the
transmit buffer, a descriptor at each and a status after, then a spin on the
used ring under the deadline. A period the device does not acknowledge in time
stops the run, and the bytes already taken are the answer -- a short write, not
a hang.
*/
sound_play :: proc "contextless" (data: []u8) -> int #no_bounds_check {
	if !cards[0].used || !cards[0].started || len(data) == 0 {
		return 0
	}
	c := &cards[0]
	g := sync.acquire(&c.lock)
	defer sync.release(&c.lock, g)

	q := &c.tx
	buf := cast([^]u8)c.tx_virt
	sent := 0
	for sent < len(data) {
		chunk := min(len(data) - sent, int(SND_PERIOD_BYTES))
		put32(buf, 0, SND_STREAM)
		copy(buf[SND_XFER_HDR:SND_XFER_HDR + chunk], data[sent:sent + chunk])

		q.desc[0] = Virtq_Desc {
			addr  = c.tx_phys,
			len   = u32(SND_XFER_HDR + chunk),
			flags = VIRTQ_DESC_NEXT,
			next  = 1,
		}
		q.desc[1] = Virtq_Desc {
			addr  = c.st_phys,
			len   = SND_STATUS_LEN,
			flags = VIRTQ_DESC_WRITE,
			next  = 0,
		}
		q.avail[2 + (q.avail_idx % VIRTQ_SIZE)] = 0
		q.avail_idx += 1
		fence()
		q.avail[1] = q.avail_idx
		fence()
		w16(q.doorbell, 0, SND_VQ_TX)

		if !wait_used(q, SND_TX_TIMEOUT_MS) {
			break
		}
		q.last_used = q.used_ring[1]
		sent += chunk
	}
	return sent
}

/*
sound_init scans the PCI bus for the first virtio-sound function and brings it
up. Answers whether one came up. A machine with no card still boots and simply
has no sound; `/dev/audio` then refuses to open.
*/
sound_init :: proc() -> bool {
	found: [32]pci.Device
	total := pci.scan(found[:])
	seen := min(total, len(found))
	for i in 0 ..< seen {
		dev := found[i]
		if dev.vendor == VIRTIO_VENDOR && dev.device == VIRTIO_SND_DEVICE {
			if sound_attach(dev.at) {
				return true
			}
		}
	}
	return false
}
