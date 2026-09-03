/*
`#S`: the storage device, a disk as files under `/dev/sd0`.

A block driver moves sectors; a person and a program move files. This device
is the join between them, Plan 9's `#S` and `9front`'s `sd`. Each disk the
virtio driver brought up is a directory:

    /dev/sd0/data    the whole disk, byte-addressable, read and write
    /dev/sd0/ctl     one line of geometry: the sector count and the size
    /dev/sd0/esp     a partition, when the disk has a table naming one
    /dev/sd0/dos     its neighbours, one file each

`data` is the disk with no interpretation. The partition files are windows
onto it, read out of the MBR at sector zero: a file that begins where its
partition begins and is as long as the partition is. Writing `/dev/sd0/esp`
writes inside that window and cannot reach past it, which is the whole reason
`disk/prep` hands a filesystem a partition rather than the disk.

## Bound into `/dev`

`#S` is a union member of `/dev`, searched after `#c`. `/dev/cons` is the
console device's; `/dev/sd0` is this one's; neither knows about the other.

## Synchronous, but not under the fid lock

A read is a disk transfer, which the virtio driver does by polling. The poll
does not sleep, so it would be safe under the device's spinlock, but it can
take a while, and a spinlock held across it stalls every other core. So the
fid is resolved under the lock, the lock is dropped, and the transfer happens
on the calling thread's own stack, the way `kernel/procfs` renders a status
line. A bounce page carries the sectors, because a caller's buffer is not
always where the device can reach by physical address.
*/
package sd

import "base:runtime"

import "kernel:drivers/virtio"
import "kernel:mem"
import "kernel:sync"
import "kernel:vfs"
import "vsys:libodin"
import "vsys:vectra9"

SD_MAX_FIDS :: 64
SECTOR :: 512

// Partitions a disk may name past `data` and `ctl`. The MBR holds four.
MAX_PARTS :: 4

S_IFDIR :: u32(0o040000)
S_IFREG :: u32(0o100000)

// A file kind within a disk directory. `Data` and `Ctl` first, then the
// partitions, so a node's file field past `Ctl` is a partition index.
FILE_DIR :: 0
FILE_DATA :: 1
FILE_CTL :: 2
FILE_PART0 :: 3

Partition :: struct {
	name:    [16]u8,
	len:     int,
	start:   u64, // First sector
	sectors: u64, // How many
}

Disk :: struct {
	present: bool,
	sectors: u64,
	parts:   [MAX_PARTS]Partition,
	nparts:  int,
}

@(private = "file")
Sd_Device :: struct {
	disks:  [virtio.MAX_DISKS]Disk,
	fids:   vfs.Fid_Table,
	lock:   sync.Spinlock,
	server: vfs.Server,
	reads:  u64,
	writes: u64,
}

@(private = "file")
dev: Sd_Device

