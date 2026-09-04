/*
devfs -- the first server in Vectra whose files are devices.

`#c` bound at `/dev`, with `cons`, `null`, `zero` and the raw framebuffer in
it. What that buys is the whole path from a name to a byte on a screen, end
to end and over real 9P:

    open_path(ns, "/dev/cons", O_RDWR)   a walk across two servers
    chan_write(c, 0, "hello\n")          Twrite -> a worker -> the framebuffer
    chan_read(c, 0, buf)                 Tread  -> a worker -> parks -> a key

`vfs.static.odin` served the same shape of tree before this and could not serve
this one, for exactly one reason. It is read-only, and its `data` is a string in
`.rodata`. A device has no contents. It has behaviour, and the behaviour is what
the node table has to hold.

## Three things this is the first of

**The first server whose reads genuinely park.** Everything else in this tree
that waits waits because a self-test told it to. A read of `/dev/cons` with
nothing typed has nothing to answer with and no way to invent one. It parks on
`Cons.ready` until a byte arrives, and a client that gives up flushes it. That
is `Tflush` reached from a path rather than from a test -- which is what
`kernel/mnt` and `kernel/vfs` were built for.

**The first handler that may not hold its lock across a request.**
`static_handler` takes the server's spinlock on the way in and drops it on the
way out, because nothing it does can wait. Every line of it is a table lookup.
This handler writes to a framebuffer and parks on a rendezvous, and both are
forbidden inside a spinlock. So `Dev_Tree.lock` guards the fid table and only
the fid table. The node table needs no lock at all: it is `.rodata` and it never
changes.

**The first server with an abort hook that means something.** `devfs_abort` is
what `kernel/mnt` calls when a `Tflush` names a live request. It wakes every
parked reader, each re-tests whether the flush was its own, and the one that was
flushed answers EINTR. The transport's own `flushed` bit is the authority,
through `vfs.server_flushed`. That bit goes clear when a slot is claimed. A
flag of this server's own would need the same clearing, at a moment this server
cannot see.

## A worker for every request, and one more to serve the flush

`WORKERS` is `mnt.MAX_REQUESTS + 1`. The transport carries at most
`MAX_REQUESTS` requests at once, so a worker for every slot lets every read park
without ever waiting for a worker. The one beyond that serves the `Tflush` that
unsticks a parked read, and a flush never parks. It marks the request, calls the
abort hook, and returns.

This is Plan 9's thread of its own for every request. It was too many threads to
want when this server was first written. The file comment said so. Nine threads
over an eight-slot transport is cheap. The stall it retires had a fourth read of
`/dev/cons` wait on a worker that a third read held parked. A byte at the port
freed the whole chain at once.
*/
package devfs

import "base:intrinsics"

import "kernel:drivers/console"
import "kernel:drivers/fb"
import "kernel:drivers/uart"
import "kernel:mnt"
import "kernel:sync"
import "kernel:mem"
import "kernel:vfs"
import "vsys:vectra9"

/*
What a file in this tree does, rather than what it contains.

A separate enum from the node, so that adding `random` or `kbd` is a row in the
table and a case in two switches. Nothing about the walk, the listing or the fid
table has to learn a new file kind.
*/
Dev_Kind :: enum u8 {
	Dir,
	Cons, // The console: writes draw, reads park until a key
	Consctl, // The console's rules: writes command, reads report
	Null, // Writes vanish, reads are at end of file
	Zero, // Writes vanish, reads are zeroes and never end
	Fb, // The raw framebuffer: pixel bytes at an offset. See `fbdev.odin`
	Fbctl, // The framebuffer's geometry: reads report, nothing to command yet
		Scancode, // The keyboard before translation, diverted while open. See `tap.odin`
	Eia0, // The serial port's bytes, raw in and raw out. See `tap.odin`
	Mouse, // The pointer, one line per movement, one reader. See `mouse.odin`
}

Dev_Node :: struct {
	name:   string,
	parent: i32, // Index of the containing directory; -1 for the root
	kind:   Dev_Kind,
}

/*
The tree, in the order a listing reports it.

`/dev/cons` is the milestone. `null` and `zero` are here for two reasons. A
dispatch table with one row is not a dispatch table. And the self-test needs a
read that does *not* park, to compare the one that does against. Both are about
ten lines and both are files a POSIX layer will need on its first day.

`fb` and `fbctl` are the console's raw half: the screen's memory as a file,
and the geometry beside it. The first device a user process reaches for the
hardware rather than for the line discipline. See `fbdev.odin`.

`scancode` and `eia0` are the input streams the same way: the keyboard
before translation, and the serial port before the line discipline. Each
is diverted from the console while something holds it open. See `tap.odin`.
*/
@(private)
DEV_NODES := [?]Dev_Node {
	{name = "/", parent = -1, kind = .Dir},
	{name = "cons", parent = 0, kind = .Cons},
	{name = "consctl", parent = 0, kind = .Consctl},
	{name = "null", parent = 0, kind = .Null},
	{name = "zero", parent = 0, kind = .Zero},
	{name = "fb", parent = 0, kind = .Fb},
	{name = "fbctl", parent = 0, kind = .Fbctl},
		{name = "scancode", parent = 0, kind = .Scancode},
	{name = "eia0", parent = 0, kind = .Eia0},
	{name = "mouse", parent = 0, kind = .Mouse},
}

