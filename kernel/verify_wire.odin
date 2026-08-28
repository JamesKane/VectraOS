/*
The wire self-test: 9P down a pipe, with a server the kernel does not call.

`kernel/mnt`'s `Conn` proved a transport can leave a request pending. The
wire proves the harder half of the same claim: the far side of the transport
can be *nothing but bytes*. The server here is a kernel thread, because a
self-test wants determinism. It touches the wire exactly as a process will:
it reads frames from a pipe end and writes frames back. No code of the
kernel's runs between its decision and the client's wake but the reader.

The claims, in order:

  - the handshake crosses the pipe under NOTAG and settles the msize
  - a request is encoded, answered, and its payload lands in the caller's own
    buffer rather than anywhere the wire owns
  - two requests in flight come back to the right callers when the server
    answers them in the wrong order, which is what a tag is for
  - a deadline works end to end: the client flushes, the server discards and
    answers the flush, and the tag is usable again
  - a reply naming no request is drained, counted, and survived
  - a server that hangs up fails everything in flight rather than parks it
  - a server that breaks framing poisons the wire, and every later call fails
    at once

The last three are the ones a kernel-side server could never need. `Conn`'s
handlers are code the kernel trusts. A process is not, so the wire's job is
half transport and half border control, and the checks below are the border.
*/
package kernel

import "base:intrinsics"

import "kernel:mnt"
import "kernel:pipe"
import "kernel:sched"
import "kernel:sync"
import "vsys:libodin"
import "vsys:vectra9"

@(private = "file")
Wire_Result :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,
	served:        int, // Frames the scripted server answered
	flushed:       int, // Requests the client gave up on
	stale:         u64, // Unsolicited replies the wire drained
}

@(private = "file")
wcheck :: proc "contextless" (r: ^Wire_Result, ok: bool, what: string) -> bool {
	r.checks += 1
	if !ok {
		r.failures += 1
		if r.first_failure == "" {
			r.first_failure = what
		}
	}
	return ok
}

// The offset a client sends when it wants the server to sit on the request.
// The server records the tag and answers nothing until the flush arrives.
@(private = "file")
STALL :: u64(99)

/*
The scripted server -- a process stood in for by a thread.

It answers the way `/bin/niner` will: read a frame, look at the kind, write
a reply under the same tag. The script hooks are the flags below, each
consumed by the next matching request. Everything it does to the pipe, it
does through `pipe.read` and `pipe.write` on its own end. That discipline
keeps this test honest: no shared state with the wire but the bytes.
*/
@(private = "file")
Script :: struct {
	p:          ^pipe.Pipe,
	end:        int,

	swap_pair:  bool, // Hold the next request, answer the one after it first
	stale_next: bool, // After the next answer, also send a reply nobody asked for
	quit_next:  bool, // Swallow the next request and leave

	served:     int,
	stalled:    u32, // Bitmask of tags being sat on, one bit per pool slot
	done:       bool,
}

@(private = "file")
script_read_frame :: proc "contextless" (s: ^Script, buf: []u8) -> int {
	got := 0
	for got < vectra9.HEADER_SIZE {
		n := pipe.read(s.p, s.end, buf[got:vectra9.HEADER_SIZE])
		if n <= 0 {
			return 0
		}
		got += n
	}
	size := int(buf[0]) | int(buf[1]) << 8 | int(buf[2]) << 16 | int(buf[3]) << 24
	if size < vectra9.HEADER_SIZE || size > len(buf) {
		return 0
	}
	for got < size {
		n := pipe.read(s.p, s.end, buf[got:size])
		if n <= 0 {
			return 0
		}
		got += n
	}
	return size
}

@(private = "file")
script_send :: proc "contextless" (s: ^Script, tag: vectra9.Tag, msg: vectra9.Msg) -> bool {
	frame: [256]u8
	n, err := vectra9.encode(frame[:], tag, msg)
	if err != .None {
		return false
	}
	w, werr := pipe.write(s.p, s.end, frame[:n])
	return werr == 0 && w == n
}

@(private = "file")
script_answer :: proc "contextless" (s: ^Script, tag: vectra9.Tag, msg: ^vectra9.Msg) -> bool {
	payload: [64]u8
	#partial switch m in msg^ {
	case vectra9.Tversion:
		return script_send(s, tag, vectra9.Rversion{msize = m.msize, version = m.version})
	case vectra9.Tattach:
		return script_send(s, tag, vectra9.Rattach{qid = {kind = {.Dir}, path = 1}})
	case vectra9.Tread:
		// The reply carries the offset back as its bytes, so a client can see
		// whether it got its own answer or somebody else's.
		count := min(int(m.count), len(payload))
		for i in 0 ..< count {
			payload[i] = u8(m.offset)
		}
		return script_send(s, tag, vectra9.Rread{data = payload[:count]})
	case vectra9.Tflush:
		if int(m.oldtag) < 32 && s.stalled & (1 << u32(m.oldtag)) != 0 {
			// Discard the stalled request rather than answer it. Legal, and
			// the wire's `discards` counter is the check on the other side.
			s.stalled &~= 1 << u32(m.oldtag)
		}
		return script_send(s, tag, vectra9.Rflush{})
	case vectra9.Tclunk:
		return script_send(s, tag, vectra9.Rclunk{})
	}
	return script_send(s, tag, vectra9.error_reply(vectra9.EOPNOTSUPP))
}

