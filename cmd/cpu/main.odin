/*
cpu -- a shell on another machine, with this terminal's devices, `docs/FLEET.md`
section 7.

`cpu -h HOST` dials HOST's CPU port, authenticates as the person at this
terminal, and then serves this terminal's own namespace back to HOST over the
sealed stream. HOST mounts that at `/mnt/term`, binds the terminal's `/dev`
before its own, and runs a shell whose `/dev/cons` is the terminal's -- so the
shell runs on HOST but reads the keyboard and writes the screen here. `-c CMD`
runs one command instead of an interactive shell; the command travels in the
terminal's `/env/cpucmd`, which HOST reads over the mount.

`cpu -R` is the far half, the CPU port's `listen` service runs it: it is the
responder to the handshake, becomes the proven client, mounts the client's
export, binds its `/dev`, and execs the shell. One binary, both ends, because
the two sides share the handshake and only differ in who serves 9P after it --
here the client does, the reverse of `import`.
*/
package cpu

import "vsys:abi"
import "vsys:libauth"
import "vsys:libnet"
import "vsys:libuser"

// The service name a dial string names, resolved to a port through `ndb`.
SERVICE :: "rcpu"

say :: proc "contextless" (parts: ..string) {
	for p in parts {
		_ = libuser.write(2, transmute([]u8)p)
	}
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]

	if len(args) >= 1 && args[0] == "-R" {
		server()
	}

	host := ""
	cmd := ""
	i := 0
	for i < len(args) {
		switch args[i] {
		case "-h":
			if i + 1 < len(args) {host = args[i + 1];i += 2} else {i += 1}
		case "-c":
			if i + 1 < len(args) {cmd = args[i + 1];i += 2} else {i += 1}
		case:
			i += 1
		}
	}
	if host == "" {
		say("usage: cpu -h host [-c command]\n")
		libuser.exits("usage")
	}
	client(host, cmd)
}

// -- The client, at the terminal -------------------------------------------------

client :: proc(host: string, cmd: string) {
	spec: [96]u8
	fd, ok := libnet.dial(libuser.cat_into(spec[:], "tcp!", host, "!", SERVICE))
	if !ok {
		say("cpu: cannot dial ", host, "\n")
		libuser.exits("dial")
	}
	// Authenticate as the person at this terminal, against the host's key.
	who: [128]u8
	user, dom, wok := libauth.whoami(who[:])
	if !wok {
		say("cpu: no user in the environment: /env/user and /env/dom\n")
		libuser.exits("auth")
	}
	keyb: [64]u8
	key, has := libauth.host_key(host, keyb[:])
	if !has {
		say("cpu: no key= for ", host, " in /lib/ndb/local\n")
		libuser.exits("auth")
	}
	sess, done := libauth.auth_client(int(fd), user, dom, key)
	if !done {
		say("cpu: the handshake with ", host, " failed\n")
		libuser.exits("auth")
	}
	// A command to run, left where the far shell reads it over the mount: the
	// terminal's own environment, which the export carries.
	if cmd != "" {
		put_env("cpucmd", cmd)
	}
	// Serve this terminal's namespace back over the sealed stream. `exportfs`
	// runs until the far shell exits and the stream closes, which is when `cpu`
	// is done; so become it rather than wait on it.
	num: [16]u8
	argv := []string{"exportfs", "-f", libuser.itoa(num[:], i64(sess.fd)), "-r", "/"}
	_ = libuser.exec("/bin/exportfs", argv)
	say("cpu: cannot exec exportfs\n")
	libuser.exits("exec")
}

// -- The server, on the CPU machine ----------------------------------------------

