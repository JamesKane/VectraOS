/*
netecho -- announce a service, or dial one and say a word.

The two halves of a conversation, as two runs of one program. A line crossing
between two machines then needs nothing else on either of them:

    netecho announce echo        answers every line with the same line
    netecho dial tcp!two!echo hello
                                 says `hello` and prints what comes back

`docs/FLEET.md` step 0 ends with a line crossing a TCP conversation between two
machines of the bench. This is that line. Both halves go through `sys/libnet`,
so the address is a name and `/net/cs` resolves it out of `/lib/ndb/local`.

The announcing half serves one conversation and then exits, which is what a
bench wants. It is started, it is used once, and it goes away rather than
needing to be killed.
*/
package netecho

import "vsys:abi"
import "vsys:libnet"
import "vsys:libuser"

buf: [1024]u8
dir: [128]u8
path: [160]u8

// say writes one line to this program's output.
say :: proc "contextless" (text: string) {
	_ = libuser.write(1, transmute([]u8)text)
}

fail :: proc "contextless" (what: string) -> ! {
	say(what)
	say("\n")
	libuser.exits(what)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	if len(args) < 3 {
		fail("usage: netecho announce service | netecho dial addr word")
	}

	switch args[1] {
	case "announce":
		announce_one(args[2])
	case "dial":
		if len(args) < 4 {
			fail("usage: netecho dial addr word")
		}
		dial_one(args[2], args[3])
	case:
		fail("netecho: announce or dial")
	}
	libuser.exits("")
}

/*
announce_one announces a service, waits for one conversation, and answers every
line on it with the same line until the far end closes.

The read of `listen` parks in the server until a connection arrives, which is
what makes this a service rather than a poll. It serves one conversation and
then exits, which is what a bench wants. It is started, it is used once, and it
goes away rather than needing to be killed.
*/
announce_one :: proc "contextless" (service: string) {
	addr: [64]u8
	spec := libuser.cat_into(addr[:], "tcp!*!", service)
	// `*` is this machine, which `cs` reads as the local address.
	dirlen, ok := libnet.announce(spec, dir[:])
	if !ok {
		fail("netecho: cannot announce")
	}
	served := string(dir[:dirlen])

	lfd := libuser.open(libnet.join(path[:], served, "listen"), abi.O_RDONLY)
	if lfd < 0 {
		fail("netecho: cannot listen")
	}
	echo_conversation(lfd, served)
}

/*
echo_conversation waits for one connection on `lfd`, then answers every line on
it with the same line until the far end closes. The `listen` read parks until a
connection arrives, and answers the number of the conversation it accepted.
*/
echo_conversation :: proc "contextless" (lfd: i64, served: string) {
	n := libuser.read(int(lfd), buf[:])
	if n <= 0 {
		fail("netecho: nothing connected")
	}

	// The number `listen` answered names the conversation that was accepted.
	conv: [64]u8
	at := 0
	for i in 0 ..< int(n) {
		if buf[i] < '0' || buf[i] > '9' {
			break
		}
		conv[at] = buf[i]
		at += 1
	}
	base: [128]u8
	// The accepted conversation sits beside the one that announced it.
	cut := 0
	for i in 0 ..< len(served) {
		if served[i] == '/' {
			cut = i
		}
	}
	accepted := libuser.cat_into(base[:], served[:cut + 1], string(conv[:at]))

	dfd := libuser.open(libnet.join(path[:], accepted, "data"), abi.O_RDWR)
	if dfd < 0 {
		fail("netecho: cannot open the stream")
	}
	for {
		got := libuser.read(int(dfd), buf[:])
		if got <= 0 {
			break
		}
		if libuser.write(int(dfd), buf[:int(got)]) != i64(got) {
			break
		}
	}
	// Hang up the accepted conversation, so it closes on both sides and its
	// slot is reclaimed rather than left holding on the far end's close.
	libnet.hangup(accepted)
	_ = libuser.close(int(dfd))
}

// dial_one dials `spec`, says `word`, and prints what comes back. It hangs up
// when it is done. The far end then sees the close, and its own read ends
// rather than waiting for bytes that will not come.
dial_one :: proc "contextless" (spec: string, word: string) {
	fd, dirlen, ok := libnet.dial_dir(spec, dir[:])
	if !ok {
		fail("netecho: cannot dial")
	}
	if libuser.write(fd, transmute([]u8)word) != i64(len(word)) {
		fail("netecho: cannot write")
	}
	got := libuser.read(fd, buf[:])
	libnet.hangup(string(dir[:dirlen]))
	_ = libuser.close(fd)
	if got <= 0 {
		fail("netecho: nothing came back")
	}
	say(string(buf[:int(got)]))
	say("\n")
}
