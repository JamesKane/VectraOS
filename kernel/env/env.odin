/*
`#e`: the environment device, a kernel device whose files are variables.

Plan 9 keeps a process's environment in a device rather than in the process.
`/env/path` is a file, `cat /env/path` reads it, `echo -n /bin > /env/path`
sets it, and `rm /env/path` unsets it. A shell is a client of this directory
like any other program, and what it keeps there is what every program it
starts sees. `rc` puts `$path`, `$prompt`, `$status` and every `x=y` in it.

## One group per process

The directory a process sees is its *environment group*. A group is a
table of variables with a reference count, and a process holds one. The
holding is `kernel/user`'s business, with the same rules as a descriptor
table:

    spawn      the child gets a copy, so a shell's `x=y cmd` reaches one
               command and not the shell
    rfork      shared by default, copied under `RFENVG`, empty under
               `RFCENVG`, like descriptors under `RFFDG` and `RFCFDG`
    exec       kept; the program changes and the environment does not
    exit       one holder gone, and the last one frees the variables

The device is one server for every group. A message names a fid and a fid
names a variable in some group, but the *root* is the caller's: a walk from
it, a listing of it and a create in it all look up the group of the process
asking, through the resolver `kernel/user` registers. The device knows
nothing about processes and does not need to. That is the same door
`kernel/srv` opens for a descriptor number.

## What a fid names

    root       0, whoever asks
    variable   group slot << 16 | id

An id is monotonic within its group and never reused, so a fid opened on a
variable that is then removed and recreated under the same name names
nothing rather than the newcomer. A listing's cookie is the id, for the
reason `kernel/srv` gives: a directory that changes cannot use a position.

## Reads and writes

A variable is a byte array up to `VALUE_MAX`. A read is the bytes from the
offset. A write at an offset overwrites and extends, an open with `O_TRUNC`
empties first, and a `wstat` of the length truncates or zero-fills. That is
Plan 9's `devenv` to the letter, and it is what makes `echo x > /env/y`
replace and `>>` append without the device knowing which a shell meant.

Synchronous, like `#s`: every message is a table operation, and nothing in
it waits.
*/
package env

import "base:runtime"

import "kernel:mem"
import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

// How many groups may exist at once. One per process at the ceiling, plus
// slack for a fork that holds a fresh copy beside the one it copies from.
// `kernel/user` has twelve process slots; this does not import it to say so.
MAX_GROUPS :: 16

// How many variables a group holds, and how long a name or a value may be.
MAX_VARS :: 32
MAX_NAME :: 64
VALUE_MAX :: 4096

// Client fids at once, across every process. A process that walks `/env`
// holds one per open file there.
ENV_MAX_FIDS :: 64

// Plan 9's `env` files are `0666`, and its directory `0777`: the environment
// is the process's own to change. Linux bits, because 9P2000.L carries them.
S_IFDIR :: u32(0o040000)
S_IFREG :: u32(0o100000)

Var :: struct {
	id:      i32,
	name:    [MAX_NAME]u8,
	len:     int,
	// The value, from the heap, and how much of it is set. `cap(data)` is
	// what the last growth allocated, so a shrink frees nothing.
	data:    []u8,
	size:    int,
	version: u32,
}

Group :: struct {
	refs:    int,
	vars:    [MAX_VARS]Var,
	count:   int,
	next_id: i32,
}

@(private = "file")
Group_Slot :: struct {
	group: Group,
	used:  bool,
}

// Who is asking. Registered by `kernel/user`, which owns the process table;
// the device runs in the caller's thread, so `current process` is defined.
Group_Resolver :: proc "contextless" () -> ^Group

@(private = "file")
Env_Device :: struct {
	slots:    [MAX_GROUPS]Group_Slot,
	live:     int,
	fids:     vfs.Fid_Table,
	// Guards every group and the fid table. Never held across a message.
	lock:     sync.Spinlock,
	resolver: Group_Resolver,
	server:   vfs.Server,
	writes:   u64,
	removes:  u64,
}

@(private = "file")
dev: Env_Device