// How many devices this server publishes, not counting its own root. Reported
// at boot, so a change to the table above shows up in the log.
DEV_FILES :: len(DEV_NODES) - 1

// Linux st_mode type bits, as Rgetattr carries them. A device is a character
// device, and says so: that is what tells a POSIX layer not to seek it.
@(private = "file")
S_IFDIR :: u32(0o040000)
@(private = "file")
S_IFCHR :: u32(0o020000)

// Linux d_type, for a listing. `sys/vectra9` names the two it needed first.
@(private = "file")
DT_CHR :: u8(2)

/*
One parked reader's wait, one per request slot.

The condition procedure gets one `rawptr` and needs two facts: which console to
look at, and which request to ask the transport about. Odin has no closure that
does not allocate, so the pair is a struct with a slot of its own. Indexed by
tag, because a tag is what names a request slot on this transport and there is
one wait per slot by construction.
*/
@(private = "file")
Read_Wait :: struct {
	tree: ^Dev_Tree,
	tag:  vectra9.Tag,

		// Which stream this request waits on: a tap, the mouse, or the console
	// when neither. Written by every request that parks, because the slot is
	// reused and a stale stream would have a reader test the wrong ring.
	tap:   ^Tap,
	mouse: ^Mouse_File,
}

Dev_Tree :: struct {
	server: vfs.Server,
	cons:   Cons,

	// The screen's own memory, for `/dev/fb`. The whole surface rather than
	// the console's region of it: the raw device is the hardware, and the
	// console is one tenant. See `fbdev.odin`.
	raw:    ^fb.Surface,

		// The two raw input streams, each diverted from the console while its
	// file is open. See `tap.odin`.
	scancode: Tap,
	serial:   Tap,

	// The pointer, one line per movement. See `mouse.odin`.
	mouse:    Mouse_File,

	// Client fids, and the one thing in here that several workers write. See
	// `kernel/vfs/fidtab.odin`.
	fids:   vfs.Fid_Table,
	lock:   sync.Spinlock,
	waits:  [mnt.MAX_REQUESTS]Read_Wait,

	/*
	How many fids hold each file whose open state *means* something.

	Under `lock`, with the fid table they are counted from. `/dev/consctl`
	at zero puts the console back in cooked mode -- see `consctl_close`.
	The two taps at zero give their streams back to the console -- see
	`tap.odin`. The handler moves the tap's own `open` flag across on the
	first open and the last close. The producers that read that flag must
	never touch this lock.
	*/
	ctl_opens:  int,
	scan_opens: int,
	eia_opens:  int,
	// How many fids hold the screen. While it is above zero the console draws
	// into a copy instead of onto the glass -- see `fbdev.odin`.
	fb_opens:   int,
}

/*
A worker for every request slot, and one more.

See the file comment. Every one of the `MAX_REQUESTS` slots can hold a parked
read, and the spare serves the flush that unsticks one. The spare is exactly one
because a flush never parks: it marks the request, calls the abort hook, and
returns.
*/
WORKERS :: mnt.MAX_REQUESTS + 1

// Fids this server will hand out at once. A ceiling rather than a guess -- see
// `vfs.fidtab_init`. Four files means a client would have to clone the same
// handle hundreds of times to reach it: every process holds three here.
DEV_MAX_FIDS :: 1024

@(private)
dev_tree: Dev_Tree

/*
init brings the device tree up and binds it at `/dev` in `ns`.

Order matters twice here, and neither is tidiness.

`server_start` comes before `register_device`, so nothing can reach this server
while it is still on its own stack. A handler on the synchronous transport is
handed no payload buffer and cannot park without taking its caller down with it.
Both are properties of the transport, and this server is correct on exactly one
of them.

`cons_start` comes last, because a producer thread with nowhere to deliver is a
thread that fills a ring nobody drains.

Needs a scheduler and a running clock. The workers are threads, the producer is
a thread, and a parked reader waits on a rendezvous. Everything before that
point in the boot names files without ever reading one.
*/
init :: proc(ns: ^vfs.Namespace, screen: ^console.Console, port: ^uart.Port, raw: ^fb.Surface) -> vfs.Errno {
	t := &dev_tree

	if !vfs.fidtab_init(&t.fids, DEV_MAX_FIDS) {
		return vectra9.ENOMEM
	}
	cons_init(&t.cons, screen, port)
	t.raw = raw

	// The one file in this tree that is memory rather than a stream. See
	// `vfs.Server.device`, and `devfs_device` below.
	t.server.device = devfs_device

	if err := vfs.server_init(&t.server, "c", devfs_handler, t); err != .None {
		vfs.fidtab_destroy(&t.fids)
		return vectra9.EPROTO
	}
	if !vfs.server_start(&t.server, WORKERS, 0, devfs_abort) {
		vfs.fidtab_destroy(&t.fids)
		return vectra9.ENOMEM
	}
	if !vfs.register_device(&t.server) {
		vfs.server_stop(&t.server)
		vfs.fidtab_destroy(&t.fids)
		return vectra9.EEXIST
	}

	if err := vfs.mount_device(ns, "#c", "/dev"); err != vfs.OK {
		return err
	}

	// A console with no producer still writes, and a write is the half of
	// `/dev/cons` that a boot log needs. A port that failed its loopback probe
	// gets no thread, and that is not a failure of the mount.
	_ = cons_start(&t.cons)
	return vfs.OK
}

