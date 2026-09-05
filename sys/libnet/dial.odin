/*
dial -- Plan 9's call, over the files `netfs` serves.

    fd, ok := libnet.dial("tcp!fs!9fs")

That is the whole of what a program does to reach another machine. The work is four opens and three lines of text.
None of it is a system call this system had to grow:

    /net/cs    write the dial string, read back a clone file
    clone      read it for a conversation's number
    ctl        write `connect addr!port`
    data       open it, and that is the stream

`announce` is the same shape from the other side: a conversation, an `announce`
line, and a number the caller reads `listen` on. `docs/FLEET.md` gives this
library five calls, and these are the two everything else is built from.

`/net/cs` resolves a name, not this library. A program that dials `tcp!fs!9fs`
and one that dials `tcp!10.0.2.15!564` take the same path, and only the database
knows the difference.
*/
package libnet

import "vsys:abi"
import "vsys:libodin"
import "vsys:libuser"

// The most a dial string, a translation or a path built from one can be.
DIAL_MAX :: 128

/*
dial connects to `addr` and answers a descriptor on the conversation's data
file. The conversation stays open for as long as that descriptor does. A
failure answers false, and a caller that wants to know which step failed reads
`/net/cs` itself.
*/
dial :: proc "contextless" (addr: string) -> (int, bool) #no_bounds_check {
	line: [DIAL_MAX]u8
	n := cs_query(addr, line[:])
	if n <= 0 {
		return -1, false
	}
	clone_path, remote, ok := split_answer(string(line[:n]))
	if !ok {
		return -1, false
	}

	// The conversation, and the directory its files are in.
	dir: [DIAL_MAX]u8
	dirlen, cok := take_conv(clone_path, dir[:])
	if !cok {
		return -1, false
	}

	// Connect it.
	path: [DIAL_MAX]u8
	ctl := libuser.open(join(path[:], string(dir[:dirlen]), "ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return -1, false
	}
	cmd: [DIAL_MAX]u8
	sink := libodin.sink_from(cmd[:])
	libodin.put_str(&sink, "connect ")
	libodin.put_str(&sink, remote)
	text := libodin.str(&sink)
	// The `connect` write is synchronous: `netfs` holds it until the handshake
	// is established, and answers it short if the conversation cannot open. So
	// a write that returns the whole line is a conversation ready for its
	// stream, and there is nothing more to wait for here.
	wrote := libuser.write(int(ctl), transmute([]u8)text) == i64(len(text))
	_ = libuser.close(int(ctl))
	if !wrote {
		return -1, false
	}

	// And the stream.
	data := libuser.open(join(path[:], string(dir[:dirlen]), "data"), abi.O_RDWR)
	if data < 0 {
		return -1, false
	}
	return int(data), true
}

/*
announce takes a conversation and tells it to listen at `addr`. It answers the
directory the conversation's files are in, copied into `into`. A caller then
opens `listen` on it and takes each connection as it arrives.
*/
announce :: proc "contextless" (addr: string, into: []u8) -> (int, bool) #no_bounds_check {
	line: [DIAL_MAX]u8
	n := cs_query(addr, line[:])
	if n <= 0 {
		return 0, false
	}
	clone_path, remote, ok := split_answer(string(line[:n]))
	if !ok {
		return 0, false
	}
	// The port to announce is the far end's, which for an announce is ours.
	port, pok := port_of(remote)
	if !pok {
		return 0, false
	}

	dirlen, cok := take_conv(clone_path, into)
	if !cok {
		return 0, false
	}
	path: [DIAL_MAX]u8
	ctl := libuser.open(join(path[:], string(into[:dirlen]), "ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return 0, false
	}
	cmd: [DIAL_MAX]u8
	sink := libodin.sink_from(cmd[:])
	libodin.put_str(&sink, "announce ")
	libodin.put_str(&sink, port)
	text := libodin.str(&sink)
	wrote := libuser.write(int(ctl), transmute([]u8)text) == i64(len(text))
	_ = libuser.close(int(ctl))
	if !wrote {
		return 0, false
	}
	return dirlen, true
}

// -- The steps ----------------------------------------------------------------

// cs_query writes one dial string to `/net/cs` and reads the answer back.
cs_query :: proc "contextless" (addr: string, into: []u8) -> int {
	fd := libuser.open("/net/cs", abi.O_RDWR)
	if fd < 0 {
		return 0
	}
	if libuser.write(int(fd), transmute([]u8)addr) != i64(len(addr)) {
		_ = libuser.close(int(fd))
		return 0
	}
	n := libuser.read(int(fd), into)
	_ = libuser.close(int(fd))
	return int(max(n, 0))
}

/*
split_answer cuts what `cs` answered into the clone file to open and the far end
to connect to. The answer is one line of two words.
*/
split_answer :: proc "contextless" (line: string) -> (clone: string, remote: string, ok: bool) #no_bounds_check {
	text := line
	for len(text) > 0 && (text[len(text) - 1] == '\n' || text[len(text) - 1] == '\r') {
		text = text[:len(text) - 1]
	}
	for i in 0 ..< len(text) {
		if text[i] == ' ' {
			return text[:i], text[i + 1:], true
		}
	}
	return "", "", false
}

/*
take_conv reads a clone file, which answers a conversation's number, and builds
the directory that conversation's files are in. `/net/tcp/clone` answering `2`
makes `/net/tcp/2`. Answers how long that path is.
*/
take_conv :: proc "contextless" (clone_path: string, dir: []u8) -> (int, bool) #no_bounds_check {
	fd := libuser.open(clone_path, abi.O_RDONLY)
	if fd < 0 {
		return 0, false
	}
	num: [16]u8
	n := libuser.read(int(fd), num[:])
	_ = libuser.close(int(fd))
	if n <= 0 {
		return 0, false
	}
	// The path without its last element is the protocol's directory.
	cut := 0
	for i in 0 ..< len(clone_path) {
		if clone_path[i] == '/' {
			cut = i
		}
	}
	sink := libodin.sink_from(dir)
	libodin.put_str(&sink, clone_path[:cut + 1])
	for i in 0 ..< int(n) {
		if num[i] < '0' || num[i] > '9' {
			break
		}
		one := [1]u8{num[i]}
		libodin.put_str(&sink, string(one[:]))
	}
	return len(libodin.str(&sink)), true
}

// join builds `dir/leaf` into `buf` and answers it. `libuser.cat_into` does the
// concatenation, and this names what the parts are.
join :: proc "contextless" (buf: []u8, dir: string, leaf: string) -> string {
	return libuser.cat_into(buf, dir, "/", leaf)
}

// port_of answers the port out of an `addr!port`.
port_of :: proc "contextless" (remote: string) -> (string, bool) #no_bounds_check {
	for i in 0 ..< len(remote) {
		if remote[i] == '!' {
			return remote[i + 1:], true
		}
	}
	return "", false
}