/*
init brings up `#S` for every disk the virtio driver found, reads each one's
partition table, and binds the tree into `/dev` as a union member after the
console. A machine with no disk still calls this; the tree is then an empty
directory, which is the honest thing for it to be.
*/
init :: proc(ns: ^vfs.Namespace) -> vfs.Errno {
	d := &dev
	for i in 0 ..< virtio.MAX_DISKS {
		if virtio.present(i) {
			d.disks[i] = Disk {
				present = true,
				sectors = virtio.capacity(i),
			}
			read_table(i)
		}
	}
	if !vfs.fidtab_init(&d.fids, SD_MAX_FIDS) {
		return vectra9.ENOMEM
	}
	if err := vfs.server_init(&d.server, "S", sd_handler, d); err != .None {
		vfs.fidtab_destroy(&d.fids)
		return vectra9.EPROTO
	}
	if !vfs.register_device(&d.server) {
		vfs.fidtab_destroy(&d.fids)
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#S", "/dev", .After)
}

// disk_count and part_count report what came up, for the boot line.
disk_count :: proc "contextless" () -> int {
	n := 0
	for i in 0 ..< virtio.MAX_DISKS {
		if dev.disks[i].present {
			n += 1
		}
	}
	return n
}

part_count :: proc "contextless" () -> (n: int) {
	for i in 0 ..< virtio.MAX_DISKS {
		if dev.disks[i].present {
			n += dev.disks[i].nparts
		}
	}
	return
}

stats :: proc "contextless" () -> (reads, writes: u64) {
	g := sync.acquire(&dev.lock)
	defer sync.release(&dev.lock, g)
	return dev.reads, dev.writes
}

// -- The partition table ------------------------------------------------------

MBR_SIGNATURE :: u16(0xAA55)
MBR_TABLE :: 446
MBR_ENTRY :: 16

/*
read_table reads sector zero and, if it is a master boot record rather than a
volume boot record, fills the disk's partition list from it.

The two are told apart with care, because a FAT filesystem's own boot sector
also ends in the `0x55AA` signature. An MBR's bootstrap area begins with code
or zero; a FAT volume's begins with a jump instruction, `0xEB` or `0xE9`. A
sector that jumps is a filesystem, not a table, and its partition-entry region
is really the BIOS parameter block. Each entry that survives that test names a
partition: a status of `0x00` or `0x80`, a non-zero type, and a run inside the
disk.
*/
@(private = "file")
read_table :: proc(n: int) {
	sector: [SECTOR]u8
	if !read_sectors(n, 0, sector[:]) {
		return
	}
	if u16(sector[510]) | u16(sector[511]) << 8 != MBR_SIGNATURE {
		return
	}
	if sector[0] == 0xEB || sector[0] == 0xE9 {
		return // A volume boot record, not a partition table.
	}
	disk := &dev.disks[n]
	for i in 0 ..< 4 {
		base := MBR_TABLE + i * MBR_ENTRY
		status := sector[base]
		kind := sector[base + 4]
		if (status != 0x00 && status != 0x80) || kind == 0 {
			continue
		}
		start := le32(sector[base + 8:])
		length := le32(sector[base + 12:])
		if start == 0 || length == 0 || u64(start) + u64(length) > disk.sectors {
			continue
		}
		p := &disk.parts[disk.nparts]
		p.start = u64(start)
		p.sectors = u64(length)
		p.len = part_name(kind, disk.nparts, p.name[:])
		disk.nparts += 1
	}
}

// part_name gives a partition a Plan 9-ish name from its MBR type: the EFI
// system partition is `esp`, a FAT type is `dos`, anything else `partN`.
@(private = "file")
part_name :: proc "contextless" (kind: u8, index: int, out: []u8) -> int {
	name: string
	switch kind {
	case 0xEF:
		name = "esp"
	case 0x0B, 0x0C, 0x01, 0x04, 0x06, 0x0E:
		name = "dos"
	case:
		sink := libodin.sink_from(out)
		libodin.put_str(&sink, "part")
		libodin.put_uint(&sink, u64(index + 1))
		return len(libodin.str(&sink))
	}
	return copy(out, name)
}

@(private = "file")
le32 :: proc "contextless" (b: []u8) -> u32 #no_bounds_check {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

// -- Bytes on and off the disk ------------------------------------------------

// read_sectors reads `len(out)/SECTOR` sectors from `first` into `out`
// through a bounce page the device can reach. `out` must be sector-sized.
@(private = "file")
read_sectors :: proc(n: int, first: u64, out: []u8) -> bool #no_bounds_check {
	phys, ok := mem.alloc_page()
	if !ok {
		return false
	}
	defer mem.free_page(phys)
	bounce := (cast([^]u8)mem.phys_to_virt(phys))[:mem.PAGE_SIZE]

	done := 0
	sector := first
	for done < len(out) {
		chunk := min(len(out) - done, mem.PAGE_SIZE)
		chunk -= chunk % SECTOR
		if chunk == 0 {
			break
		}
		if !virtio.read(n, sector, bounce[:chunk]) {
			return false
		}
		copy(out[done:done + chunk], bounce[:chunk])
		done += chunk
		sector += u64(chunk / SECTOR)
	}
	return done == len(out)
}

@(private = "file")
write_sectors :: proc(n: int, first: u64, in_buf: []u8) -> bool #no_bounds_check {
	phys, ok := mem.alloc_page()
	if !ok {
		return false
	}
	defer mem.free_page(phys)
	bounce := (cast([^]u8)mem.phys_to_virt(phys))[:mem.PAGE_SIZE]

	done := 0
	sector := first
	for done < len(in_buf) {
		chunk := min(len(in_buf) - done, mem.PAGE_SIZE)
		chunk -= chunk % SECTOR
		if chunk == 0 {
			break
		}
		copy(bounce[:chunk], in_buf[done:done + chunk])
		if !virtio.write(n, sector, bounce[:chunk]) {
			return false
		}
		done += chunk
		sector += u64(chunk / SECTOR)
	}
	return done == len(in_buf)
}