server :: proc() {
	// The handshake, as this host, on the raw stream `listen` handed us.
	who: [128]u8
	host, dom, ok := libauth.whoami(who[:])
	if !ok {
		libuser.exits("cpu: no host user in the environment")
	}
	sess, done := libauth.auth_server(0, host, dom)
	if !done {
		libuser.exits("cpu: the handshake failed")
	}
	name := libauth.session_name(&sess)
	if name == libauth.NONE {
		_ = libuser.close(sess.fd)
		libuser.exits("a stranger, refused")
	}
	// Become the client: the shell, and everything it starts, runs as the
	// person who typed `cpu`, so the files it opens are checked against them.
	become(name)
	// Mount the client's exported namespace, and bind its `/dev` before ours so
	// its `/dev/cons` -- the terminal's -- is the shell's console.
	if !post("/srv/term", sess.fd) {
		libuser.exits("cpu: cannot post /srv/term")
	}
	if libuser.mount("/srv/term", "/mnt/term", abi.ORDER_REPLACE) < 0 {
		libuser.exits("cpu: cannot mount the terminal at /mnt/term")
	}
	if libuser.bind("/mnt/term/dev", "/dev", abi.ORDER_BEFORE) < 0 {
		libuser.exits("cpu: cannot bind the terminal's /dev")
	}
	// The command the client left, if any, read over the mount.
	cbuf: [1024]u8
	cmd := slurp("/mnt/term/env/cpucmd", cbuf[:])
	// The shell's three descriptors are the terminal's console, now `/dev/cons`.
	cons := libuser.open("/dev/cons", abi.O_RDWR)
	if cons >= 0 {
		_ = libuser.dup(int(cons), 0)
		_ = libuser.dup(int(cons), 1)
		_ = libuser.dup(int(cons), 2)
		if int(cons) > 2 {
			_ = libuser.close(int(cons))
		}
	}
	if len(cmd) > 0 {
		argv := []string{"rc", "-c", cmd}
		_ = libuser.exec("/bin/rc", argv)
	} else {
		argv := []string{"rc", "-i"}
		_ = libuser.exec("/bin/rc", argv)
	}
	libuser.exits("cpu: cannot exec rc")
}

// -- Small shared helpers --------------------------------------------------------

// put_env writes `/env/name` with `value`, truncating any old one.
put_env :: proc "contextless" (name: string, value: string) {
	path: [64]u8
	fd := libuser.open_or_create(libuser.cat_into(path[:], "/env/", name), abi.O_WRONLY | abi.O_TRUNC, 0o600)
	if fd < 0 {
		return
	}
	_ = libuser.write(int(fd), transmute([]u8)value)
	_ = libuser.close(int(fd))
}

// slurp reads a file into `buf` and answers what it holds, or "" when absent.
slurp :: proc "contextless" (path: string, buf: []u8) -> string {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return ""
	}
	n := libuser.read(int(fd), buf)
	_ = libuser.close(int(fd))
	if n <= 0 {
		return ""
	}
	return string(buf[:n])
}

// post writes an open descriptor's number into a fresh `/srv` name, the way
// `import` does, so the kernel can mount the stream behind it.
post :: proc "contextless" (path: string, fd: int) -> bool {
	cfd := libuser.create(path, abi.O_WRONLY, 0o600)
	if cfd < 0 {
		return false
	}
	num: [16]u8
	text := libuser.itoa(num[:], i64(fd))
	wrote := libuser.write(int(cfd), transmute([]u8)text) == i64(len(text))
	_ = libuser.close(int(cfd))
	return wrote
}

// become names this process the proven client on its own ctl, and re-mounts the
// writable tree as that user so its files are checked against them -- the same
// step `exportfs` takes when it proves a client.
become :: proc "contextless" (name: string) {
	path: [48]u8
	num: [24]u8
	ctl := libuser.open(libuser.cat_into(path[:], "/proc/", libuser.itoa(num[:], i64(libuser.getpid())), "/ctl"), abi.O_WRONLY)
	if ctl < 0 {
		libuser.exits("cpu: cannot open my own ctl")
	}
	line: [64]u8
	text := libuser.cat_into(line[:], "user ", name)
	wrote := libuser.write(int(ctl), transmute([]u8)text)
	_ = libuser.close(int(ctl))
	if wrote != i64(len(text)) {
		say("cpu: cannot become the client: this process is not the host owner's\n")
		libuser.exits("become")
	}
	_ = libuser.mount("/srv/kfs", "/usr", abi.ORDER_REPLACE)
}