/*
init brings `#e` up and binds it at `/env`. Nothing is in any group yet; the
first process to write a variable puts it there.
*/
init :: proc(ns: ^vfs.Namespace) -> vfs.Errno {
	d := &dev
	if !vfs.fidtab_init(&d.fids, ENV_MAX_FIDS) {
		return vectra9.ENOMEM
	}
	if err := vfs.server_init(&d.server, "e", env_handler, d); err != .None {
		vfs.fidtab_destroy(&d.fids)
		return vectra9.EPROTO
	}
	if !vfs.register_device(&d.server) {
		vfs.fidtab_destroy(&d.fids)
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#e", "/env")
}

set_group_resolver :: proc "contextless" (r: Group_Resolver) {
	dev.resolver = r
}

// live reports how many groups are held, for the balance checks.
live :: proc "contextless" () -> int {
	g := sync.acquire(&dev.lock)
	defer sync.release(&dev.lock, g)
	return dev.live
}

// stats reports what this device did: writes and removes, so a table that
// ends where it started still shows what happened in between.
stats :: proc "contextless" () -> (writes: u64, removes: u64) {
	g := sync.acquire(&dev.lock)
	defer sync.release(&dev.lock, g)
	return dev.writes, dev.removes
}

// -- Groups, as `kernel/user` holds them -------------------------------------

// new_group claims an empty group with one reference.
new_group :: proc "contextless" () -> ^Group {
	g := sync.acquire(&dev.lock)
	defer sync.release(&dev.lock, g)
	return claim()
}

@(private = "file")
claim :: proc "contextless" () -> ^Group #no_bounds_check {
	for i in 0 ..< MAX_GROUPS {
		if !dev.slots[i].used {
			dev.slots[i].used = true
			dev.slots[i].group = Group {
				refs    = 1,
				next_id = 1,
			}
			dev.live += 1
			return &dev.slots[i].group
		}
	}
	return nil
}

// incref is one more process on the same group.
incref :: proc "contextless" (grp: ^Group) {
	if grp == nil {
		return
	}
	g := sync.acquire(&dev.lock)
	grp.refs += 1
	sync.release(&dev.lock, g)
}

/*
release is one holder gone, and the last one frees the variables.

The frees happen with the lock held, because the heap's own lock is a
spinlock and nests, and because a slot given back with values still
attached would hand them to the next `new_group`. Nothing here parks.
*/
release :: proc(grp: ^Group) #no_bounds_check {
	if grp == nil {
		return
	}
	g := sync.acquire(&dev.lock)
	defer sync.release(&dev.lock, g)
	grp.refs -= 1
	if grp.refs > 0 {
		return
	}
	for i in 0 ..< MAX_VARS {
		if grp.vars[i].id != 0 {
			delete(grp.vars[i].data, mem.allocator())
		}
	}
	for i in 0 ..< MAX_GROUPS {
		if &dev.slots[i].group == grp {
			dev.slots[i].used = false
			dev.slots[i].group = Group{}
			break
		}
	}
	dev.live -= 1
}

/*
copy_group fills a fresh group with another's variables, value for value.
`RFENVG`, and what a spawn gives its child. Ids start over: the copy is a
new directory, and a fid on the original names nothing in it.

Nil when the pool or the heap is out, and then nothing was taken.
*/
copy_group :: proc(src: ^Group) -> ^Group #no_bounds_check {
	g := sync.acquire(&dev.lock)
	defer sync.release(&dev.lock, g)
	fresh := claim()
	if fresh == nil || src == nil {
		return fresh
	}
	for i in 0 ..< MAX_VARS {
		s := &src.vars[i]
		if s.id == 0 {
			continue
		}
		v := &fresh.vars[fresh.count]
		v^ = Var {
			id  = fresh.next_id,
			len = s.len,
		}
		v.name = s.name
		if s.size > 0 {
			v.data = make([]u8, s.size, mem.allocator())
			if v.data == nil {
				v.id = 0
				release_locked(fresh)
				return nil
			}
			copy(v.data, s.data[:s.size])
			v.size = s.size
		}
		fresh.next_id += 1
		fresh.count += 1
	}
	return fresh
}

// release_locked is `release` for a caller already under the lock.
@(private = "file")
release_locked :: proc(grp: ^Group) #no_bounds_check {
	for i in 0 ..< MAX_VARS {
		if grp.vars[i].id != 0 {
			delete(grp.vars[i].data, mem.allocator())
		}
	}
	for i in 0 ..< MAX_GROUPS {
		if &dev.slots[i].group == grp {
			dev.slots[i].used = false
			dev.slots[i].group = Group{}
			break
		}
	}
	dev.live -= 1
}