/*
read_bytes reads `len(out)` bytes from byte `offset` of the window `[base,
base+span)` sectors, the general read a data or partition file wants. It
reads the covering sectors into a scratch page and copies out the slice, so
an unaligned offset or count is handled without the caller knowing sectors
exist. Answers how many bytes it placed, which is short at the window's end.
*/
@(private = "file")
read_bytes :: proc(n: int, base, span: u64, offset: u64, out: []u8) -> int #no_bounds_check {
	limit := span * SECTOR
	if offset >= limit {
		return 0
	}
	want := min(u64(len(out)), limit - offset)

	scratch: [SECTOR]u8
	got := 0
	pos := offset
	for u64(got) < want {
		sector := base + pos / SECTOR
		within := int(pos % SECTOR)
		if !read_sectors(n, sector, scratch[:]) {
			break
		}
		take := min(SECTOR - within, int(want) - got)
		copy(out[got:got + take], scratch[within:within + take])
		got += take
		pos += u64(take)
	}
	return got
}

/*
write_bytes writes `len(in_buf)` bytes at byte `offset` of the window,
read-modify-writing the two end sectors an unaligned range shares with its
neighbours so nothing outside the range changes. Answers how many bytes it
wrote, which is short at the window's end.
*/
@(private = "file")
write_bytes :: proc(n: int, base, span: u64, offset: u64, in_buf: []u8) -> int #no_bounds_check {
	limit := span * SECTOR
	if offset >= limit {
		return 0
	}
	want := min(u64(len(in_buf)), limit - offset)

	scratch: [SECTOR]u8
	put := 0
	pos := offset
	for u64(put) < want {
		sector := base + pos / SECTOR
		within := int(pos % SECTOR)
		take := min(SECTOR - within, int(want) - put)
		if within != 0 || take != SECTOR {
			// A partial sector: read it, change the slice, write it back.
			if !read_sectors(n, sector, scratch[:]) {
				break
			}
		}
		copy(scratch[within:within + take], in_buf[put:put + take])
		if !write_sectors(n, sector, scratch[:]) {
			break
		}
		put += take
		pos += u64(take)
	}
	return put
}

// -- Nodes --------------------------------------------------------------------

ROOT :: i32(0)

// node_of encodes a disk and a file into a fid node, past the root.
@(private = "file")
node_of :: proc "contextless" (disk, file: int) -> i32 {
	return i32(1 + disk * 64 + file)
}

@(private = "file")
split :: proc "contextless" (node: i32) -> (disk, file: int) {
	v := int(node - 1)
	return v / 64, v % 64
}

// window returns the sector range a data or partition file spans, and
// whether the node names one at all.
@(private = "file")
window :: proc "contextless" (disk, file: int) -> (base, span: u64, ok: bool) {
	dk := &dev.disks[disk]
	if !dk.present {
		return
	}
	switch {
	case file == FILE_DATA:
		return 0, dk.sectors, true
	case file >= FILE_PART0 && file - FILE_PART0 < dk.nparts:
		p := &dk.parts[file - FILE_PART0]
		return p.start, p.sectors, true
	}
	return
}

@(private = "file")
node_is_dir :: proc "contextless" (node: i32) -> bool {
	if node == ROOT {
		return true
	}
	_, file := split(node)
	return file == FILE_DIR
}

@(private = "file")
node_live :: proc "contextless" (node: i32) -> bool {
	if node == ROOT {
		return true
	}
	disk, file := split(node)
	if disk < 0 || disk >= virtio.MAX_DISKS || !dev.disks[disk].present {
		return false
	}
	switch file {
	case FILE_DIR, FILE_DATA, FILE_CTL:
		return true
	case:
		return file - FILE_PART0 < dev.disks[disk].nparts
	}
}

@(private = "file")
qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if node_is_dir(node) {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

// file_name is the name of a disk-directory entry, or "" for a partition
// index the disk does not have.
@(private = "file")
file_name :: proc "contextless" (disk, file: int, out: []u8) -> int {
	switch file {
	case FILE_DATA:
		return copy(out, "data")
	case FILE_CTL:
		return copy(out, "ctl")
	case:
		idx := file - FILE_PART0
		if idx < 0 || idx >= dev.disks[disk].nparts {
			return 0
		}
		p := &dev.disks[disk].parts[idx]
		return copy(out, p.name[:p.len])
	}
}

// -- The server ---------------------------------------------------------------

@(private = "file")
sd_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) {
	_ = server
	_ = s
	_ = tag
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	context = ctx

	// A read or a write is a disk transfer: resolve the fid under the lock,
	// then move bytes with it dropped, as the file comment explains.
	#partial switch m in request^ {
	case vectra9.Tread:
		do_read(m, reply, buf)
		return
	case vectra9.Twrite:
		do_write(m, reply)
		return
	}
	dispatch(request, reply, buf)
}

