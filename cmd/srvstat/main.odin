/*
srvstat -- how each server posted in /srv is, `docs/CHROME.md` section 10.

    srvstat [name ...]

A name in `/srv` says a server is posted. It does not say the server
answers. So a server may serve a `status` file at its root, one word:
`ok`, `degraded`, `starting` or `failed`. This mounts each name, reads the
word, and prints a line per name: the name, the LED's colour, and why.

    draw       green  ok
    kfs        amber  degraded
    wedged     red    timeout
    gone       off    none

| What it finds                                        | LED   |
|------------------------------------------------------|-------|
| the name, and `status` says `ok`, or has no `status` | green |
| `status` says `degraded` or `starting`               | amber |
| `status` says `failed`, the mount is refused, or it  | red   |
| does not answer in two seconds                       |       |
| no name in `/srv`                                    | off   |

With no names, every name in `/srv` is read, in order. A name that is
not there is `off`, so a script may ask after a server it expects.

**Each name is read on an io proc of its own, which takes a namespace of
its own before it mounts.** So a mount that answers late lands where no
other read looks. The wait is two seconds, and a wedged server costs a red
line and never a wedged `srvstat`.
*/
package srvstat

import "vsys:abi"
import "vsys:libthread"
import "vsys:libuser"

WAIT_MS :: 2000

// What a probe found, as the channel carries it.
Found :: enum u64 {
	Ok,
	None, // Posted, answering, and no `status`
	Degraded,
	Starting,
	Failed,
	Other, // A word this does not know, reported as it is
	Refused,
	Timeout,
}

Probe :: struct {
	name:  string,
	done:  ^libthread.Chan,
	word:  [16]u8,
	n:     int,
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	given = libuser.args(block)[1:]
	libthread.main(threadmain, nil)
}

given: []string

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	names := given
	if len(names) == 0 {
		fd := libuser.open("/srv", abi.O_RDONLY)
		if fd < 0 {
			libuser.eprint("srvstat: cannot read /srv\n")
			libthread.threadexitsall("srv")
		}
		names = libuser.list_dir(int(fd))
		_ = libuser.close(int(fd))
		libuser.sort_strings(names)
	}
	for name in names {
		report(name)
	}
	libthread.threadexitsall("")
}

// report reads one name and prints its line.
report :: proc "contextless" (name: string) {
	pb: [128]u8
	st: abi.Stat
	if libuser.stat(libuser.cat_into(pb[:], "/srv/", name), &st) < 0 {
		line(name, "off", "none")
		return
	}
	p := (^Probe)(libuser.heap_alloc(size_of(Probe)))
	if p == nil {
		line(name, "red", "memory")
		return
	}
	p^ = {}
	p.name = name
	// Room for both answers, so the one that comes second never waits:
	// the probe's, and the sleeper's.
	p.done = libthread.chancreate(size_of(u64), 2)
	if p.done == nil || libthread.threadcreate(probe_thread, p) < 0 || libthread.threadcreate(sleep_thread, p) < 0 {
		line(name, "red", "memory")
		return
	}
	found := Found(libthread.recvul(p.done))
	switch found {
	case .Ok:
		line(name, "green", "ok")
	case .None:
		line(name, "green", "-")
	case .Degraded:
		line(name, "amber", "degraded")
	case .Starting:
		line(name, "amber", "starting")
	case .Failed:
		line(name, "red", "failed")
	case .Other:
		line(name, "red", string(p.word[:p.n]))
	case .Refused:
		line(name, "red", "refused")
	case .Timeout:
		line(name, "red", "timeout")
	}
	// The probe and its io proc stay with a late answer, and go when the
	// program does. The record goes with them.
}

line :: proc "contextless" (name: string, led: string, why: string) {
	out: [192]u8
	w := copy(out[:], name)
	for w < 12 {
		out[w] = ' '
		w += 1
	}
	out[w] = ' '
	w += 1
	w += copy(out[w:], led)
	for w < 20 {
		out[w] = ' '
		w += 1
	}
	out[w] = ' '
	w += 1
	w += copy(out[w:], why)
	out[w] = '\n'
	_ = libuser.write(1, out[:w + 1])
}

// probe_thread reads the name on an io proc and tells what it found.
probe_thread :: proc "contextless" (arg: rawptr) {
	p := (^Probe)(arg)
	io := libthread.ioproc()
	if io == nil {
		libthread.sendul(p.done, u64(Found.Refused))
		libthread.threadexits("")
	}
	found := libthread.iorun(io, probe, p)
	libthread.sendul(p.done, u64(found))
	libthread.threadexits("")
}

// sleep_thread tells a timeout after the wait.
sleep_thread :: proc "contextless" (arg: rawptr) {
	p := (^Probe)(arg)
	io := libthread.ioproc()
	if io != nil {
		_ = libthread.iosleep(io, WAIT_MS)
	}
	libthread.sendul(p.done, u64(Found.Timeout))
	libthread.threadexits("")
}

/*
probe runs on the io proc: a namespace of its own, the name mounted over
`/mnt` in it, and the word in `status` read.
*/
probe :: proc "contextless" (arg: rawptr) -> i64 {
	p := (^Probe)(arg)
	if libuser.rfork(abi.RFNAMEG) < 0 {
		return i64(Found.Refused)
	}
	pb: [128]u8
	if libuser.mount(libuser.cat_into(pb[:], "/srv/", p.name), "/mnt", abi.ORDER_REPLACE) < 0 {
		return i64(Found.Refused)
	}
	fd := libuser.open("/mnt/status", abi.O_RDONLY)
	if fd < 0 {
		return i64(Found.None)
	}
	buf: [32]u8
	n := libuser.read(int(fd), buf[:])
	_ = libuser.close(int(fd))
	word := string(buf[:max(int(n), 0)])
	for len(word) > 0 && (word[len(word) - 1] == '\n' || word[len(word) - 1] == ' ') {
		word = word[:len(word) - 1]
	}
	p.n = copy(p.word[:], word)
	switch word {
	case "ok":
		return i64(Found.Ok)
	case "degraded":
		return i64(Found.Degraded)
	case "starting":
		return i64(Found.Starting)
	case "failed":
		return i64(Found.Failed)
	}
	return i64(Found.Other)
}
