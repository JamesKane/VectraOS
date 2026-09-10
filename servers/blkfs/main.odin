/*
blkfs -- a disk driver that is a program, `docs/SMMU.md` section 11.

The first client of the walker, and the rest of `docs/HARDWARE.md` step 0. It
drives one `virtio-blk-pci` function through nothing but files: the host's
`mmio` for the function's configuration page, `mmio32` or `mmio64` for the
BAR the device's registers live in, and `dma`, to which it writes `attach
<slot> <self>`. From that line on, every address this program hands the
device is an address in this program's own space, and the device's walker
translates it through this program's own page tables. The virtqueue is memory
from `segalloc`, and the addresses it hands the device are the addresses it
wrote them at. That is the sentence the whole design exists for.

It serves `sd0/data` and `sd0/ctl` in the shape `docs/DISK.md` gives them,
posted as `/srv/blkfs`. `data` is the disk, byte-addressable. `ctl` reads as
one line of geometry, and takes two words for the two proofs step 0 lists:

    prove unmapped   a transfer aimed at a page this program never mapped.
                     The device faults, the `dma` file says so, the device is
                     reset and its queue rebuilt, and the marker sector reads
                     correctly after.
    prove freed      a page the program gave back with `segdetach` is not
                     readable by the device. A sector is written from it, the
                     page is freed, and the same write from the same address
                     faults. Under `VECTRA_SMMU_NO_INVALIDATE` it lands, and
                     the check that reads this back fails, which is what a
                     control is for.

The result of the last proof is the second line of `ctl`.

One request at a time, polled, as the kernel's driver polls. A poll that
does not complete within its patience is a device that faulted, and the
`dma` line is read then, not before, because that read parks.

The device number on bus zero is the one argument, and two, the scratch
disk, is the default. `docs/DISK.md` says why the scratch disk and not the
ESP: the ESP is the disk every program is loaded from, and its stream stays
the kernel's.
*/
package blkfs

import "base:intrinsics"
import "base:runtime"

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

HOST :: "/dev/tree/pcie@10000000"

// -- PCI, through the configuration page -------------------------------------------

VENDOR :: u16(0x1AF4)
DEVICE :: u16(0x1042)
CFG_VENDOR :: uintptr(0x00)
CFG_DEVICE :: uintptr(0x02)
CFG_COMMAND :: uintptr(0x04)
CFG_BAR0 :: uintptr(0x10)
CFG_CAP_PTR :: uintptr(0x34)
COMMAND_MEMORY :: u16(1) << 1
COMMAND_MASTER :: u16(1) << 2
CAP_VENDOR :: u8(9)
CAP_COMMON :: u8(1)
CAP_NOTIFY :: u8(2)
CAP_DEVICE :: u8(4)

// -- virtio, the modern common configuration -----------------------------------------

COMMON_DEVICE_FEATURE_SELECT :: uintptr(0)
COMMON_DEVICE_FEATURE :: uintptr(4)
COMMON_DRIVER_FEATURE_SELECT :: uintptr(8)
COMMON_DRIVER_FEATURE :: uintptr(12)
COMMON_DEVICE_STATUS :: uintptr(20)
COMMON_QUEUE_SELECT :: uintptr(22)
COMMON_QUEUE_SIZE :: uintptr(24)
COMMON_QUEUE_ENABLE :: uintptr(28)
COMMON_QUEUE_NOTIFY_OFF :: uintptr(30)
COMMON_QUEUE_DESC :: uintptr(32)
COMMON_QUEUE_DRIVER :: uintptr(40)
COMMON_QUEUE_DEVICE :: uintptr(48)
STATUS_ACKNOWLEDGE :: u8(1)
STATUS_DRIVER :: u8(2)
STATUS_DRIVER_OK :: u8(4)
STATUS_FEATURES_OK :: u8(8)
VIRTIO_F_VERSION_1 :: u32(1)
VIRTIO_F_ACCESS_PLATFORM :: u32(1) << 1 // bit 33: the addresses go through the walker
BLK_CAPACITY :: uintptr(0)

VIRTQ_SIZE :: u16(16)
VIRTQ_DESC_NEXT :: u16(1)
VIRTQ_DESC_WRITE :: u16(2)
VIRTIO_BLK_T_IN :: u32(0)
VIRTIO_BLK_T_OUT :: u32(1)
VIRTIO_BLK_S_OK :: u8(0)
SECTOR :: 512
PAGE :: 4096