/*
lookup reads one variable out of a group into `out`, for the kernel's own
use: a boot check, or a loader that wants `$path`. The length set, or -1
for no such name. Truncated to `out` without saying so, like a short read.
*/
lookup :: proc "contextless" (grp: ^Group, name: string, out: []u8) -> int #no_bounds_check {
	if grp == nil {
		return -1
	}
	g := sync.acquire(&dev.lock)
	defer sync.release(&dev.lock, g)
	i := var_named(grp, name)
	if i < 0 {
		return -1
	}
	n := min(len(out), grp.vars[i].size)
	copy(out[:n], grp.vars[i].data[:n])
	return n
}

// -- The device -------------------------------------------------------------

ROOT_ID :: i32(0)

@(private = "file")
node_of :: proc "contextless" (slot: int, id: i32) -> i32 {
	return i32(slot) << 16 | id
}

// var_of resolves a node to its variable, or nil for a node that names
// nothing any more. Caller holds `lock`.
@(private = "file")
var_of :: proc "contextless" (node: i32) -> ^Var #no_bounds_check {
	slot := int(node >> 16)
	id := node & 0xFFFF
	if slot < 0 || slot >= MAX_GROUPS || !dev.slots[slot].used || id == 0 {
		return nil
	}
	grp := &dev.slots[slot].group
	for i in 0 ..< MAX_VARS {
		if grp.vars[i].id == id {
			return &grp.vars[i]
		}
	}
	return nil
}

@(private = "file")
slot_of_group :: proc "contextless" (grp: ^Group) -> int #no_bounds_check {
	for i in 0 ..< MAX_GROUPS {
		if &dev.slots[i].group == grp {
			return i
		}
	}
	return -1
}

// var_named is the index in `grp` of the live variable `name`, or -1.
@(private = "file")
var_named :: proc "contextless" (grp: ^Group, name: string) -> int #no_bounds_check {
	for i in 0 ..< MAX_VARS {
		v := &grp.vars[i]
		if v.id != 0 && v.len == len(name) && string(v.name[:v.len]) == name {
			return i
		}
	}
	return -1
}

@(private = "file")
valid_name :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_NAME || name == "." || name == ".." {
		return false
	}
	for i in 0 ..< len(name) {
		if name[i] == '/' || name[i] < 0x20 {
			return false
		}
	}
	return true
}

@(private = "file")
qid_of :: proc "contextless" (node: i32, v: ^Var) -> vectra9.Qid {
	if node == ROOT_ID {
		return vectra9.Qid{kind = {.Dir}, path = 1}
	}
	q := vectra9.Qid{path = u64(node) + 1}
	if v != nil {
		q.version = v.version
	}
	return q
}

// caller is the group of the process asking, or nil when nothing registered
// a resolver or the caller is not a process.
@(private = "file")
caller :: proc "contextless" () -> ^Group {
	if dev.resolver == nil {
		return nil
	}
	return dev.resolver()
}

@(private = "file")
env_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) {
	_ = s
	_ = tag
	_ = server
	// A context, because a write may grow a value and growth is an
	// allocation. Built once here rather than in the arm.
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	context = ctx
	env_dispatch(request, reply, buf)
}