// tree is the one instance, for a caller that wants to count what it did. The
// self-test and the boot log are the two, and both only read.
tree :: proc "contextless" () -> ^Dev_Tree {
	return &dev_tree
}

/*
devfs_device answers what physical memory a file is, which is `/dev/fb` and
nothing else.

The kernel asks this, never a client. `docs/DRAW.md` section 7 named the four
things a mapping costs, and this is the third: the framebuffer's physical
address, plumbed through. It is one subtraction, because Limine puts the
framebuffer in the direct map and `fb.Surface` holds the pointer into it.

Every other node answers false, including `/dev/fbctl`. Geometry is a report
in text, and a text report is a stream however close it sits to the pixels.
*/
@(private = "file")
devfs_device :: proc "contextless" (
	sv: ^vfs.Server,
	qid: vectra9.Qid,
) -> (phys: uintptr, bytes: u64, ok: bool) #no_bounds_check {
	_ = sv
	node := i32(qid.path) - 1
	if node < 0 || int(node) >= len(DEV_NODES) || DEV_NODES[node].kind != .Fb {
		return 0, 0, false
	}
	raw := dev_tree.raw
	if raw == nil || raw.pixels == nil {
		return 0, 0, false
	}
	return mem.virt_to_phys(rawptr(raw.pixels)), fb_size(raw), true
}

// raw_surface is the screen `/dev/fb` serves, for a self-test that has to
// look at pixels a program wrote through the mount. Nothing else should
// reach around the file.
raw_surface :: proc "contextless" () -> ^fb.Surface {
	return dev_tree.raw
}

/*
keyboard_sink is where a keyboard driver's translated bytes arrive.

The same entry point the serial poller uses, one layer up. `kernel/drivers/kbd`
does not know what a console is and this does not know what a scancode is. The
byte between them is the whole interface.

Two producers into one ring is not a special case. `Cons.lock` guards it and
always did. By the time a byte gets here, one typed at a keyboard is
indistinguishable from one off the serial line. That is what makes the line
discipline one implementation rather than two.
*/
keyboard_sink :: proc "contextless" (b: u8) {
	_ = cons_feed(&dev_tree.cons, b)
}

/*
cons_takes reports the count of bytes this console gave to readers.

**A fence for a test that has to know a reader caught up.** `/dev/cons` is
asynchronous by construction. A self-test types a character into the sink here,
and the process reading it is somewhere else entirely.

A check about what happens *between* two typed characters -- which window a
half-typed line belongs to when the focus moves -- has to know the reader took
the first before the focus moved. Nothing else in this system says so.

It is one of the counters `Cons` already keeps for the boot report, exposed
rather than added. A delay would have been the alternative, and
`docs/TESTING.md` has nothing good to say about those.
*/
cons_takes :: proc "contextless" () -> u64 {
	return dev_tree.cons.takes
}

// input_started reports whether the producer thread is on the port. False on a
// machine with no serial port, where `/dev/cons` writes and never reads.
input_started :: proc "contextless" () -> bool {
	return dev_tree.cons.port != nil && dev_tree.cons.port.present
}

// -- The tree ----------------------------------------------------------------

@(private = "file")
node_qid :: proc "contextless" (node: i32) -> vectra9.Qid #no_bounds_check {
	// Path is the index plus one, so that a qid nobody filled in does not name
	// the root. Same rule as `vfs.static.odin`, for the same reason.
	kind: vectra9.Qid_Flags
	if DEV_NODES[node].kind == .Dir {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

@(private = "file")
find_child :: proc "contextless" (parent: i32, name: string) -> i32 #no_bounds_check {
	for i in 0 ..< len(DEV_NODES) {
		if DEV_NODES[i].parent == parent && DEV_NODES[i].name == name {
			return i32(i)
		}
	}
	return -1
}

@(private = "file")
step :: proc "contextless" (from: i32, name: string) -> i32 #no_bounds_check {
	switch name {
	case ".":
		return from
	case "..":
		// The root's parent is the root. This server has no name for anything
		// above its own tree, and saying so is what lets `kernel/vfs` notice and
		// climb out through `mounted_over` instead.
		p := DEV_NODES[from].parent
		return p < 0 ? from : p
	}
	if DEV_NODES[from].kind != .Dir {
		return -1
	}
	return find_child(from, name)
}

// -- The fid table, and the lock around it -----------------------------------
//
// Three one-line wrappers, and they earn their place. The lock is held for the
// table lookup, and released before the device does anything. Every caller
// would otherwise write the same three lines, and one of them would forget the
// release.

@(private = "file")
bind_fid :: proc "contextless" (t: ^Dev_Tree, fid: vectra9.Fid, node: i32) -> bool {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return vfs.fidtab_bind(&t.fids, fid, node)
}

@(private = "file")
node_of :: proc "contextless" (t: ^Dev_Tree, fid: vectra9.Fid) -> i32 {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return vfs.fidtab_node(&t.fids, fid)
}

