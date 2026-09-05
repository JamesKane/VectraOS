/*
listen -- announce a service per port, and run its script for each connection.

    listen [dir]

Every file in `dir`, `/lib/service` by default, named `tcpNNN` is a service on
port NNN. `listen` announces each, and for each connection that arrives runs
the file as an rc script with the stream as descriptors zero and one:
`/lib/service/tcp564` is `exec exportfs -r /`, and a new service is a new
file. `docs/FLEET.md` section 5, with the scripts under `/lib` where this
tree keeps them rather than Plan 9's `/rc/bin/service`.

One process listens per port, forked from this one. For each connection it
forks a helper, which forks again to run the script and then hangs the
conversation up when the script exits, so a finished service leaves no
conversation in the stack's table. The listener goes on to the next
connection at once.
*/
package listen

import "vsys:abi"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"
import "vsys:vectra9"

dir_buf: [128]u8
names_buf: [4096]u8

say :: proc "contextless" (text: string) {
	_ = libuser.write(2, transmute([]u8)text)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	dir := "/lib/service"
	if len(args) >= 2 {
		dir = args[1]
	}
	names, ok := libuser.read_dir(dir, context.allocator)
	if !ok {
		say("listen: cannot read ")
		say(dir)
		say("\n")
		libuser.exits("no services")
	}
	started := 0
	for name in names {
		if len(name) < 4 || name[:3] != "tcp" {
			continue
		}
		port := name[3:]
		for i in 0 ..< len(port) {
			if port[i] < '0' || port[i] > '9' {
				continue
			}
		}
		pid := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOWAIT)
		if pid < 0 {
			say("listen: cannot fork\n")
			continue
		}
		if pid == 0 {
			serve_port(dir, name, port)
		}
		started += 1
	}
	if started == 0 {
		libuser.exits("no services")
	}
	libuser.exits("")
}

/*
serve_port announces one port and takes each connection as it arrives. Each
is handed to a helper that runs the script and cleans up after it.
*/
serve_port :: proc "contextless" (dir: string, script: string, port: string) -> ! {
	spec: [64]u8
	addr := libuser.cat_into(spec[:], "tcp!*!", port)
	served: [128]u8
	dirlen, ok := libnet.announce(addr, served[:])
	if !ok {
		say("listen: cannot announce ")
		say(addr)
		say("\n")
		libuser.exits("announce")
	}
	path: [160]u8
	lfd := libuser.open(libnet.join(path[:], string(served[:dirlen]), "listen"), abi.O_RDONLY)
	if lfd < 0 {
		libuser.exits("listen")
	}
	line: [32]u8
	for {
		n := libuser.read(int(lfd), line[:])
		if n <= 0 {
			libuser.exits("listen ended")
		}
		digits := 0
		for digits < int(n) && line[digits] >= '0' && line[digits] <= '9' {
			digits += 1
		}
		// The accepted conversation sits beside the announcing one.
		cut := 0
		for i in 0 ..< dirlen {
			if served[i] == '/' {
				cut = i
			}
		}
		conv: [160]u8
		accepted := libuser.cat_into(conv[:], string(served[:cut + 1]), string(line[:digits]))
		pid := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOWAIT)
		if pid == 0 {
			run_service(dir, script, accepted)
		}
	}
}

/*
run_service is the helper: it opens the stream, forks the script onto it,
waits for the script, and hangs the conversation up. The script sees the
stream as descriptors zero and one, and the conversation's directory as its
argument.
*/
run_service :: proc "contextless" (dir: string, script: string, accepted: string) -> ! {
	path: [160]u8
	data := libuser.open(libnet.join(path[:], accepted, "data"), abi.O_RDWR)
	if data < 0 {
		libuser.exits("data")
	}
	pid := libuser.rfork(abi.RFPROC | abi.RFFDG)
	if pid == 0 {
		_ = libuser.dup(int(data), 0)
		_ = libuser.dup(int(data), 1)
		_ = libuser.close(int(data))
		file: [160]u8
		spath := libnet.join(file[:], dir, script)
		argv := [?]string{"rc", spath, accepted}
		_ = libuser.exec("/bin/rc", argv[:])
		libuser.exits("exec")
	}
	_ = libuser.close(int(data))
	if pid > 0 {
		// `await` gives up every so often so a parked caller can hear a
		// note; wait until the service is really gone before hanging up,
		// or the far side loses its stream mid-request.
		word: [64]u8
		for {
			n := libuser.await(u64(pid), word[:])
			if n != -i64(vectra9.EAGAIN) {
				break
			}
		}
	}
	libnet.hangup(accepted)
	libuser.exits("")
}

// `libodin` keeps the sink the announce spec is built with in scope for a
// later `-v`; the name is used so the import is.
_ :: libodin.Sink
