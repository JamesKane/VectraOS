/*
A wire over a chan: a posted connection that is a file of some server's,
not a pipe end, mounted as a 9P client of whatever answers the far side.

`serve9.odin` builds a wire over a pipe end, which is how a program's posted
service is mounted. `docs/FLEET.md` section 5 wants the same over a stream:
`srv tcp!fs!9fs fs` posts `/net/tcp/N/data`, and `mount /srv/fs /n/fs` must
make the kernel a client of the `exportfs` on the far machine. The chan is
`netfs`'s, and its bytes are the conversation's. So the wire's read is
`chan_read` and its write is `chan_write`, and everything above them is the
same `mnt.Wire` a pipe gets.

**Which chans.** A pipe end has its own builder. A kernel device's chan, such
as one on `/dev/cons`, keeps meaning the device behind it, which is how
posting that descriptor publishes the whole of `#c`. What is left is a chan
served across a wire -- interruptible, in `vfs`'s word -- and that is the
kind a stream is.

**Teardown is the difference from a pipe.** The wire's reader is parked in a
read of the far conversation, which only the far side can end. Closing this
side's chan does not unpark it, and a `Tclunk` with a read still held on the
fid leaves the read held. So the release closes the chan, poisons the wire,
and waits a bounded while for the reader; a reader that stays parked keeps
its slot, marked, until the far side's hang-up lets it leave and a later
build reclaims it.
*/
package pipe

import "kernel:mem"
import "kernel:mnt"
import "kernel:sync"
import "kernel:vfs"

MAX_CHAN_WIRES :: 8

@(private = "file")
Chan_Wire :: struct {
	used:  bool,
	dying: bool, // Released, with a reader still parked on the far side
	c:     ^vfs.Chan,
	w:     ^mnt.Wire,
	sv:    ^vfs.Server,
	arena: []u8,
}

@(private = "file")
chan_wires: [MAX_CHAN_WIRES]Chan_Wire

@(private = "file")
chan_wire_read :: proc "contextless" (data: rawptr, buf: []u8) -> int {
	cw := cast(^Chan_Wire)data
	context = mem.kernel_context()
	n, err := vfs.chan_read(cw.c, 0, buf)
	if err != vfs.OK || n <= 0 {
		return 0
	}
	return n
}

@(private = "file")
chan_wire_write :: proc "contextless" (data: rawptr, frame: []u8) -> bool {
	cw := cast(^Chan_Wire)data
	context = mem.kernel_context()
	// A stream may take a frame in pieces, so this writes until it has.
	at := 0
	for at < len(frame) {
		n, err := vfs.chan_write(cw.c, 0, frame[at:])
		if err != vfs.OK || n <= 0 {
			return false
		}
		at += n
	}
	return true
}

/*
chan_server_for answers `which server is this chan?` for a posted chan that
is a stream, building the wire on first asking. Nil for a chan that is a
pipe end or a device's, which have their own answers, and for a far side
that fails the handshake. Serialised by the pipe table's build mutex, for
the reason `server_for` gives.
*/
chan_server_for :: proc(c: ^vfs.Chan) -> ^vfs.Server {
	if c == nil || !vfs.server_interruptible(c.server) {
		return nil
	}
	if p, _ := chan_pipe(c); p != nil {
		return nil
	}
	// A registered kernel device -- `/dev/cons` and the like -- is published
	// as itself when a descriptor on it is posted and mounted. Only a chan on
	// a mounted file server, a network conversation's data among them, is a
	// stream to speak 9P over. See `vfs.is_device_server`.
	if vfs.is_device_server(c.server) {
		return nil
	}
	t := &pipes
	sync.mutex_lock(&t.build)
	defer sync.mutex_unlock(&t.build)

	slot := -1
	for i in 0 ..< MAX_CHAN_WIRES {
		cw := &chan_wires[i]
		if cw.used && cw.dying {
			// A released wire whose reader may have left by now.
			if mnt.wire_join_for(cw.w, 1) {
				chan_wire_free(cw)
			}
		}
		if cw.used && !cw.dying && cw.c == c {
			vfs.server_pin(cw.sv)
			return cw.sv
		}
		if !cw.used && slot < 0 {
			slot = i
		}
	}
	if slot < 0 {
		return nil
	}
	cw := &chan_wires[slot]
	arena := make([]u8, WIRE_ARENA)
	w := new(mnt.Wire)
	sv := new(vfs.Server)
	if arena == nil || w == nil || sv == nil {
		free_wire_build(nil, arena, w, sv)
		return nil
	}
	cw^ = Chan_Wire{used = true, c = vfs.chan_incref(c), w = w, sv = sv, arena = arena}
	if !mnt.wire_init(w, mnt.Wire_IO{data = cw, read = chan_wire_read, write = chan_wire_write}, arena) ||
	   !mnt.wire_start(w) {
		vfs.chan_close(cw.c)
		cw^ = {}
		free_wire_build(nil, arena, w, sv)
		return nil
	}
	sv.name = "stream"
	sv.session = mnt.wire_session(w)^
	if !handshake(&sv.session) {
		// The far side never said 9P2000.L. The reader is parked on a
		// stream that may still be open, so this is a release, not a free.
		sv.release = nil
		chan_wire_retire(cw)
		return nil
	}
	sv.release = chan_wire_release
	sv.pins = 2
	return sv
}

/*
chan_unpost takes the `/srv` name's stake off a posted stream's wire, and
hands the caller the server to drop it on. Nil for a chan that is not a
stream's wire. The caller closes its chan and then unpins, outside every
lock, as `unpost` asks.
*/
chan_unpost :: proc(c: ^vfs.Chan) -> ^vfs.Server {
	t := &pipes
	sync.mutex_lock(&t.build)
	defer sync.mutex_unlock(&t.build)
	for i in 0 ..< MAX_CHAN_WIRES {
		cw := &chan_wires[i]
		if cw.used && !cw.dying && cw.c == c {
			return cw.sv
		}
	}
	return nil
}

// chan_wire_release is the last stake going: the wire is retired.
@(private = "file")
chan_wire_release :: proc(sv: ^vfs.Server) {
	t := &pipes
	sync.mutex_lock(&t.build)
	defer sync.mutex_unlock(&t.build)
	for i in 0 ..< MAX_CHAN_WIRES {
		cw := &chan_wires[i]
		if cw.used && !cw.dying && cw.sv == sv {
			if !vfs.server_release_confirm(sv) {
				return
			}
			chan_wire_retire(cw)
			return
		}
	}
}

/*
chan_wire_retire hangs the wire up: the chan is closed, which is this side's
clunk of the far conversation, and the reader is given a bounded while to
leave. One that stays parked keeps the slot, marked, for a later build to
reclaim once the far side's hang-up lets it go. Under the build mutex.
*/
@(private = "file")
chan_wire_retire :: proc(cw: ^Chan_Wire) {
	vfs.chan_close(cw.c)
	cw.c = nil
	cw.dying = true
	if mnt.wire_join_for(cw.w, QUIET_TICKS) {
		chan_wire_free(cw)
	}
}

@(private = "file")
chan_wire_free :: proc(cw: ^Chan_Wire) {
	free_wire_build(nil, cw.arena, cw.w, cw.sv)
	cw^ = {}
}