/*
mark_open records an open, counts it when the file's open state means
something, and reports whether this was the first.

`first` is what the handler acts on outside this lock: the first open of a
tap is the moment the stream diverts. The count and the fid's open flag
move together, and one lock covers both. What the count *causes* -- a tap
gate, a console mode -- happens elsewhere, because the rule in this
package is one lock at a time.
*/
@(private = "file")
mark_open :: proc "contextless" (t: ^Dev_Tree, fid: vectra9.Fid) -> (kind: Dev_Kind, first: bool) {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	node := vfs.fidtab_node(&t.fids, fid)
	if node < 0 || !vfs.fidtab_set_open(&t.fids, fid, true) {
		return .Dir, false
	}

	kind = DEV_NODES[node].kind
	#partial switch kind {
	case .Consctl:
		t.ctl_opens += 1
		return kind, t.ctl_opens == 1
	case .Scancode:
		t.scan_opens += 1
		return kind, t.scan_opens == 1
	case .Eia0:
		t.eia_opens += 1
		return kind, t.eia_opens == 1
		case .Fb:
		t.fb_opens += 1
		return kind, t.fb_opens == 1
	case .Mouse:
		t.mouse.opens += 1
		return kind, t.mouse.opens == 1
	}
	return kind, false
}

/*
drop_fid releases a fid and reports whether it was the last open holder of
a file whose open state means something.

The report is what the caller acts on, and it has to come from in here.
Whether the fid was open, and what it was bound to, are both gone the
instant the slot goes back on the free list.

Nothing is reverted under this lock. `cons_set_mode` takes the console's
lock and `tap_stop` takes the tap's. Two spinlocks nested is an order to
get right rather than a thing to do by accident. The rule in this package
is one at a time.
*/
@(private = "file")
drop_fid :: proc "contextless" (t: ^Dev_Tree, fid: vectra9.Fid) -> (kind: Dev_Kind, last: bool) {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	node := vfs.fidtab_node(&t.fids, fid)
	open := vfs.fidtab_is_open(&t.fids, fid)
	_ = vfs.fidtab_release(&t.fids, fid)

	if !open || node < 0 {
		return .Dir, false
	}

	kind = DEV_NODES[node].kind
	#partial switch kind {
	case .Consctl:
		t.ctl_opens -= 1
		return kind, t.ctl_opens <= 0
	case .Scancode:
		t.scan_opens -= 1
		return kind, t.scan_opens <= 0
	case .Eia0:
		t.eia_opens -= 1
		return kind, t.eia_opens <= 0
		case .Fb:
		t.fb_opens -= 1
		return kind, t.fb_opens <= 0
	case .Mouse:
		t.mouse.opens -= 1
		return kind, t.mouse.opens <= 0
	}
	return kind, false
}

// live_fids is what this server has out. A self-test that opens and closes in
// balance checks it. A fid the client released and the server kept is a leak
// nothing else reports.
live_fids :: proc "contextless" () -> int {
	t := &dev_tree
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return vfs.fidtab_live(&t.fids)
}

// -- /dev/consctl ------------------------------------------------------------

/*
The first `ctl` file in the tree, and therefore where the convention gets set.

`docs/VECTRA9.md` decision 1 covers this. When a service needs an operation 9P
does not have, the answer is a file that takes a line of text. This is the first
service to need one. Four rules, and each is a decision rather than an
accident:

  - **One write is one command.** Nothing is buffered between writes and a
    command may not be split across two of them. A ctl file that reassembled a
    command from fragments would have to guess where one ended, and 9P gives it
    nothing to guess with.
  - **A command nothing recognises is EINVAL**, and the write takes none of it.
    Silence would let a client believe it changed something.
  - **The file reads back as the writes that would restore it.** Not a status
    report in a different vocabulary. A reader can save what it reads and write
    it back later, and that is what makes this one file rather than two.
  - **The last close reverts it.** Below.

Surrounding whitespace is ignored, and a trailing newline is expected rather
than merely tolerated. A client that writes `rawon` is writing a line of text.
*/

// The command vocabulary, and the whole of it. A table rather than a chain of
// comparisons, so the read side can walk the same rows the write side matches
// against.
@(private = "file")
Consctl_Command :: struct {
	word: string,
	mode: Cons_Mode,
	echo: bool,
}

@(private = "file")
CONSCTL_COMMANDS := [?]Consctl_Command {
	// Raw turns echo off and cooked turns it on, because a raw read that echoed
	// would be a password on a screen. See `cons.odin`.
	{word = "rawon", mode = .Raw, echo = false},
	{word = "rawoff", mode = .Cooked, echo = true},
}

// Echo moves on its own as well, for a client that wants a combination the two
// commands above do not produce. A cooked line nobody sees is a reasonable
// thing to want and there is no other way to ask for it.
@(private = "file")
ECHO_ON :: "echoon"
@(private = "file")
ECHO_OFF :: "echooff"

/*
trim removes surrounding whitespace and at most one trailing newline.

A client writes a line. Whether the line arrives with its newline is a property
of the client. No ctl file should have an opinion about that.
*/
@(private = "file")
trim :: proc "contextless" (data: []u8) -> string #no_bounds_check {
	lo := 0
	hi := len(data)
	for lo < hi && is_space(data[lo]) {
		lo += 1
	}
	for hi > lo && is_space(data[hi - 1]) {
		hi -= 1
	}
	return string(data[lo:hi])
}

@(private = "file")
is_space :: proc "contextless" (b: u8) -> bool {
	return b == ' ' || b == '\t' || b == '\r' || b == '\n'
}

