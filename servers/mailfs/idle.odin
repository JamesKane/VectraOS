/*
IDLE: `docs/WEB.md` section 6's "the read that parks, so `event` answers
the moment the server has something".

`idle` on `ctl` keeps a session with the account's server: a login, the
inbox selected, whatever is new taken, and then IDLE, RFC 2177. The
server says `* N EXISTS` when a message lands, this side says DONE,
takes what is new by UID, and idles again. What is taken goes into
`inbox/` and its chat the way a fetch's does, so a reader parked on
`event` is answered with `inbox/<id>` as it lands. The write to `ctl`
returns once the session idles, or says why it could not.

`idle off` ends it: DONE, a logout, and the session's thread leaves.
`ctl` says `idle` while it runs.

The handshake answers from here too. A step that arrives under IDLE is
answered on a sender thread over SMTP, the way a write to `new` goes,
since this thread must get back to the wire.
*/
package mailfs

import "vsys:lib9p"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

Idle :: struct {
	using f:  Fetch,
	stop:     bool, // `idle off` was said
	idling:   bool, // The server said `+`, and DONE has not been said
	answered: bool, // The write that asked for the session has its reply
	next_uid: int, // The first UID not yet taken
}

idle: ^Idle // The session running, or nil

// start_idle holds the ctl write and starts the session on a thread of
// its own. EBUSY when one runs already.
start_idle :: proc(tag: vectra9.Tag, count: int) -> vectra9.Errno {
	if !account.set {
		return vectra9.EINVAL
	}
	if idle != nil {
		return vectra9.EBUSY
	}
	i := new(Idle)
	i.tag = tag
	i.count = count
	i.fd = -1
	i.next_uid = 1
	if libthread.threadcreate(idle_thread, i, 256 * 1024) < 0 {
		free(i)
		return vectra9.ENOSPC
	}
	idle = i
	lib9p.hold(&net.srv)
	return 0
}

// stop_idle asks the session to end. The session's thread is parked in a
// read of the wire while it idles, so DONE goes from here, and the thread
// logs out when the server answers it.
stop_idle :: proc() {
	i := idle
	if i == nil {
		return
	}
	i.stop = true
	if i.idling && i.fd >= 0 {
		_ = libuser.write(i.fd, transmute([]u8)string("DONE\r\n"))
	}
}

// answer_idle answers the ctl write that asked for the session, once.
answer_idle :: proc(i: ^Idle, err: vectra9.Errno) {
	if i.answered {
		return
	}
	i.answered = true
	if req := lib9p.find_held_tag(&net.srv, i.tag); req != nil {
		if err == 0 {
			_ = lib9p.respond(req, vectra9.Rwrite{count = u32(i.count)})
		} else {
			_ = lib9p.respond(req, vectra9.error_reply(err))
		}
	}
}

idle_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	i := (^Idle)(arg)
	err := vectra9.Errno(0)
	i.io = libthread.ioproc()
	if i.io == nil {
		err = vectra9.EIO
	} else {
		err = idle_session(i)
		if i.tls != nil {
			free(i.tls)
		}
		if i.fd >= 0 {
			libnet.hangup(string(i.dir[:i.dirlen]))
			_ = libuser.close(i.fd)
		}
		libthread.ioclose(i.io)
	}
	if err != 0 && i.why != "" {
		libuser.eprint("mailfs: idle: ", i.why, "\n")
	}
	answer_idle(i, err)
	if idle == i {
		idle = nil
	}
	rebuild_status()
	free(i)
	libthread.threadexits("")
}

// idle_session is the whole session: the login and the inbox, what was
// there, and then IDLE until something lands or `idle off` is said.
idle_session :: proc(i: ^Idle) -> vectra9.Errno {
	f := &i.f
	if err := login(f, "i1", "i2"); err != 0 {
		return err
	}
	if !take_messages(f, "i3", &i.next_uid) {
		return vectra9.EIO
	}
	// The session idles: the write that asked is answered now.
	answer_idle(i, 0)
	rebuild_status()
	for !i.stop {
		if !say(f, "i4 IDLE\r\n") {
			i.why = "IDLE would not go"
			return vectra9.EIO
		}
		// The continuation, then whatever the server says until it says a
		// message landed, or that the IDLE ended: DONE was said from ctl.
		landed := false
		ended := false
		for {
			line, ok := read_line(f)
			if !ok {
				if i.stop {
					return 0
				}
				i.why = "the session ended"
				return vectra9.EIO
			}
			if libodin.has_prefix(line, "+") {
				i.idling = true
				if i.stop {
					// Asked to stop before the server answered: DONE from here.
					_ = say(f, "DONE\r\n")
				}
				continue
			}
			if libodin.has_prefix(line, "i4 ") {
				ended = true
				break
			}
			if libodin.has_prefix(line, "* ") && ends_with(line, " EXISTS") {
				landed = true
				break
			}
		}
		i.idling = false
		if !ended {
			if !say(f, "DONE\r\n") || !until_tagged(f, "i4") {
				i.why = "IDLE would not end"
				return vectra9.EIO
			}
		}
		if landed && !take_messages(f, "i3", &i.next_uid) {
			return vectra9.EIO
		}
		if landed {
			rebuild_status()
		}
	}
	_ = say(f, "i5 LOGOUT\r\n")
	_ = until_tagged(f, "i5")
	return 0
}

ends_with :: proc "contextless" (s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

// uid_of answers the UID a FETCH response line carries, `(UID N`, or zero.
uid_of :: proc "contextless" (line: string) -> int {
	at := libodin.index(line, " UID ")
	if at < 0 {
		return 0
	}
	v := 0
	for i := at + 5; i < len(line) && line[i] >= '0' && line[i] <= '9'; i += 1 {
		v = v * 10 + int(line[i] - '0')
	}
	return v
}