Virtq_Desc :: struct {
	addr:  u64,
	len:   u32,
	flags: u16,
	next:  u16,
}

Blk_Header :: struct {
	type:     u32,
	reserved: u32,
	sector:   u64,
}

// How long a transfer is waited for before the device is presumed to have
// faulted: spins first, then ticks of sleep.
SPINS :: 20000
PATIENCE_TICKS :: 300

// -- The device -------------------------------------------------------------------------

Disk :: struct {
	slot:        u32, // the requester id, and the dma file's slot
	cfg:         uintptr, // the function's configuration page
	common:      uintptr,
	notify:      uintptr,
	device:      uintptr,
	notify_mult: u32,
	doorbell:    uintptr,
	capacity:    u64,

	// The virtqueue and the request page, memory of this program's own,
	// named to the device by the addresses this program uses.
	desc:        [^]Virtq_Desc,
	avail:       [^]u16,
	used:        [^]u16,
	header:      ^Blk_Header,
	status:      ^u8,
	bounce:      [^]u8,
	last_used:   u16,

	dma_fd:      int,
	faults:      u64,
	transfers:   u64,
}

disk: Disk

// The windows the host's `ranges` name, by their base, for placing a BAR.
Window :: struct {
	base: u64,
	size: u64,
	fd:   int,
}
win32, win64: Window

// -- The tree ---------------------------------------------------------------------------

NODE_ROOT :: i32(0)
NODE_SD0 :: i32(1)
NODE_DATA :: i32(2)
NODE_CTL :: i32(3)

fids: libuser.Fid_Table

FRAME :: 8192 + 256
frame_in: [FRAME]u8
frame_out: [FRAME]u8
payload: [8192]u8

// The last proof's line, the second line of `ctl`.
proof: [160]u8
proof_len: int

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()

	dev := u32(2)
	args := libuser.args(block)
	if len(args) > 1 {
		if n, ok := parse_uint(args[1]); ok && n < 32 {
			dev = u32(n)
		}
	}
	disk.slot = dev << 3
	// A note handler that continues, so an alarm can end a parked read of
	// the dma file with EINTR rather than end the program.
	libuser.notify(uintptr(rawptr(on_note)))

	if !find_windows() {
		libuser.exit(0x74)
	}
	if !map_function(dev) {
		libuser.exit(0x75)
	}
	if !attach_stream() {
		libuser.exit(0x76)
	}
	if !alloc_queue() {
		libuser.exit(0x77)
	}
	if !bring_up() {
		libuser.exit(0x78)
	}

	fd, perr := libuser.post("/srv/blkfs")
	if perr < 0 {
		libuser.exit(0x71)
	}
	_, why := libuser.serve(fd, handler, nil, frame_in[:], frame_out[:], payload[:])
	switch why {
	case .Removed:
		libuser.exit(0)
	case .Hangup:
		libuser.exit(0x68)
	case .Broken:
		libuser.exit(0x72)
	}
}

// -- Bring-up ----------------------------------------------------------------------------