/*
consctl_command applies one command and reports whether it was one.

A write of nothing at all is accepted and does nothing, because that is what a
write of no bytes means everywhere else. A write of only whitespace is refused:
the client meant to send a command and sent none.
*/
@(private = "file")
consctl_command :: proc "contextless" (t: ^Dev_Tree, data: []u8) -> bool #no_bounds_check {
	if len(data) == 0 {
		return true
	}
	word := trim(data)
	if word == "" {
		return false
	}

	for cmd in CONSCTL_COMMANDS {
		if word == cmd.word {
			_ = cons_set_mode(&t.cons, cmd.mode, cmd.echo)
			return true
		}
	}

	switch word {
	case ECHO_ON, ECHO_OFF:
		mode, _ := cons_mode(&t.cons)
		_ = cons_set_mode(&t.cons, mode, word == ECHO_ON)
		return true
	}
	return false
}

/*
consctl_report renders the state as the commands that would restore it.

    rawoff
    echoon

Generated on every read rather than snapshotted at open. Plan 9 snapshots a ctl
file, and it is right to for one whose contents are long or expensive. This is
under twenty bytes and a client that reads it twice wants the second answer to
be true.

`offset` is honoured so a client with a small buffer can finish the file. A
read past the end then returns nothing rather than repeating.
*/
@(private = "file")
consctl_report :: proc "contextless" (t: ^Dev_Tree, offset: u64, buf: []u8) -> []u8 #no_bounds_check {
	mode, echo := cons_mode(&t.cons)

	// Built into the caller's buffer from the start, then sliced by offset.
	// The whole file is shorter than the smallest payload a slot ever has, so
	// there is no case where it does not fit.
	line: [64]u8
	n := 0
	for cmd in CONSCTL_COMMANDS {
		if cmd.mode != mode {
			continue
		}
		for i in 0 ..< len(cmd.word) {
			line[n] = cmd.word[i]
			n += 1
		}
		line[n] = '\n'
		n += 1
		break
	}

	word := echo ? ECHO_ON : ECHO_OFF
	for i in 0 ..< len(word) {
		line[n] = word[i]
		n += 1
	}
	line[n] = '\n'
	n += 1

	if offset >= u64(n) {
		return nil
	}
	start := int(offset)
	end := min(n, start + len(buf))
	copy(buf[:end - start], line[start:end])
	return buf[:end - start]
}

/*
consctl_close puts the console back the way it was found.

**The last close reverts the mode, and that is the point of the file.** A
program that turns raw mode on and then faults leaves a console nobody can type
at. No echo, and no line editing to fix a mistake with. Tying the mode to an
open fid means the kernel undoes it when the program goes. The program does not
have to survive long enough to undo it itself.

Plan 9 does exactly this, and it is worth copying for exactly this reason.

Called from `Tclunk`, and only when `drop_fid` reports that the last open
`/dev/consctl` fid went.
*/
@(private = "file")
consctl_close :: proc "contextless" (t: ^Dev_Tree) {
	_ = cons_set_mode(&t.cons, .Cooked, true)
}

// -- The abort hook ----------------------------------------------------------

/*
devfs_abort is what `kernel/mnt` calls when a Tflush names a live request.

It wakes every parked reader rather than the one that was flushed, and that is
not laziness. This hook is handed a tag. What identifies a parked reader is the
rendezvous it is on, rather than a tag. `wakeup_all` costs one pass over
a list at most `WORKERS` long. Each woken thread re-tests its own condition,
and the ones nothing flushed park again. `sync.sleep` loops for exactly this
reason.

The alternative is a rendezvous per tag, which is eight rendezvous to save
waking three threads that will go straight back to sleep.
*/
@(private)
devfs_abort :: proc "contextless" (server: rawptr, tag: vectra9.Tag) {
	t := cast(^Dev_Tree)server
	_ = tag
		sync.wakeup_all(&t.cons.ready)
	sync.wakeup_all(&t.scancode.ready)
	sync.wakeup_all(&t.serial.ready)
	sync.wakeup_all(&t.mouse.ready)
}

/*
read_ready is the condition a parked reader waits on.

Two ways out, and the caller has to tell them apart afterwards. A byte arrived,
or this request was flushed. Runs with interrupts masked, so it does what a
condition is allowed to do and nothing else: two loads and a comparison.
*/
@(private = "file")
read_ready :: proc "contextless" (arg: rawptr) -> bool {
		w := cast(^Read_Wait)arg
	if w.tap != nil {
		if tap_available(w.tap) {
			return true
		}
	} else if w.mouse != nil {
		if mouse_available(w.mouse) {
			return true
		}
	} else if cons_available(&w.tree.cons) {
		return true
	}
	return vfs.server_flushed(&w.tree.server, w.tag)
}

// -- The handler -------------------------------------------------------------

/*
dev_creates reports whether a message would add a file to this tree or take one
away.

Answered by kind rather than by a fall-through, and answered with EPERM rather
than EOPNOTSUPP. The two say different things to a client. EPERM is `there is
such an operation and you may not`, which is the truth. The shape of `/dev` is
the driver table, and a client does not get to add a row to it. EOPNOTSUPP would
send a client off to look for a server that does implement it.
*/
@(private = "file")
dev_creates :: proc "contextless" (k: vectra9.Kind) -> bool {
	#partial switch k {
	case .Tlcreate,
	     .Tmkdir,
	     .Tmknod,
	     .Tsymlink,
	     .Tlink,
	     .Trename,
	     .Trenameat,
	     .Tunlinkat,
	     .Tremove:
		return true
	}
	return false
}