@(private = "file")
dispatch :: proc(request: ^vectra9.Msg, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)
	if vectra9.creates(vectra9.kind(request^)) {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}

	g := sync.acquire(&d.lock)
	defer sync.release(&d.lock, g)

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply)

	case vectra9.Tattach:
		if !vfs.fidtab_bind(&d.fids, m.fid, ROOT) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = qid_of(ROOT)}

	case vectra9.Twalk:
		walk(m, reply)

	case vectra9.Tlopen:
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if !node_live(node) {
			reply^ = vectra9.error_reply(vectra9.ENXIO)
			return
		}
		if node_is_dir(node) && m.flags & 0o3 != vfs.O_RDONLY {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		vfs.fidtab_set_open(&d.fids, m.fid, true)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tgetattr:
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if !node_live(node) {
			reply^ = vectra9.error_reply(vectra9.ENXIO)
			return
		}
		reply^ = attr_of(node, m.request_mask)

	case vectra9.Tstatfs:
		if vfs.fidtab_node(&d.fids, m.fid) < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = vectra9.Rstatfs{type = 0x0139_9249, bsize = SECTOR, namelen = 16}

	case vectra9.Tremove:
		_ = vfs.fidtab_release(&d.fids, m.fid)
		reply^ = vectra9.error_reply(vectra9.EPERM)

	case vectra9.Tclunk:
		_ = vfs.fidtab_release(&d.fids, m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

@(private = "file")
attr_of :: proc "contextless" (node: i32, mask: u64) -> vectra9.Rgetattr {
	dir := node_is_dir(node)
	mode: u32
	size: u64
	if dir {
		mode = S_IFDIR | 0o555
	} else {
		disk, file := split(node)
		switch file {
		case FILE_CTL:
			mode = S_IFREG | 0o444
		case:
			mode = S_IFREG | 0o666
			if base, span, ok := window(disk, file); ok {
				_ = base
				size = span * SECTOR
			}
		}
	}
	attr := vectra9.Rgetattr {
		valid   = mask & vfs.GETATTR_BASIC,
		qid     = qid_of(node),
		mode    = mode,
		nlink   = dir ? 2 : 1,
		size    = size,
		blksize = SECTOR,
	}
	attr.blocks = (size + SECTOR - 1) / SECTOR
	return attr
}

// do_read answers a Tread: the fid under the lock, the bytes after it.
@(private = "file")
do_read :: proc(m: vectra9.Tread, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	g := sync.acquire(&d.lock)
	node := vfs.fidtab_node(&d.fids, m.fid)
	open := node >= 0 && vfs.fidtab_is_open(&d.fids, m.fid)
	sync.release(&d.lock, g)

	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !open {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	if node_is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.EISDIR)
		return
	}
	disk, file := split(node)
	if !node_live(node) {
		reply^ = vectra9.error_reply(vectra9.ENXIO)
		return
	}

	room := min(len(buf), int(m.count))
	if file == FILE_CTL {
		read_ctl(disk, m.offset, buf[:room], reply)
		return
	}
	base, span, ok := window(disk, file)
	if !ok {
		reply^ = vectra9.error_reply(vectra9.ENXIO)
		return
	}
	n := read_bytes(disk, base, span, m.offset, buf[:room])
	if n < 0 {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	g2 := sync.acquire(&d.lock)
	d.reads += 1
	sync.release(&d.lock, g2)
	reply^ = vectra9.Rread{data = buf[:n]}
}

@(private = "file")
read_ctl :: proc(disk: int, offset: u64, buf: []u8, reply: ^vectra9.Msg) #no_bounds_check {
	text: [128]u8
	sink := libodin.sink_from(text[:])
	libodin.put_str(&sink, "geometry ")
	libodin.put_uint(&sink, dev.disks[disk].sectors)
	libodin.put_str(&sink, " ")
	libodin.put_uint(&sink, SECTOR)
	libodin.put_str(&sink, "\n")
	rendered := libodin.str(&sink)
	if offset >= u64(len(rendered)) {
		reply^ = vectra9.Rread{data = nil}
		return
	}
	start := int(offset)
	end := min(len(rendered), start + len(buf))
	n := copy(buf, rendered[start:end])
	reply^ = vectra9.Rread{data = buf[:n]}
}

@(private = "file")
do_write :: proc(m: vectra9.Twrite, reply: ^vectra9.Msg) #no_bounds_check {
	d := &dev
	g := sync.acquire(&d.lock)
	node := vfs.fidtab_node(&d.fids, m.fid)
	open := node >= 0 && vfs.fidtab_is_open(&d.fids, m.fid)
	sync.release(&d.lock, g)

	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !open {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	if node_is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.EISDIR)
		return
	}
	disk, file := split(node)
	if file == FILE_CTL {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}
	if !node_live(node) {
		reply^ = vectra9.error_reply(vectra9.ENXIO)
		return
	}
	base, span, ok := window(disk, file)
	if !ok {
		reply^ = vectra9.error_reply(vectra9.ENXIO)
		return
	}
	n := write_bytes(disk, base, span, m.offset, m.data)
	if n <= 0 && len(m.data) > 0 {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	g2 := sync.acquire(&d.lock)
	d.writes += 1
	sync.release(&d.lock, g2)
	reply^ = vectra9.Rwrite{count = u32(n)}
}