/*
find_windows reads the host's `ranges` and keeps the two memory windows a BAR
can fall in, then opens the tree's file for each. Read-only, as every file of
the static tree is opened, and the mapping is still writable. An entry is the child's
three cells, the parent's two and the size's two: the PCI shape, which the
tree grew `mmio32` and `mmio64` from by the same rule.
*/
find_windows :: proc "contextless" () -> bool {
	fd := libuser.open(HOST + "/ranges", abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	raw: [256]u8
	n := libuser.read(int(fd), raw[:])
	libuser.close(int(fd))
	if n <= 0 || n % 28 != 0 {
		return false
	}
	for at := 0; at + 28 <= int(n); at += 28 {
		kind := be32(raw[at:]) & 0x0300_0000
		base := u64(be32(raw[at + 12:])) << 32 | u64(be32(raw[at + 16:]))
		size := u64(be32(raw[at + 20:])) << 32 | u64(be32(raw[at + 24:]))
		switch kind {
		case 0x0200_0000:
			win32 = Window{base = base, size = size, fd = -1}
		case 0x0300_0000:
			win64 = Window{base = base, size = size, fd = -1}
		}
	}
	if win32.size > 0 {
		win32.fd = int(libuser.open(HOST + "/mmio32", abi.O_RDONLY))
	}
	if win64.size > 0 {
		win64.fd = int(libuser.open(HOST + "/mmio64", abi.O_RDONLY))
	}
	return win32.fd >= 0 || win64.fd >= 0
}

/*
map_function attaches the function's configuration page out of the ECAM,
checks it is the block device, enables it as a bus master, and walks its
capabilities for the three register structures, each mapped out of the
window its BAR fell in. `docs/DISK.md` describes the modern layout this
reads; the kernel's `virtio/blk.odin` reads the same one through a
different door.
*/
map_function :: proc "contextless" (dev: u32) -> bool {
	ecam := libuser.open(HOST + "/mmio", abi.O_RDONLY)
	if ecam < 0 {
		return false
	}
	cfg, err := libuser.segattach_window(int(ecam), u64(dev) << 15, PAGE)
	if err != 0 {
		return false
	}
	disk.cfg = cfg
	if r16(cfg, CFG_VENDOR) != VENDOR || r16(cfg, CFG_DEVICE) != DEVICE {
		return false
	}
	w16(cfg, CFG_COMMAND, r16(cfg, CFG_COMMAND) | COMMAND_MEMORY | COMMAND_MASTER)

	cap := uintptr(r8(cfg, CFG_CAP_PTR))
	for cap != 0 && cap < PAGE - 16 {
		if r8(cfg, cap) == CAP_VENDOR {
			kind := r8(cfg, cap + 3)
			bar := int(r8(cfg, cap + 4))
			offset := u64(r32(cfg, cap + 8))
			length := u64(r32(cfg, cap + 12))
			if kind == CAP_COMMON || kind == CAP_NOTIFY || kind == CAP_DEVICE {
				phys, ok := bar_base(bar)
				if !ok {
					return false
				}
				va, ok2 := map_window(phys + offset, length)
				if !ok2 {
					return false
				}
				switch kind {
				case CAP_COMMON:
					disk.common = va
				case CAP_NOTIFY:
					disk.notify = va
					disk.notify_mult = r32(cfg, cap + 16)
				case CAP_DEVICE:
					disk.device = va
				}
			}
		}
		cap = uintptr(r8(cfg, cap + 1))
	}
	return disk.common != 0 && disk.notify != 0 && disk.device != 0
}

// bar_base reads a base address register, 64 bits wide when its type says so.
bar_base :: proc "contextless" (index: int) -> (u64, bool) {
	if index < 0 || index > 5 {
		return 0, false
	}
	low := r32(disk.cfg, CFG_BAR0 + uintptr(index) * 4)
	if low & 1 != 0 {
		return 0, false // a port range, not memory
	}
	phys := u64(low & ~u32(0xF))
	if low & 0x6 == 0x4 && index < 5 {
		phys |= u64(r32(disk.cfg, CFG_BAR0 + uintptr(index + 1) * 4)) << 32
	}
	return phys, phys != 0
}

// map_window attaches `bytes` at a physical address out of whichever of the
// host's windows holds it.
map_window :: proc "contextless" (phys: u64, bytes: u64) -> (uintptr, bool) {
	w: ^Window
	if win64.fd >= 0 && phys >= win64.base && phys - win64.base < win64.size {
		w = &win64
	} else if win32.fd >= 0 && phys >= win32.base && phys - win32.base < win32.size {
		w = &win32
	} else {
		return 0, false
	}
	va, err := libuser.segattach_window(w.fd, phys - w.base, bytes)
	return va, err == 0
}

// attach_stream binds the function's stream to this program's own space.
// The self case of `docs/SMMU.md` section 7: the writer is the target.
attach_stream :: proc "contextless" () -> bool {
	fd := libuser.open(HOST + "/dma", abi.O_RDWR)
	if fd < 0 {
		return false
	}
	disk.dma_fd = int(fd)
	line: [48]u8
	n := put_text(line[:], 0, "attach ")
	n = put_dec(line[:], n, u64(disk.slot))
	n = put_text(line[:], n, " ")
	n = put_dec(line[:], n, libuser.getpid())
	return libuser.write(disk.dma_fd, line[:n]) > 0
}

// alloc_queue takes the memory the device will read and write: three pages
// of rings, one of header and status, one bounce page for the sectors.
alloc_queue :: proc "contextless" () -> bool {
	base, err := libuser.segalloc(5 * PAGE)
	if err != 0 {
		return false
	}
	disk.desc = cast([^]Virtq_Desc)base
	disk.avail = cast([^]u16)(base + PAGE)
	disk.used = cast([^]u16)(base + 2 * PAGE)
	disk.header = cast(^Blk_Header)(base + 3 * PAGE)
	disk.status = cast(^u8)(base + 3 * PAGE + size_of(Blk_Header))
	disk.bounce = cast([^]u8)(base + 4 * PAGE)
	return true
}

/*
bring_up is the modern handshake, and the rebuild after a fault: reset,
acknowledge, driver, the one feature, features-ok checked, the queue's rings
named by this program's own addresses, driver-ok. The rings are zeroed
first, because the device's indexes restart at zero and the driver's must
agree.
*/
bring_up :: proc "contextless" () -> bool {
	w8(disk.common, COMMON_DEVICE_STATUS, 0)
	for r8(disk.common, COMMON_DEVICE_STATUS) != 0 {}
	set_status(STATUS_ACKNOWLEDGE)
	set_status(STATUS_DRIVER)

	w32(disk.common, COMMON_DEVICE_FEATURE_SELECT, 1)
	offered := r32(disk.common, COMMON_DEVICE_FEATURE)
	w32(disk.common, COMMON_DRIVER_FEATURE_SELECT, 0)
	w32(disk.common, COMMON_DRIVER_FEATURE, 0)
	w32(disk.common, COMMON_DRIVER_FEATURE_SELECT, 1)
	w32(disk.common, COMMON_DRIVER_FEATURE, VIRTIO_F_VERSION_1 | (offered & VIRTIO_F_ACCESS_PLATFORM))
	set_status(STATUS_FEATURES_OK)
	if r8(disk.common, COMMON_DEVICE_STATUS) & STATUS_FEATURES_OK == 0 {
		return false
	}

	zero := cast([^]u8)disk.desc
	for i in 0 ..< 3 * PAGE {
		zero[i] = 0
	}
	disk.last_used = 0

	w16(disk.common, COMMON_QUEUE_SELECT, 0)
	if r16(disk.common, COMMON_QUEUE_SIZE) == 0 {
		return false
	}
	w16(disk.common, COMMON_QUEUE_SIZE, VIRTQ_SIZE)
	w64(disk.common, COMMON_QUEUE_DESC, u64(uintptr(disk.desc)))
	w64(disk.common, COMMON_QUEUE_DRIVER, u64(uintptr(disk.avail)))
	w64(disk.common, COMMON_QUEUE_DEVICE, u64(uintptr(disk.used)))
	notify_off := r16(disk.common, COMMON_QUEUE_NOTIFY_OFF)
	disk.doorbell = disk.notify + uintptr(u32(notify_off) * disk.notify_mult)
	w16(disk.common, COMMON_QUEUE_ENABLE, 1)

	set_status(STATUS_DRIVER_OK)
	disk.capacity = u64(r32(disk.device, BLK_CAPACITY)) | u64(r32(disk.device, BLK_CAPACITY + 4)) << 32
	return disk.capacity > 0
}

set_status :: proc "contextless" (bit: u8) {
	w8(disk.common, COMMON_DEVICE_STATUS, r8(disk.common, COMMON_DEVICE_STATUS) | bit)
}

// -- The one operation --------------------------------------------------------------------

/*
transfer moves `bytes` at `addr` from or to the disk at `sector`, and answers
whether the device said OK within its patience. The three descriptors are
the kernel driver's, and the data address is whatever the caller names,
which is the point: a proof names an address the device cannot reach, and
this reports that it did not complete.
*/
transfer :: proc "contextless" (sector: u64, addr: u64, bytes: u32, write: bool) -> bool {
	disk.header^ = Blk_Header{type = write ? VIRTIO_BLK_T_OUT : VIRTIO_BLK_T_IN, sector = sector}
	disk.status^ = 0xFF
	disk.desc[0] = Virtq_Desc{addr = u64(uintptr(disk.header)), len = size_of(Blk_Header), flags = VIRTQ_DESC_NEXT, next = 1}
	disk.desc[1] = Virtq_Desc{addr = addr, len = bytes, flags = write ? VIRTQ_DESC_NEXT : VIRTQ_DESC_NEXT | VIRTQ_DESC_WRITE, next = 2}
	disk.desc[2] = Virtq_Desc{addr = u64(uintptr(disk.status)), len = 1, flags = VIRTQ_DESC_WRITE, next = 0}

	idx := disk.avail[1]
	disk.avail[2 + int(idx % VIRTQ_SIZE)] = 0
	fence()
	disk.avail[1] = idx + 1
	fence()
	w16(disk.doorbell, 0, 0)
	disk.transfers += 1

	for _ in 0 ..< SPINS {
		fence()
		if disk.used[1] != disk.last_used {
			disk.last_used = disk.used[1]
			fence()
			return disk.status^ == VIRTIO_BLK_S_OK
		}
	}
	for _ in 0 ..< PATIENCE_TICKS {
		libuser.sleep(1)
		fence()
		if disk.used[1] != disk.last_used {
			disk.last_used = disk.used[1]
			fence()
			return disk.status^ == VIRTIO_BLK_S_OK
		}
	}
	return false
}

// move copies bytes between `data` and the disk at a byte offset through the
// bounce page, a page of sectors per request, as the kernel's driver does.
// Answers how many bytes moved.
move :: proc "contextless" (offset: u64, data: []u8, write: bool) -> int {
	limit := disk.capacity * SECTOR
	if offset >= limit || len(data) == 0 {
		return 0
	}
	want := int(min(u64(len(data)), limit - offset))
	done := 0
	pos := offset
	for done < want {
		sector := pos / SECTOR
		within := int(pos % SECTOR)
		left := want - done
		nsec := min(PAGE / SECTOR, (within + left + SECTOR - 1) / SECTOR)
		take := min(nsec * SECTOR - within, left)
		run := u32(nsec * SECTOR)
		if write {
			if within != 0 || take % SECTOR != 0 {
				if !transfer(sector, u64(uintptr(disk.bounce)), run, false) {
					break
				}
			}
			for i in 0 ..< take {
				disk.bounce[within + i] = data[done + i]
			}
			if !transfer(sector, u64(uintptr(disk.bounce)), run, true) {
				break
			}
		} else {
			if !transfer(sector, u64(uintptr(disk.bounce)), run, false) {
				break
			}
			for i in 0 ..< take {
				data[done + i] = disk.bounce[within + i]
			}
		}
		done += take
		pos += u64(take)
	}
	return done
}

// -- The proofs -----------------------------------------------------------------------------

// A page-aligned address below the user ceiling that nothing here mapped.
NOWHERE :: u64(0x7000_0000)

// Ticks a fault line is waited for before the proof says there was none.
LINE_PATIENCE :: 100

// on_note is the handler every note reaches: it continues. The one note
// this program arranges is its own alarm, which ends a parked read.
on_note :: proc "c" (ureg: rawptr, note: ^u64) {
	_ = ureg
	_ = note
	libuser.noted(abi.NCONT)
}

/*
prove_unmapped aims a read at a page this program never mapped. The walker
refuses the address, the `dma` file's line says which stream, what kind,
where and which way, the device is reset and its queue rebuilt, and the
sector that carries the marker reads correctly after. The proof line says
each of those. Whether the device reported the request complete is written
down but is not the judgement: QEMU's device completes a request whose
data it could not reach, and the fault line is what says the walker
refused it.
*/
prove_unmapped :: proc "contextless" () {
	drain_lines()
	n := put_text(proof[:], 0, "unmapped: ")
	n = put_text(proof[:], n, transfer(0, NOWHERE, SECTOR, false) ? "completed, " : "refused, ")
	n = take_fault_line(n)
	if !bring_up() {
		n = put_text(proof[:], n, ", reset failed")
		proof_len = n
		return
	}
	n = put_text(proof[:], n, ", reset, ")
	if transfer(0, u64(uintptr(disk.bounce)), SECTOR, false) && disk.bounce[510] == 0x55 && disk.bounce[511] == 0xAA {
		n = put_text(proof[:], n, "recovered")
	} else {
		n = put_text(proof[:], n, "sector 0 unreadable after")
	}
	proof_len = n
}

/*
prove_freed writes a sector from a page of this program's own, so the walker
holds its translation, gives the page back with `segdetach`, and writes the
same sector from the same address again. The second write must fault: the
kernel told the walker when the page went. Under the negative control it
lands, and the line says so.
*/
prove_freed :: proc "contextless" () {
	drain_lines()
	n := put_text(proof[:], 0, "freed: ")
	page, err := libuser.segalloc(PAGE)
	if err != 0 {
		proof_len = put_text(proof[:], n, "no page")
		return
	}
	p := cast([^]u8)page
	for i in 0 ..< SECTOR {
		p[i] = u8(i * 3 + 1)
	}
	// Sector one, the scratch sector `verify_disk` uses, clear of the
	// partitions the build made.
	if !transfer(1, u64(page), SECTOR, true) {
		proof_len = put_text(proof[:], n, "first write did not land")
		return
	}
	n = put_text(proof[:], n, "written, ")
	if libuser.segdetach(page) != 0 {
		proof_len = put_text(proof[:], n, "segdetach failed")
		return
	}
	n = put_text(proof[:], n, "page freed at ")
	n = put_hex(proof[:], n, u64(page))
	n = put_text(proof[:], n, ", ")
	n = put_text(proof[:], n, transfer(1, u64(page), SECTOR, true) ? "completed, " : "refused, ")
	n = take_fault_line(n)
	if bring_up() {
		n = put_text(proof[:], n, ", reset")
	}
	proof_len = n
}

// drain_lines empties the ring before a proof, so the line the proof reads
// is its own. A device retries a transfer it could not complete, and every
// retry is a line.
drain_lines :: proc "contextless" () {
	line: [96]u8
	for _ in 0 ..< 64 {
		libuser.alarm(5)
		got := libuser.read(disk.dma_fd, line[:])
		libuser.alarm(0)
		if got <= 0 {
			return
		}
	}
}

put_hex :: proc "contextless" (b: []u8, at: int, v: u64) -> int {
	n := put_text(b, at, "0x")
	digits: [16]u8
	k := 0
	x := v
	for {
		d := u8(x & 0xF)
		digits[k] = d < 10 ? '0' + d : 'a' + d - 10
		k += 1
		x >>= 4
		if x == 0 {
			break
		}
	}
	for i := k - 1; i >= 0 && n < len(b); i -= 1 {
		b[n] = digits[i]
		n += 1
	}
	return n
}

// take_fault_line reads one line of the `dma` file into the proof. The read
// parks until a line is there, and an alarm ends the park when none comes,
// which is the control's case: the walker was told nothing, the device
// read the page, and there is no line to read.
take_fault_line :: proc "contextless" (at: int) -> int {
	line: [96]u8
	libuser.alarm(LINE_PATIENCE)
	got := libuser.read(disk.dma_fd, line[:])
	libuser.alarm(0)
	if got <= 0 {
		return put_text(proof[:], at, "no fault line")
	}
	disk.faults += 1
	end := int(got)
	if end > 0 && line[end - 1] == '\n' {
		end -= 1
	}
	return put_text(proof[:], at, string(line[:end]))
}

// -- The handler ------------------------------------------------------------------------------

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if node == NODE_ROOT || node == NODE_SD0 {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

name_of :: proc "contextless" (node: i32) -> string {
	switch node {
	case NODE_SD0:
		return "sd0"
	case NODE_DATA:
		return "data"
	case NODE_CTL:
		return "ctl"
	}
	return ""
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	switch name {
	case ".":
		return from
	case "..":
		return from == NODE_SD0 || from == NODE_ROOT ? NODE_ROOT : NODE_SD0
	}
	switch from {
	case NODE_ROOT:
		if name == "sd0" {
			return NODE_SD0
		}
	case NODE_SD0:
		switch name {
		case "data":
			return NODE_DATA
		case "ctl":
			return NODE_CTL
		}
	}
	return -1
}

handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state
	_ = s
	_ = tag
	if !libuser.default_reply(request, reply) {
		return
	}
	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)
	case vectra9.Tattach:
		libuser.attach(&fids, m, reply, NODE_ROOT, qid_of)
	case vectra9.Twalk:
		libuser.walk(&fids, m, reply, step, qid_of)
	case vectra9.Tlopen:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		libuser.fid_open(&fids, m.fid)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}
	case vectra9.Tread:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		room := min(len(buf), int(m.count))
		switch node {
		case NODE_DATA:
			n := move(m.offset, buf[:room], false)
			reply^ = vectra9.Rread{data = buf[:n]}
		case NODE_CTL:
			text: [256]u8
			n := put_dec(text[:], 0, disk.capacity)
			n = put_text(text[:], n, " sectors of 512 bytes\n")
			n = put_text(text[:], n, string(proof[:proof_len]))
			if proof_len > 0 {
				n = put_text(text[:], n, "\n")
			}
			if m.offset >= u64(n) {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			take := min(room, n - int(m.offset))
			for i in 0 ..< take {
				buf[i] = text[int(m.offset) + i]
			}
			reply^ = vectra9.Rread{data = buf[:take]}
		case:
			reply^ = vectra9.error_reply(vectra9.EISDIR)
		}
	case vectra9.Twrite:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		switch node {
		case NODE_DATA:
			n := move(m.offset, m.data, true)
			if n <= 0 {
				reply^ = vectra9.error_reply(vectra9.EIO)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(n)}
		case NODE_CTL:
			line := string(m.data)
			if len(line) > 0 && line[len(line) - 1] == '\n' {
				line = line[:len(line) - 1]
			}
			switch line {
			case "prove unmapped":
				prove_unmapped()
			case "prove freed":
				prove_freed()
			case:
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case:
			reply^ = vectra9.error_reply(vectra9.EPERM)
		}
	case vectra9.Treaddir:
		readdir(m, reply, buf)
	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := node == NODE_ROOT || node == NODE_SD0
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100666,
			nlink   = dir ? 2 : 1,
			size    = node == NODE_DATA ? disk.capacity * SECTOR : 0,
			blksize = 512,
		}
	case vectra9.Tclunk:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rclunk{}
	case vectra9.Tremove:
		// The stop, as `ramfs` stops. The dma file closes with the process,
		// and the last close gives the stream back.
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}
	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	first, last: i32
	switch node {
	case NODE_ROOT:
		first, last = NODE_SD0, NODE_SD0
	case NODE_SD0:
		first, last = NODE_DATA, NODE_CTL
	case:
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	for child := first + i32(m.offset); child <= last; child += 1 {
		if vectra9.remaining(&c) < vectra9.dirent_size(name_of(child)) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of(child),
				offset = u64(child - first + 1),
				type = child == NODE_SD0 ? vectra9.DT_DIR : vectra9.DT_REG,
				name = name_of(child),
			},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}