devfs_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = s
	t := cast(^Dev_Tree)server
	if t == nil {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}

	// No lock here, unlike `vfs.static_handler`. This handler writes to a
	// framebuffer and parks on a rendezvous, and a spinlock forbids both. What
	// needs the lock is the fid table, and `bind_fid`, `node_of` and `drop_fid`
	// take it for exactly as long as a lookup.

	if dev_creates(vectra9.kind(request^)) {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}

	// Everything unhandled is a genuine "not implemented". Set it first, so
	// each case below is one assignment rather than one assignment and a
	// fall-through somebody forgets.
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply)

	case vectra9.Tattach:
		if !bind_fid(t, m.fid, 0) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = node_qid(0)}

	case vectra9.Twalk:
		devfs_walk(t, m, reply)

	case vectra9.Tlopen:
		node := node_of(t, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		// A directory may be read and may not be written. Every device here
		// takes all three access modes. Each has a read side and a write side,
		// even when one of the two does nothing.
		if DEV_NODES[node].kind == .Dir && m.flags & 0o3 != vfs.O_RDONLY {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		// A port that failed its loopback probe is a device that is not
		// there. A refusal at the open beats a read that parks for ever on
		// hardware nothing feeds.
				if DEV_NODES[node].kind == .Eia0 && (t.cons.port == nil || !t.cons.port.present) {
			reply^ = vectra9.error_reply(vectra9.ENXIO)
			return
		}
				// A mouse that never came up is the same refusal. A pointer has one
		// owner, so a second open of a held mouse is refused rather than
		// given half the movements.
		if DEV_NODES[node].kind == .Mouse {
			if !t.mouse.present {
				reply^ = vectra9.error_reply(vectra9.ENXIO)
				return
			}
			if mouse_held(t) {
				reply^ = vectra9.error_reply(vectra9.EBUSY)
				return
			}
		}
		// The open is recorded, not merely allowed. `/dev/consctl` owns the
		// console's rules while held, and a tap owns its stream. The first
		// open of a tap is the moment the stream diverts.
		kind, first := mark_open(t, m.fid)
		if first {
			#partial switch kind {
			case .Scancode:
				tap_start(&t.scancode)
			case .Eia0:
				tap_start(&t.serial)
			case .Fb:
				// And the screen diverts the same way the streams do. The
				// console draws into a copy until the last of these goes.
				screen_divert(t.cons.screen, t.raw)
			}
		}
		reply^ = vectra9.Rlopen{qid = node_qid(node), iounit = 0}

	case vectra9.Tread:
		devfs_read(t, m, tag, reply, buf)

	case vectra9.Twrite:
		devfs_write(t, m, reply)

	case vectra9.Treaddir:
		devfs_readdir(t, m, reply, buf)

	case vectra9.Tgetattr:
		node := node_of(t, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		dir := DEV_NODES[node].kind == .Dir
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & vfs.GETATTR_BASIC,
			qid     = node_qid(node),
			// 0o666 on a device, because `/dev/cons` is the one file every
			// process is expected to be able to write. A permission model that
			// says otherwise arrives with the processes.
			mode    = dir ? S_IFDIR | 0o555 : S_IFCHR | 0o666,
			nlink   = dir ? 2 : 1,
			// A stream has no length, and zero is what stops a caller from
			// reading one by its size. The framebuffer is not a stream. It has
			// exactly this many bytes, and a caller may read it by them.
			size    = DEV_NODES[node].kind == .Fb ? fb_size(t.raw) : 0,
			blksize = 512,
		}

	case vectra9.Tstatfs:
		if node_of(t, m.fid) < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = vectra9.Rstatfs {
			type    = 0x0139_9249, // V9FS_MAGIC, as Linux reports for 9P
			bsize   = 512,
			files   = u64(len(DEV_NODES)),
			namelen = 255,
		}

	case vectra9.Tclunk:
		// Clunking a fid this server never bound is not worth an error. The
		// client wanted it gone and it is gone. A refusal would only ever break
		// a cleanup path.
		kind, last := drop_fid(t, m.fid)
		if last {
			#partial switch kind {
			case .Consctl:
				consctl_close(t)
			case .Scancode:
				tap_stop(&t.scancode)
			case .Eia0:
				tap_stop(&t.serial)
			case .Fb:
				// And the screen comes back, with everything the console drew
				// while it was away on it.
				screen_revert(t.cons.screen, t.raw)
			}
		}
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		// `kernel/mnt` answers Tflush itself and never delivers one here. This
		// case is for the synchronous transport, where nothing is ever pending
		// and the request being flushed has already been answered. Rflush
		// regardless: Tflush may never be answered with an error.
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

