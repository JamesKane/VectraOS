/*
The screen lock, `docs/WORKBENCH.md` step 5.

`lock` on the server's `ctl`, or the chord, puts the server in a mode that
takes the keyboard and the mouse and paints a lock over the whole glass: no
window gets a key or a line, no chord acts, and no window's pixels show. A
copper plate stands in the middle, and an amber dot on it for each character
typed, so a person sees the passphrase land without seeing it.

Return asks `factotum` whether the typed line is the passphrase of the person
logged in, `check user= dom= !passphrase=` on its `ctl`: the key it derives is
compared with the one `factotum` holds, or with the person's line in
`/adm/keys`. So this server holds no key and links no crypto, and a wrong
passphrase replaces nothing. A match leaves the mode and repaints the glass
from the stores. The question goes from the lock's own thread through an io proc
of its own, because the derivation takes a while and the serve loop must not
wait on it. That thread is made when the server starts and waits on a
channel: a thread created from the key's own context did not run until much
later, and a person's Return sat there for half a minute.
*/
package intuition

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libpal"
import "vsys:libthread"
import "vsys:libuser"

LOCK_MAX :: 128
LOCK_DOTS :: 16

locked: bool
lock_checking: bool
lock_pending: bool // A Return typed while a check ran: check again after it
lock_buf: [LOCK_MAX]u8
lock_n: int
lock_io: ^libthread.Ioproc
lock_chan: ^libthread.Chan // A Return typed: the lock thread wakes and asks

/*
lock_start makes the lock's thread, once, with the server: it waits on
`lock_chan` and runs each check. It is made here, not when a key arrives,
so a check never waits on a thread the key's own context has to yield to.
*/
lock_start :: proc "contextless" () -> bool {
	lock_chan = libthread.chancreate(size_of(rawptr), 4)
	if lock_chan == nil {
		return false
	}
	return libthread.threadcreate(lock_thread, nil, 32 * 1024) >= 0
}

@(private = "file")
lock_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	for {
		_ = libthread.recvp(lock_chan)
		lock_check()
	}
}

// lock_on locks the glass: every window goes behind the lock, and the keys
// and the pointer are the lock's until the passphrase is typed.
lock_on :: proc "contextless" () {
	if locked {
		return
	}
	locked = true
	lock_n = 0
	grabbing = false
	drag.kind = .None
	desk_paint(0, 0, scr_w, scr_h)
}

// lock_off is the passphrase matched: the glass comes back from the stores.
lock_off :: proc "contextless" () {
	locked = false
	lock_n = 0
	desk_paint(0, 0, scr_w, scr_h)
	repaint(0, 0, scr_w, scr_h)
}

// lock_plate is the plate's rectangle: centred, and wide enough for the dots.
lock_plate :: proc "contextless" () -> (x: int, y: int, w: int, h: int) {
	w, h = 16 + LOCK_DOTS * 14, 48
	return (scr_w - w) / 2, (scr_h - h) / 2, w, h
}

// lock_paint paints the lock over a rectangle of the glass: the void, the
// plate, and a dot for each character typed.
lock_paint :: proc "contextless" (sx0: int, sy0: int, sx1: int, sy1: int) #no_bounds_check {
	pieces: [2 + LOCK_DOTS]libdraw.Piece
	pieces[0] = libdraw.Piece{0, 0, scr_w, scr_h, libpal.VOID}
	px, py, pw, ph := lock_plate()
	pieces[1] = libdraw.Piece{px, py, pw, ph, libpal.COPPER}
	n := 2
	for i in 0 ..< min(lock_n, LOCK_DOTS) {
		pieces[n] = libdraw.Piece{px + 8 + i * 14, py + ph / 2 - 5, 10, 10, libpal.AMBER}
		n += 1
	}
	desk_pieces(pieces[:n], sx0, sy0, sx1, sy1)
}

// lock_key takes one byte typed while locked. Return asks; a backspace takes
// the last character back; anything else is the passphrase.
lock_key :: proc "contextless" (b: u8) #no_bounds_check {
	switch b {
	case '\n', '\r':
		// A check running takes this line after it: typing ahead of a slow
		// derivation loses nothing.
		if lock_checking {
			lock_pending = true
			return
		}
		lock_checking = true
		if lock_chan == nil || !libthread.nbsendp(lock_chan, nil) {
			lock_checking = false
		}
		return
	case 8, 0x7F:
		if lock_n > 0 {
			lock_n -= 1
		}
	case:
		if b >= 0x20 && lock_n < LOCK_MAX {
			lock_buf[lock_n] = b
			lock_n += 1
		}
	}
	px, py, pw, ph := lock_plate()
	lock_paint(px, py, px + pw, py + ph)
	cursor_show()
}

/*
lock_check asks `factotum`, on a thread, whether the line typed is the
passphrase of `$user` in `$dom`, and unlocks on a yes. The line is wiped
whichever the answer. `factotum` is found at `/mnt/factotum`, and mounted
there from `/srv/factotum` when this namespace does not have it.
*/
lock_check :: proc "contextless" () #no_bounds_check {
	// The line is this check's from here; what is typed meanwhile is the
	// next one's.
	pass: [LOCK_MAX]u8
	pn := copy(pass[:], lock_buf[:lock_n])
	lock_buf = {}
	lock_n = 0
	defer {
		pass = {}
		again := false
		if locked && lock_pending {
			lock_pending = false
			again = libthread.nbsendp(lock_chan, nil)
		}
		if !again {
			lock_pending = false
			lock_checking = false
			if locked {
				px, py, pw, ph := lock_plate()
				lock_paint(px, py, px + pw, py + ph)
				cursor_show()
			}
		}
	}
	if lock_io == nil {
		lock_io = libthread.ioproc()
		if lock_io == nil {
			return
		}
	}
	ub, db: [64]u8
	user := env_word("/env/user", ub[:])
	dom := env_word("/env/dom", db[:])
	if user == "" || dom == "" {
		return
	}
	fd := libuser.open("/mnt/factotum/ctl", abi.O_WRONLY)
	if fd < 0 {
		_ = libthread.iomount(lock_io, "/srv/factotum", "/mnt/factotum", abi.ORDER_REPLACE)
		fd = libuser.open("/mnt/factotum/ctl", abi.O_WRONLY)
	}
	if fd < 0 {
		return
	}
	line: [LOCK_MAX + 160]u8
	text := libuser.cat_into(line[:], "check proto=noise user=", user, " dom=", dom, " !passphrase=", string(pass[:pn]))
	ok := libthread.iowrite(lock_io, int(fd), transmute([]u8)text) == i64(len(text))
	line = {}
	_ = libuser.close(int(fd))
	if ok {
		lock_off()
	}
}

// env_word reads a variable of `/env` and trims it to its first word.
env_word :: proc "contextless" (path: string, buf: []u8) -> string #no_bounds_check {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return ""
	}
	n := libuser.read(int(fd), buf)
	_ = libuser.close(int(fd))
	end := 0
	for end < max(int(n), 0) && buf[end] != 0 && buf[end] != '\n' && buf[end] != ' ' {
		end += 1
	}
	return string(buf[:end])
}