@(private = "file")
walk :: proc(m: vectra9.Twalk, reply: ^vectra9.Msg) #no_bounds_check {
	d := &dev
	node := vfs.fidtab_node(&d.fids, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if vfs.fidtab_is_open(&d.fids, m.fid) {
		reply^ = vectra9.error_reply(vectra9.EBUSY)
		return
	}
	answer: vectra9.Rwalk
	cur := node
	for i in 0 ..< m.count {
		next := step(cur, m.names[i])
		if next < 0 {
			if i == 0 {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
			break
		}
		cur = next
		answer.qids[answer.count] = qid_of(cur)
		answer.count += 1
	}
	if answer.count == m.count {
		if !vfs.fidtab_bind(&d.fids, m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}

// step resolves one name: a disk name from the root, a file name from a
// disk directory. `..` climbs to the disk directory or the root.
@(private = "file")
step :: proc "contextless" (from: i32, name: string) -> i32 {
	if name == "." {
		return from
	}
	if from == ROOT {
		if name == ".." {
			return ROOT
		}
		if disk, ok := disk_named(name); ok {
			return node_of(disk, FILE_DIR)
		}
		return -1
	}
	disk, file := split(from)
	if file != FILE_DIR {
		return -1
	}
	if name == ".." {
		return ROOT
	}
	if name == "data" {
		return node_of(disk, FILE_DATA)
	}
	if name == "ctl" {
		return node_of(disk, FILE_CTL)
	}
	dk := &dev.disks[disk]
	for i in 0 ..< dk.nparts {
		p := &dk.parts[i]
		if string(p.name[:p.len]) == name {
			return node_of(disk, FILE_PART0 + i)
		}
	}
	return -1
}

// disk_named parses `sd<n>` and reports whether that disk is present.
@(private = "file")
disk_named :: proc "contextless" (name: string) -> (disk: int, ok: bool) {
	if len(name) != 3 || name[0] != 's' || name[1] != 'd' {
		return
	}
	c := name[2]
	if c < '0' || c > '9' {
		return
	}
	disk = int(c - '0')
	if disk < 0 || disk >= virtio.MAX_DISKS || !dev.disks[disk].present {
		return 0, false
	}
	return disk, true
}

@(private = "file")
readdir :: proc(m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	node := vfs.fidtab_node(&d.fids, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !vfs.fidtab_is_open(&d.fids, m.fid) {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	if !node_is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	name: [16]u8

	if node == ROOT {
		// One entry per present disk, cookie the disk index plus one.
		for i := int(m.offset); i < virtio.MAX_DISKS; i += 1 {
			if !d.disks[i].present {
				continue
			}
			sink := libodin.sink_from(name[:])
			libodin.put_str(&sink, "sd")
			libodin.put_uint(&sink, u64(i))
			entry := libodin.str(&sink)
			if vectra9.remaining(&c) < vectra9.dirent_size(entry) {
				break
			}
			vectra9.put_dirent(
				&c,
				vectra9.Dirent{qid = qid_of(node_of(i, FILE_DIR)), offset = u64(i + 1), type = vectra9.DT_DIR, name = entry},
			)
		}
	} else {
		disk, _ := split(node)
		if !d.disks[disk].present {
			reply^ = vectra9.error_reply(vectra9.ENXIO)
			return
		}
		last := FILE_PART0 + d.disks[disk].nparts
		for i := int(m.offset) + 1; i < last; i += 1 {
			n := file_name(disk, i, name[:])
			if n == 0 {
				continue
			}
			entry := string(name[:n])
			if vectra9.remaining(&c) < vectra9.dirent_size(entry) {
				break
			}
			t := vectra9.DT_REG
			vectra9.put_dirent(
				&c,
				vectra9.Dirent{qid = qid_of(node_of(disk, i)), offset = u64(i), type = t, name = entry},
			)
		}
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