@(private = "file")
script_server :: proc "contextless" (arg: rawptr) {
	s := cast(^Script)arg
	frame: [1200]u8
	held: [1200]u8
	held_n := 0
	held_tag: vectra9.Tag
	held_msg: vectra9.Msg

	for {
		n := script_read_frame(s, frame[:])
		if n == 0 {
			break
		}
		tag, msg, derr := vectra9.decode(frame[:n])
		if derr != .None {
			break
		}

		if m, is_read := msg.(vectra9.Tread); is_read && m.offset == STALL {
			if int(tag) < 32 {
				s.stalled |= 1 << u32(tag)
			}
			continue
		}
		if s.quit_next {
			break
		}

		if s.swap_pair && held_n == 0 {
			// Keep this one until the next arrives. The decoded message
			// borrows `frame`, so the bytes move to their own storage first.
			copy(held[:n], frame[:n])
			_, held_msg, _ = vectra9.decode(held[:n])
			held_tag = tag
			held_n = n
			continue
		}

		if !script_answer(s, tag, &msg) {
			break
		}
		s.served += 1

		if held_n > 0 {
			if !script_answer(s, held_tag, &held_msg) {
				break
			}
			s.served += 1
			held_n = 0
			s.swap_pair = false
		}

		if s.stale_next {
			s.stale_next = false
			if !script_send(s, vectra9.Tag(6), vectra9.Rread{data = frame[:8]}) {
				break
			}
		}
	}
	intrinsics.volatile_store(&s.done, true)
}

// One concurrent client: a Tread with a distinctive offset, checked against
// the bytes that come back.
@(private = "file")
Wire_Client :: struct {
	session: ^vectra9.Session,
	offset:  u64,
	stall:   bool, // Send the offset the server sits on, and expect to flush
	ok:      bool,
	done:    bool,
}

@(private = "file")
wire_client :: proc "contextless" (arg: rawptr) {
	c := cast(^Wire_Client)arg
	buf: [64]u8
	request := vectra9.Msg(vectra9.Tread{fid = 1, offset = c.offset, count = 16})
	reply: vectra9.Msg
	if c.stall {
		// The server will sit on this for ever, so the deadline is the test:
		// giving up must work with every slot in the same state.
		err := vectra9.call_for(c.session, &request, &reply, 5, buf[:])
		c.ok = err == .Interrupted
		intrinsics.volatile_store(&c.done, true)
		return
	}
	err := vectra9.call(c.session, &request, &reply, buf[:])
	if err == .None {
		if m, is := reply.(vectra9.Rread); is && len(m.data) == 16 {
			good := true
			for b in m.data {
				good = good && b == u8(c.offset)
			}
			c.ok = good
		}
	}
	intrinsics.volatile_store(&c.done, true)
}

@(private = "file")
wire_wait :: proc "contextless" (flag: ^bool) -> bool {
	for _ in 0 ..< 200 {
		if intrinsics.volatile_load(flag) {
			return true
		}
		sync.delay(1)
	}
	return intrinsics.volatile_load(flag)
}

@(private = "file")
wire_io_read :: proc "contextless" (data: rawptr, buf: []u8) -> int {
	s := cast(^Script)data
	return pipe.read(s.p, 1 - s.end, buf)
}

@(private = "file")
wire_io_write :: proc "contextless" (data: rawptr, frame: []u8) -> bool {
	s := cast(^Script)data
	n, err := pipe.write(s.p, 1 - s.end, frame)
	return err == 0 && n == len(frame)
}

// wire_up builds one pipe, one scripted server on end 0, and one wire on end
// 1. False when any part would not start, with the checks naming which.
@(private = "file")
wire_up :: proc(r: ^Wire_Result, s: ^Script, w: ^mnt.Wire, arena: []u8) -> bool {
	s^ = Script {
		end = 0,
	}
	s.p = pipe.create()
	if !wcheck(r, s.p != nil, "a pipe for the wire comes up") {
		return false
	}
	if !wcheck(
		r,
		mnt.wire_init(w, mnt.Wire_IO{data = s, read = wire_io_read, write = wire_io_write}, arena),
		"the wire divides its arena",
	) {
		return false
	}
	if !wcheck(r, mnt.wire_start(w), "the reader thread starts") {
		return false
	}
	return wcheck(r, sched.spawn("wire-script", script_server, s) != nil, "the scripted server starts")
}