// -- Bytes and registers ----------------------------------------------------------------------

r8 :: proc "contextless" (base: uintptr, off: uintptr) -> u8 {
	return intrinsics.volatile_load(cast(^u8)(base + off))
}
w8 :: proc "contextless" (base: uintptr, off: uintptr, v: u8) {
	intrinsics.volatile_store(cast(^u8)(base + off), v)
}
r16 :: proc "contextless" (base: uintptr, off: uintptr) -> u16 {
	return intrinsics.volatile_load(cast(^u16)(base + off))
}
w16 :: proc "contextless" (base: uintptr, off: uintptr, v: u16) {
	intrinsics.volatile_store(cast(^u16)(base + off), v)
}
r32 :: proc "contextless" (base: uintptr, off: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(base + off))
}
w32 :: proc "contextless" (base: uintptr, off: uintptr, v: u32) {
	intrinsics.volatile_store(cast(^u32)(base + off), v)
}
w64 :: proc "contextless" (base: uintptr, off: uintptr, v: u64) {
	w32(base, off, u32(v))
	w32(base, off + 4, u32(v >> 32))
}

fence :: proc "contextless" () {
	intrinsics.atomic_thread_fence(.Seq_Cst)
}

be32 :: proc "contextless" (b: []u8) -> u32 #no_bounds_check {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

parse_uint :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v * 10 + u64(c - '0')
	}
	return v, true
}

put_text :: proc "contextless" (b: []u8, at: int, s: string) -> int {
	n := at
	for i in 0 ..< len(s) {
		if n >= len(b) {
			break
		}
		b[n] = s[i]
		n += 1
	}
	return n
}

put_dec :: proc "contextless" (b: []u8, at: int, v: u64) -> int {
	tmp: [20]u8
	k := 0
	x := v
	for {
		tmp[k] = u8('0' + x % 10)
		k += 1
		x /= 10
		if x == 0 {
			break
		}
	}
	n := at
	for i := k - 1; i >= 0 && n < len(b); i -= 1 {
		b[n] = tmp[i]
		n += 1
	}
	return n
}