@(private = "file")
env_dispatch :: proc(request: ^vectra9.Msg, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	g := sync.acquire(&d.lock)
	defer sync.release(&d.lock, g)

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply)

	case vectra9.Tattach:
		if !vfs.fidtab_bind(&d.fids, m.fid, ROOT_ID) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = qid_of(ROOT_ID, nil)}

	case vectra9.Twalk:
		env_walk(m, reply)

	case vectra9.Tlcreate:
		/*
		Setting a variable, step one: the name comes to exist, empty. The fid
		arrives on the root and leaves on the variable, open. A name already
		in the group is EEXIST, as Plan 9 answers; the shell opens it with
		`O_TRUNC` instead.
		*/
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if node != ROOT_ID {
			reply^ = vectra9.error_reply(vectra9.ENOTDIR)
			return
		}
		grp := caller()
		if grp == nil {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		if !valid_name(m.name) {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		if var_named(grp, m.name) >= 0 {
			reply^ = vectra9.error_reply(vectra9.EEXIST)
			return
		}
		free := -1
		for i in 0 ..< MAX_VARS {
			if grp.vars[i].id == 0 {
				free = i
				break
			}
		}
		if free < 0 || grp.next_id >= 0xFFFF {
			reply^ = vectra9.error_reply(vectra9.ENOSPC)
			return
		}
		v := &grp.vars[free]
		v^ = Var {
			id  = grp.next_id,
			len = len(m.name),
		}
		copy(v.name[:], m.name)
		grp.next_id += 1
		grp.count += 1
		new_node := node_of(slot_of_group(grp), v.id)
		_ = vfs.fidtab_bind(&d.fids, m.fid, new_node)
		vfs.fidtab_set_open(&d.fids, m.fid, true)
		reply^ = vectra9.Rlcreate{qid = qid_of(new_node, v), iounit = 0}

	case vectra9.Tlopen:
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if node == ROOT_ID {
			if m.flags & 0o3 != vfs.O_RDONLY {
				reply^ = vectra9.error_reply(vectra9.EISDIR)
				return
			}
			vfs.fidtab_set_open(&d.fids, m.fid, true)
			reply^ = vectra9.Rlopen{qid = qid_of(ROOT_ID, nil), iounit = 0}
			return
		}
		v := var_of(node)
		if v == nil {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		if m.flags & vfs.O_TRUNC != 0 && m.flags & 0o3 != vfs.O_RDONLY {
			v.size = 0
			v.version += 1
		}
		vfs.fidtab_set_open(&d.fids, m.fid, true)
		reply^ = vectra9.Rlopen{qid = qid_of(node, v), iounit = 0}

	case vectra9.Tread:
		node, v, ok := open_var(m.fid, reply)
		if !ok {
			return
		}
		if node == ROOT_ID {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		if m.offset >= u64(v.size) {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		start := int(m.offset)
		end := min(v.size, start + min(len(buf), int(m.count)))
		copy(buf[:end - start], v.data[start:end])
		reply^ = vectra9.Rread{data = buf[:end - start]}

	case vectra9.Twrite:
		node, v, ok := open_var(m.fid, reply)
		if !ok {
			return
		}
		if node == ROOT_ID {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		if m.offset > u64(VALUE_MAX) || int(m.offset) + len(m.data) > VALUE_MAX {
			reply^ = vectra9.error_reply(vectra9.ENOSPC)
			return
		}
		end := int(m.offset) + len(m.data)
		if !reserve(v, end) {
			reply^ = vectra9.error_reply(vectra9.ENOMEM)
			return
		}
		// A write past the end zero-fills the gap, as a file would.
		for i in v.size ..< int(m.offset) {
			v.data[i] = 0
		}
		copy(v.data[m.offset:end], m.data)
		if end > v.size {
			v.size = end
		}
		v.version += 1
		d.writes += 1
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}

	case vectra9.Treaddir:
		env_readdir(m, reply, buf)

	case vectra9.Tremove:
		// 9P clunks the fid whether or not the remove succeeds.
		node := vfs.fidtab_node(&d.fids, m.fid)
		_ = vfs.fidtab_release(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if node == ROOT_ID {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		v := var_of(node)
		if v == nil {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		delete(v.data)
		v^ = Var{}
		dev.slots[int(node >> 16)].group.count -= 1
		d.removes += 1
		reply^ = vectra9.Rremove{}

	case vectra9.Tgetattr:
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		dir := node == ROOT_ID
		v: ^Var
		if !dir {
			v = var_of(node)
			if v == nil {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
		}
		attr := vectra9.Rgetattr {
			valid   = m.request_mask & vfs.GETATTR_BASIC,
			qid     = qid_of(node, v),
			mode    = dir ? S_IFDIR | 0o777 : S_IFREG | 0o666,
			nlink   = dir ? 2 : 1,
			blksize = 512,
		}
		if !dir {
			attr.size = u64(v.size)
		}
		attr.blocks = (attr.size + 511) / 512
		reply^ = attr

	case vectra9.Tsetattr:
		// A length is the one attribute a variable has to set. Mode and times
		// are accepted and ignored: Plan 9's `wstat` on `#e` does the same.
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if node == ROOT_ID {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		v := var_of(node)
		if v == nil {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		if m.valid & vfs.SETATTR_SIZE != 0 {
			if m.size > u64(VALUE_MAX) {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			want := int(m.size)
			if !reserve(v, want) {
				reply^ = vectra9.error_reply(vectra9.ENOMEM)
				return
			}
			for i in v.size ..< want {
				v.data[i] = 0
			}
			v.size = want
			v.version += 1
		}
		reply^ = vectra9.Rsetattr{}

	case vectra9.Tstatfs:
		if vfs.fidtab_node(&d.fids, m.fid) < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		grp := caller()
		n := grp == nil ? 0 : grp.count
		reply^ = vectra9.Rstatfs {
			type    = 0x0139_9249,
			bsize   = 512,
			files   = u64(n),
			ffree   = u64(MAX_VARS - n),
			namelen = MAX_NAME,
		}

	case vectra9.Tclunk:
		_ = vfs.fidtab_release(&d.fids, m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

// open_var is the fid checks a read or write starts with: bound, open, and
// still naming something. `v` is nil for the root, which the caller refuses
// with the message's own error.
@(private = "file")
open_var :: proc "contextless" (fid: vectra9.Fid, reply: ^vectra9.Msg) -> (node: i32, v: ^Var, ok: bool) {
	node = vfs.fidtab_node(&dev.fids, fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !vfs.fidtab_is_open(&dev.fids, fid) {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	if node != ROOT_ID {
		v = var_of(node)
		if v == nil {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
	}
	return node, v, true
}

/*
reserve makes `v.data` hold at least `want` bytes, growing in steps of a
power of two so a shell appending a path one element at a time does not
reallocate per write. Caller holds `lock`; the heap's lock nests inside it.
*/
@(private = "file")
reserve :: proc(v: ^Var, want: int) -> bool {
	if want <= len(v.data) {
		return true
	}
	size := max(64, len(v.data))
	for size < want {
		size *= 2
	}
	size = min(size, VALUE_MAX)
	fresh := make([]u8, size)
	if fresh == nil {
		return false
	}
	copy(fresh, v.data[:v.size])
	delete(v.data)
	v.data = fresh
	return true
}

/*
env_walk resolves names against the caller's directory, which has one level.
`.` and `..` from anywhere land on the root; a name from the root is a
variable of the asking process's group. Nothing walks out of a variable.
*/
@(private = "file")
env_walk :: proc "contextless" (m: vectra9.Twalk, reply: ^vectra9.Msg) #no_bounds_check {
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
		next := i32(-1)
		name := m.names[i]
		switch {
		case name == "." :
			next = cur
		case name == "..":
			next = ROOT_ID
		case cur == ROOT_ID:
			grp := caller()
			if grp != nil {
				if j := var_named(grp, name); j >= 0 {
					next = node_of(slot_of_group(grp), grp.vars[j].id)
				}
			}
		}
		if next < 0 {
			if i == 0 {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
			break
		}
		cur = next
		answer.qids[answer.count] = qid_of(cur, cur == ROOT_ID ? nil : var_of(cur))
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

// env_readdir lists the caller's group. The cookie is the id, as in `#s`,
// because a variable set or unset between two calls moves every position.
@(private = "file")
env_readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
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
	if node != ROOT_ID {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	grp := caller()
	out := buf
	room := min(len(out), int(m.count))
	c := vectra9.cursor_from(out[:room])
	if grp != nil {
		slot := slot_of_group(grp)
		after := i32(m.offset)
		for {
			best := -1
			for i in 0 ..< MAX_VARS {
				v := &grp.vars[i]
				if v.id == 0 || v.id <= after {
					continue
				}
				if best < 0 || v.id < grp.vars[best].id {
					best = i
				}
			}
			if best < 0 {
				break
			}
			v := &grp.vars[best]
			name := string(v.name[:v.len])
			if vectra9.remaining(&c) < vectra9.dirent_size(name) {
				break
			}
			vectra9.put_dirent(
				&c,
				vectra9.Dirent {
					qid = qid_of(node_of(slot, v.id), v),
					offset = u64(v.id),
					type = vectra9.DT_REG,
					name = name,
				},
			)
			after = v.id
		}
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