// wire_down ends a test's server and wire, in the order that lets both leave:
// the server's end closes first, which is EOF to the reader.
@(private = "file")
wire_down :: proc(s: ^Script, w: ^mnt.Wire) {
	pipe.close_end(s.p, 0)
	pipe.close_end(s.p, 1)
	mnt.wire_join(w)
	_ = wire_wait(&s.done)
}

@(private = "file")
verify_wire_run :: proc(r: ^Wire_Result) {
	arena := make([]u8, 1024 * (mnt.MAX_REQUESTS + 1))
	if !wcheck(r, arena != nil, "an arena for the wire") {
		return
	}
	defer delete(arena)

	script: Script
	wire: mnt.Wire
	if !wire_up(r, &script, &wire, arena) {
		return
	}
	session := mnt.wire_session(&wire)

	// -- The handshake --------------------------------------------------------

	wcheck(r, vectra9.interruptible(session), "a wire session can give up on a request")
	wcheck(r, vectra9.negotiate(session) == .None, "Tversion crosses the pipe and back")
	wcheck(r, session.msize == 1024, "and the msize is what one slot holds")

	// -- One request, and whose bytes the reply borrows -----------------------

	buf: [64]u8
	request := vectra9.Msg(vectra9.Tattach{fid = 1, afid = vectra9.NOFID})
	reply: vectra9.Msg
	wcheck(r, vectra9.call(session, &request, &reply, buf[:]) == .None, "an attach is answered")
	att, is_att := reply.(vectra9.Rattach)
	wcheck(r, is_att && att.qid.path == 1, "with the qid the script serves")

	request = vectra9.Msg(vectra9.Tread{fid = 1, offset = 7, count = 16})
	wcheck(r, vectra9.call(session, &request, &reply, buf[:]) == .None, "a read is answered")
	if m, is := reply.(vectra9.Rread); wcheck(r, is && len(m.data) == 16, "with the bytes asked for") {
		mine := true
		for b in m.data {
			mine = mine && b == 7
		}
		wcheck(r, mine, "and they are this request's bytes")
		here := uintptr(raw_data(m.data)) >= uintptr(raw_data(buf[:])) &&
			uintptr(raw_data(m.data)) < uintptr(raw_data(buf[:])) + len(buf)
		wcheck(r, here, "landed in the caller's own buffer")
	}

	// -- Two in flight, answered in the wrong order ---------------------------

	script.swap_pair = true
	a := Wire_Client {
		session = session,
		offset  = 21,
	}
	b := Wire_Client {
		session = session,
		offset  = 42,
	}
	if wcheck(r, sched.spawn("wire-a", wire_client, &a) != nil, "a first client starts") &&
	   wcheck(r, sched.spawn("wire-b", wire_client, &b) != nil, "and a second") {
		wcheck(r, wire_wait(&a.done) && wire_wait(&b.done), "both come back")
		wcheck(r, a.ok && b.ok, "each with its own answer, out of order")
	}

	// -- A deadline, a flush, and the tag afterwards --------------------------

	request = vectra9.Msg(vectra9.Tread{fid = 1, offset = STALL, count = 8})
	err := vectra9.call_for(session, &request, &reply, 5, buf[:])
	wcheck(r, err == .Interrupted, "a stalled request times out")

	request = vectra9.Msg(vectra9.Tread{fid = 1, offset = 3, count = 8})
	wcheck(r, vectra9.call(session, &request, &reply, buf[:]) == .None, "the wire still answers")

	st := mnt.wire_stats(&wire)
	wcheck(r, st.flushes == 1, "one Tflush went out")
	wcheck(r, st.discards == 1, "the server discarded the stalled request, and the wire counted it")
	wcheck(r, !st.poisoned, "and nothing poisoned the wire")

	// -- Every slot stuck at once, and every client can still leave -----------

	/*
	This is the reserved flush slot earning its keep. Eight clients fill the
	pool with requests the server sits on, and all eight give up. Each flush
	goes out from its request's reserved partner, so none of them queues for
	the resource the stuck requests hold. The alternative arrangement
	deadlocks here, with nothing having sent an illegal message.
	*/
	stuck: [mnt.MAX_REQUESTS]Wire_Client
	started := 0
	for i in 0 ..< mnt.MAX_REQUESTS {
		stuck[i] = Wire_Client {
			session = session,
			offset  = STALL,
			stall   = true,
		}
		if sched.spawn("wire-stuck", wire_client, &stuck[i]) != nil {
			started += 1
		}
	}
	wcheck(r, started == mnt.MAX_REQUESTS, "a client per request slot starts")
	all_back := true
	all_flushed := true
	for i in 0 ..< mnt.MAX_REQUESTS {
		all_back = all_back && wire_wait(&stuck[i].done)
		all_flushed = all_flushed && stuck[i].ok
	}
	wcheck(r, all_back, "a full pool of stuck requests strands nobody")
	wcheck(r, all_flushed, "every one of them flushed and left")

	request = vectra9.Msg(vectra9.Tread{fid = 1, offset = 2, count = 8})
	wcheck(r, vectra9.call(session, &request, &reply, buf[:]) == .None, "and every slot is a slot again")
	st = mnt.wire_stats(&wire)
	wcheck(r, st.discards == 9, "the server discarded all nine sat-on requests")
	r.flushed = int(st.flushes)

	// -- A reply nobody asked for ---------------------------------------------

	script.stale_next = true
	request = vectra9.Msg(vectra9.Tread{fid = 1, offset = 4, count = 8})
	wcheck(r, vectra9.call(session, &request, &reply, buf[:]) == .None, "a request beside a stale reply is answered")
	request = vectra9.Msg(vectra9.Tread{fid = 1, offset = 5, count = 8})
	wcheck(r, vectra9.call(session, &request, &reply, buf[:]) == .None, "and the wire survives the stale one")
	st = mnt.wire_stats(&wire)
	wcheck(r, st.stale >= 1, "which it drained and counted")
	r.stale = st.stale

	// -- Hangup, with a request in flight -------------------------------------

	script.quit_next = true
	hung := Wire_Client {
		session = session,
		offset  = 60,
	}
	if wcheck(r, sched.spawn("wire-hung", wire_client, &hung) != nil, "a doomed client starts") {
		_ = wire_wait(&script.done)
		pipe.close_end(script.p, 0)
		wcheck(r, wire_wait(&hung.done), "the hangup wakes it")
		wcheck(r, !hung.ok, "with a failure rather than an answer")
	}
	wcheck(r, mnt.wire_broken(&wire), "the wire knows it is dead")
	st = mnt.wire_stats(&wire)
	wcheck(r, st.hangup, "and that the death was a hangup")

	request = vectra9.Msg(vectra9.Tread{fid = 1, offset = 6, count = 8})
	wcheck(r, vectra9.call(session, &request, &reply, buf[:]) == .Transport_Failed, "a call after the death fails at once")

	r.served = script.served
	wire_down(&script, &wire)

	// -- A server that breaks framing -----------------------------------------

	script2: Script
	wire2: mnt.Wire
	if !wire_up(r, &script2, &wire2, arena) {
		return
	}
	session2 := mnt.wire_session(&wire2)
	wcheck(r, vectra9.negotiate(session2) == .None, "a second wire negotiates")

	// Sixteen bytes whose size field is far beyond the msize. The reader must
	// refuse the frame rather than route it anywhere.
	junk: [16]u8
	junk[0] = 0xFF
	junk[1] = 0xFF
	junk[2] = 0x01
	n, werr := pipe.write(script2.p, 0, junk[:])
	wcheck(r, n == len(junk) && werr == 0, "sixteen bytes of junk go down the pipe")
	poisoned := false
	for _ in 0 ..< 200 {
		if mnt.wire_stats(&wire2).poisoned {
			poisoned = true
			break
		}
		sync.delay(1)
	}
	wcheck(r, poisoned, "a frame larger than the msize poisons the wire")
	st = mnt.wire_stats(&wire2)
	wcheck(r, !st.hangup, "as a protocol breach rather than a hangup")

	request = vectra9.Msg(vectra9.Tattach{fid = 2, afid = vectra9.NOFID})
	wcheck(r, vectra9.call(session2, &request, &reply, buf[:]) == .Transport_Failed, "and every later call fails")

	wire_down(&script2, &wire2)
	sched.reap()
}

/*
verify_wire runs the wire against a scripted server across a real pipe.

Before `init_user`, because the wire is what a posted pipe becomes at mount
time. A machine that cannot keep this contract should say so before a
process is invited to depend on it.
*/
verify_wire :: proc() {
	result: Wire_Result
	verify_wire_run(&result)

	sink := begin(&klog)
	libodin.put_str(&sink, "wire ")
	libodin.put_uint(&sink, u64(result.checks))
	if result.failures == 0 && result.checks > 0 {
		libodin.put_str(&sink, " checks passed -- ")
		libodin.put_uint(&sink, u64(result.served))
		libodin.put_str(&sink, " frames answered by a thread the kernel cannot call, ")
		libodin.put_uint(&sink, u64(result.flushed))
		libodin.put_str(&sink, " flushed, ")
		libodin.put_uint(&sink, result.stale)
		libodin.put_str(&sink, " stale reply dropped, 2 wires poisoned on purpose")
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " checks, ")
	libodin.put_uint(&sink, u64(result.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, result.first_failure)
	emit(&klog, .Fault, &sink)
}
