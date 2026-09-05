/*
ping -- send echo requests to a machine, and say which came back.

    ping [-n count] host

The host is a name or an address, and `/net/cs` turns it into one, so the
bench's `ping two` reaches the machine `/lib/ndb/local` calls `two`. Each
request goes out as one write of an ICMP conversation's `data`, and the reply
is one read of it. A read is broken by an alarm, so a request nobody answers is
a line that says so rather than a program that waits for ever.

There is no clock in ring 3 yet, so no round trip is reported. `docs/DEVTOOLS.md`
step 1's `/dev/time` is what adds one. The count is what a bench wants: how many
were sent, and how many came back.
*/
package ping

import "vsys:abi"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"

// How long a reply is waited for, and the pause between requests, in the
// kernel's millisecond ticks.
WAIT :: 1000

// The bytes after the header, a size a ping is expected to carry.
PAYLOAD :: 56

// The identifier this program's requests carry, so a reply is known as its own.
ID :: u16(0x7069)

dir: [128]u8
msg: [libnet.ICMP_HDR + PAYLOAD]u8
reply: [576]u8
line: [128]u8

say :: proc "contextless" (text: string) {
	_ = libuser.write(1, transmute([]u8)text)
}

fail :: proc "contextless" (what: string) -> ! {
	say(what)
	say("\n")
	libuser.exits(what)
}

// on_note is where the alarm lands. The read it interrupted has already
// answered EINTR, so there is nothing to do but carry on.
on_note :: proc "c" (ureg: rawptr, note: cstring) {
	_ = ureg
	_ = note
	libuser.noted(abi.NCONT)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)

	count := 3
	host := ""
	for i := 1; i < len(args); i += 1 {
		if args[i] == "-n" && i + 1 < len(args) {
			i += 1
			count = 0
			for j in 0 ..< len(args[i]) {
				c := args[i][j]
				if c < '0' || c > '9' {
					fail("usage: ping [-n count] host")
				}
				count = count * 10 + int(c - '0')
			}
			continue
		}
		host = args[i]
	}
	if host == "" || count < 1 {
		fail("usage: ping [-n count] host")
	}

	spec_buf: [96]u8
	spec := libuser.cat_into(spec_buf[:], "icmp!", host, "!1")
	fd, dirlen, ok := libnet.dial_dir(spec, dir[:])
	if !ok {
		fail("ping: cannot dial")
	}

	if libuser.notify(uintptr(rawptr(on_note))) != 0 {
		fail("ping: cannot catch a note")
	}

	sent := 0
	received := 0
	for seq in 1 ..= count {
		if !send_one(fd, u16(seq)) {
			fail("ping: cannot write")
		}
		sent += 1
		if wait_one(fd, u16(seq)) {
			received += 1
			report("bytes from ", host, seq, true)
		} else {
			report("lost from ", host, seq, false)
		}
		if seq < count {
			_ = libuser.sleep(WAIT)
		}
	}
	_ = libuser.notify(0)
	libnet.hangup(string(dir[:dirlen]))
	_ = libuser.close(fd)

	sink := libodin.sink_from(line[:])
	libodin.put_uint(&sink, u64(sent))
	libodin.put_str(&sink, " sent, ")
	libodin.put_uint(&sink, u64(received))
	libodin.put_str(&sink, " received\n")
	say(libodin.str(&sink))
	libuser.exits(received > 0 ? "" : "lost")
}

// send_one writes one echo request with sequence `seq`. The stack fills in
// the checksum; the payload is a pattern the reply is expected to carry back.
send_one :: proc "contextless" (fd: int, seq: u16) -> bool {
	payload: [PAYLOAD]u8
	for i in 0 ..< PAYLOAD {
		payload[i] = u8(i)
	}
	end := libnet.put_icmp_echo(msg[:], 0, libnet.ICMP_ECHO, ID, seq, payload[:])
	return libuser.write(fd, msg[:end]) == i64(end)
}

/*
wait_one reads replies until the one for `seq` arrives, or the alarm breaks
the read. A reply for an earlier request, arriving late, is read and passed
over rather than mistaken for this one.
*/
wait_one :: proc "contextless" (fd: int, seq: u16) -> bool {
	_ = libuser.alarm(WAIT)
	defer libuser.alarm(0)
	for {
		n := libuser.read(fd, reply[:])
		if n <= 0 {
			return false
		}
		m, ok := libnet.parse_icmp(reply[:n])
		if ok && m.kind == libnet.ICMP_ECHOREPLY && m.id == ID && m.seq == seq {
			return true
		}
	}
}

// report prints one line about request `seq`, with the size when a reply
// came back to have one.
report :: proc "contextless" (what: string, host: string, seq: int, sized: bool) {
	sink := libodin.sink_from(line[:])
	if sized {
		libodin.put_uint(&sink, u64(len(msg)))
		libodin.put_str(&sink, " ")
	}
	libodin.put_str(&sink, what)
	libodin.put_str(&sink, host)
	libodin.put_str(&sink, ": seq=")
	libodin.put_uint(&sink, u64(seq))
	libodin.put_str(&sink, "\n")
	say(libodin.str(&sink))
}