/*
devfs_walk resolves up to sixteen names in one message.

The same two rules `vfs.static_walk` gets right, and worth restating because
getting either wrong is silent. A partial walk binds nothing, so `newfid` is
untouched when element three of five fails. A failure at element zero is an
error reply, and a failure later is a short Rwalk. That is how a client tells
`the first name is not there` from `the path runs out partway`.
*/
@(private = "file")
devfs_walk :: proc "contextless" (t: ^Dev_Tree, m: vectra9.Twalk, reply: ^vectra9.Msg) #no_bounds_check {
	node := node_of(t, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if vfs.fidtab_is_open(&t.fids, m.fid) {
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
		answer.qids[answer.count] = node_qid(cur)
		answer.count += 1
	}

	if answer.count == m.count {
		if !bind_fid(t, m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}

/*
devfs_read is the one that parks.

`offset` is ignored, and that is the definition of a stream rather than an
oversight. A second read of `/dev/cons` at offset zero does not read the same
bytes again, because the bytes are gone. A file whose contents are the future
has no position to be at. `Rgetattr` reports a size of zero for the same reason.

The reply is built in `buf`, which is the request slot's own storage. A read
that answered out of anything shared would be a read that hands one worker's
bytes to another worker's client. See `docs/TRANSPORT.md`.

The loop rather than one park is `sync.sleep`'s contract, honoured. A wake is a
hint. One byte can wake two readers, and only one of them gets it. The other
finds nothing and parks again.
*/
@(private = "file")
devfs_read :: proc "contextless" (
	t: ^Dev_Tree,
	m: vectra9.Tread,
	tag: vectra9.Tag,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	node := node_of(t, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !vfs.fidtab_is_open(&t.fids, m.fid) {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	if DEV_NODES[node].kind == .Dir {
		// 9P2000.L reads a directory with Treaddir. Tread on one is the client
		// using the wrong message, rather than a permission problem.
		reply^ = vectra9.error_reply(vectra9.EISDIR)
		return
	}

	room := min(len(buf), int(m.count))
	if room <= 0 {
		// Nowhere to put an answer. Not an end of file, and not worth parking
		// for. A client that asked for nothing got it.
		reply^ = vectra9.Rread{data = nil}
		return
	}

	switch DEV_NODES[node].kind {
	case .Null:
		// Always at the end of the file. Zero bytes is what that means.
		reply^ = vectra9.Rread{data = nil}

	case .Zero:
		intrinsics.mem_zero(raw_data(buf), room)
		reply^ = vectra9.Rread{data = buf[:room]}

	case .Consctl:
		reply^ = vectra9.Rread{data = consctl_report(t, m.offset, buf[:room])}

	case .Fb:
		// The offset is honoured, and this device is why the streams above
		// say so when they ignore theirs. Zero bytes past the end is a real
		// end of file. See `fbdev.odin`.
		reply^ = vectra9.Rread{data = fb_read(t.raw, m.offset, buf[:room])}

	case .Fbctl:
		reply^ = vectra9.Rread{data = fbctl_report(t.raw, m.offset, buf[:room])}

	case .Cons:
		if int(tag) >= mnt.MAX_REQUESTS {
			// A tag this server cannot index is a tag it cannot ask the
			// transport about, so a park here could never be flushed. Refusing
			// beats parking with no way out.
			reply^ = vectra9.error_reply(vectra9.EIO)
			return
		}
				w := &t.waits[int(tag)]
		w.tree = t
		w.tag = tag
		w.tap = nil
		w.mouse = nil
		// The reader owns the console for a typed interrupt from here on.
		if console_owner != nil {
			if group := console_owner(); group != 0 {
				t.cons.owner_group = group
			}
		}

		for {
			// The flush is checked before the drain, and the order keeps a
			// line from being lost to a flush that raced its arrival. A
			// flushed request's reply is dropped, so a drain into one would
			// consume the line and hand it to nobody. `flushed` is set before
			// this reader wakes, so seeing it first leaves the line for the
			// read that follows. See the `.Scancode` loop for the long form.
			if vfs.server_flushed(&t.server, tag) {
				reply^ = vectra9.error_reply(vectra9.EINTR)
				return
			}
			if n := cons_take(&t.cons, buf[:room]); n > 0 {
				reply^ = vectra9.Rread{data = buf[:n]}
				return
			}
			if cons_take_eof(&t.cons) {
				// A `^D` on an empty line, and the one place a read of the
				// console answers with nothing. The drain above came first, so
				// this cannot overtake bytes typed before it.
				reply^ = vectra9.Rread{data = nil}
				return
			}
			cons_note_block(&t.cons)
			sync.sleep(&t.cons.ready, read_ready, w)
		}

	case .Scancode, .Eia0:
		// The console's loop with two lines gone. A tap has no line
		// discipline, so any byte answers, and no `^D`, so nothing here ever
		// answers zero bytes. Park, byte, or flush is the whole state space.
		tp := DEV_NODES[node].kind == .Scancode ? &t.scancode : &t.serial
		if int(tag) >= mnt.MAX_REQUESTS {
			reply^ = vectra9.error_reply(vectra9.EIO)
			return
		}
				w := &t.waits[int(tag)]
		w.tree = t
		w.tag = tag
		w.tap = tp
		w.mouse = nil

		for {
			/*
			The flush is checked *before* the drain, and the order is
			load-bearing. A client that gave up on this read has a tag the
			transport reclaimed, and a reply on it is dropped. A drain before
			the check would consume the bytes into that dropped reply. The
			next read would find them gone -- a byte lost to a flush that
			raced its arrival. The transport sets `flushed` before it wakes
			this reader, so checking it first leaves the bytes in the tap for
			the read that comes after.
			*/
			if vfs.server_flushed(&t.server, tag) {
				reply^ = vectra9.error_reply(vectra9.EINTR)
				return
			}
			if n := tap_take(tp, buf[:room]); n > 0 {
				reply^ = vectra9.Rread{data = buf[:n]}
				return
			}
			tap_note_block(tp)
			sync.sleep(&tp.ready, read_ready, w)
		}

	case .Mouse:
		// One line per movement, and a park until there is one newer than
		// the last line answered. The same flush-first loop as the taps.
		if int(tag) >= mnt.MAX_REQUESTS {
			reply^ = vectra9.error_reply(vectra9.EIO)
			return
		}
		w := &t.waits[int(tag)]
		w.tree = t
		w.tag = tag
		w.tap = nil
		w.mouse = &t.mouse
		for {
			if vfs.server_flushed(&t.server, tag) {
				reply^ = vectra9.error_reply(vectra9.EINTR)
				return
			}
			if n := mouse_line(&t.mouse, buf[:room]); n > 0 {
				reply^ = vectra9.Rread{data = buf[:n]}
				return
			}
			sync.sleep(&t.mouse.ready, read_ready, w)
		}

	case .Dir:
		// Answered above, and named here so the switch is exhaustive rather
		// than defaulted. A file kind added to the enum should not compile.
		reply^ = vectra9.error_reply(vectra9.EISDIR)
	}
}

// mouse_held says whether a fid holds the pointer right now.
@(private = "file")
mouse_held :: proc "contextless" (t: ^Dev_Tree) -> bool {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return t.mouse.opens > 0
}

/*
devfs_write hands a payload to a device and reports how much it took.

Never short, and `/dev/consctl` is why that is worth stating rather than
assuming. A ctl file takes one command per write and either understands it or
refuses the whole thing. A short count there would mean `I took some of your
command`, which no client could act on.

`m.data` points into the request slot for as long as this handler runs, which is
the borrow rule at the top of `sys/vectra9/proto.odin`. `cons_write` copies it
onto a screen before returning, so nothing outlives the borrow.
*/
@(private = "file")
devfs_write :: proc "contextless" (t: ^Dev_Tree, m: vectra9.Twrite, reply: ^vectra9.Msg) #no_bounds_check {
	node := node_of(t, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}

	switch DEV_NODES[node].kind {
	case .Dir:
		reply^ = vectra9.error_reply(vectra9.EISDIR)

	case .Cons:
		reply^ = vectra9.Rwrite{count = u32(cons_write(&t.cons, m.data))}

	case .Consctl:
		if !consctl_command(t, m.data) {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}

	case .Fb:
		// The one write in this server that can be short, and the one that
		// can refuse for want of room. Both come from having a real size.
		// See `fbdev.odin` for the boundary rules.
		n, err := fb_write(t.raw, m.offset, m.data)
		if err != vfs.OK {
			reply^ = vectra9.error_reply(err)
			return
		}
		reply^ = vectra9.Rwrite{count = u32(n)}

	case .Fbctl:
		// The command vocabulary is empty until something about the hardware
		// can be set, so every command is one nothing recognises. A write of
		// no bytes stays a write of no bytes, as everywhere else.
		if len(m.data) > 0 {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		reply^ = vectra9.Rwrite{count = 0}

	case .Scancode, .Mouse:
		// Nobody writes the keyboard, or the mouse. The operation exists and
		// is refused, which is what EPERM says. EINVAL would blame the
		// bytes, and no bytes would have done better.
		reply^ = vectra9.error_reply(vectra9.EPERM)

	case .Eia0:
		// Raw bytes out the wire, and no glyph anywhere. A caller that wants
		// a screen has `/dev/cons`. See `tap.odin`.
		reply^ = vectra9.Rwrite{count = u32(eia0_write(t, m.data))}

	case .Null, .Zero:
		// Accepted and discarded, which is what both mean. A write that failed
		// would make `/dev/null` useless for the one thing it is for.
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}
	}
}

/*
devfs_readdir lists the tree, and the cookie is the child's ordinal.

One-based, so it means `resume after this one` rather than `resume at this one`.
That is what Treaddir means by an offset, and it is why zero is a legal starting
value no entry ever returns.

`.` and `..` are absent. 9P walks them and Plan 9's servers do not list them. A
POSIX layer that needs them makes them up where it makes up the rest of `struct
dirent`.
*/
@(private = "file")
devfs_readdir :: proc "contextless" (
	t: ^Dev_Tree,
	m: vectra9.Treaddir,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	node := node_of(t, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !vfs.fidtab_is_open(&t.fids, m.fid) {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	if DEV_NODES[node].kind != .Dir {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	if buf == nil {
		// This server has no listing buffer of its own, on purpose. A buffer
		// per server is what the payload arena replaced, and a second copy of
		// the wrong answer is worse than a refusal. See `init`.
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}

	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])

	ordinal := u64(0)
	for i in 0 ..< len(DEV_NODES) {
		if DEV_NODES[i].parent != node {
			continue
		}
		ordinal += 1
		if ordinal <= m.offset {
			continue
		}
		if vectra9.remaining(&c) < vectra9.dirent_size(DEV_NODES[i].name) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = node_qid(i32(i)),
				offset = ordinal,
				type = DEV_NODES[i].kind == .Dir ? vectra9.DT_DIR : DT_CHR,
				name = DEV_NODES[i].name,
			},
		)
	}

	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
