/*
auth -- enrol a user, change a passphrase, and become a person.

    auth newuser NAME [group ...]
    auth passwd  NAME
    auth login   NAME

A user is a name and a key pair. The private half is derived from a
passphrase with argon2id, salted with the name and the domain, so it lives
nowhere; the public half goes in `/adm/keys`, one line of `name  hex
groups`, which is the whole user database. `docs/FLEET.md` section 4.

The derivation is `factotum`'s, not this program's: a `key ... !passphrase=`
written to `/mnt/factotum/ctl` derives the private key there and the
passphrase is forgotten, and a read of `ctl` gives every key's public half.
So `newuser` and `passwd` write the passphrase to factotum and read the
public key back, and this program holds no key and links no crypto.

`newuser` appends the line to `/adm/keys`. Where `/adm` is a read-only bind
-- the boot ESP on the bench -- it cannot, and prints the line instead, for
the build to stage the way it stages the first user's. `passwd` rewrites the
line the same way.

`login` is the other half: the passphrase into factotum, `/env/user` and the
kernel's own word for the process set to the name, and a fresh shell exec'd
in place. From there every handshake proves this person, and a file the
server owns for someone else refuses. Only the host owner may become another
user, which is who a login runs as until it is done.
*/
package auth

import "vsys:abi"
import "vsys:libuser"

DOM_DEFAULT :: "home"
KEYS :: "/adm/keys"
CTL :: "/mnt/factotum/ctl"

say :: proc "contextless" (parts: ..string) {
	buf: [256]u8
	_ = libuser.write(2, transmute([]u8)libuser.cat_into(buf[:], ..parts))
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	if len(args) < 2 {
		say("usage: auth newuser|passwd|login NAME [group ...]\n")
		libuser.exits("usage")
	}
	cmd := args[0]
	name := args[1]
	groups := args[2:]

	dom_buf: [64]u8
	dom := read_env("/env/dom", dom_buf[:])
	if dom == "" {
		dom = DOM_DEFAULT
	}

	switch cmd {
	case "newuser":
		enrol(name, dom, groups, rewrite = false)
	case "passwd":
		enrol(name, dom, groups, rewrite = true)
	case "login":
		login(name, dom)
	case:
		say("auth: no such command ", cmd, "\n")
		libuser.exits("usage")
	}
}

// -- Reading a passphrase, and the environment -------------------------------

// ask reads one line -- the passphrase -- from descriptor 0. The prompt goes
// to descriptor 2 so it is seen but not piped. No echo control yet, which is
// the one thing a real login must still grow.
ask :: proc "contextless" (prompt: string) -> (string, bool) {
	say(prompt)
	@(static) line: [256]u8
	n := libuser.read(0, line[:])
	if n <= 0 {
		return "", false
	}
	end := int(n)
	for end > 0 && (line[end - 1] == '\n' || line[end - 1] == '\r') {
		end -= 1
	}
	if end == 0 {
		return "", false
	}
	return string(line[:end]), true
}

read_env :: proc "contextless" (path: string, into: []u8) -> string #no_bounds_check {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return ""
	}
	n := int(libuser.read(int(fd), into))
	_ = libuser.close(int(fd))
	for n > 0 && (into[n - 1] == '\n' || into[n - 1] == 0) {
		n -= 1
	}
	if n <= 0 {
		return ""
	}
	return string(into[:n])
}

// -- factotum: derive a key, and read its public half ------------------------

// derive writes the passphrase to factotum, which derives the private key and
// forgets the passphrase. The key is factotum's from here, for a handshake or
// for `read_pub` to answer its public half.
derive :: proc "contextless" (name, dom, pass: string) -> bool {
	ctl := libuser.open(CTL, abi.O_WRONLY)
	if ctl < 0 {
		say("auth: cannot open ", CTL, " -- is factotum mounted?\n")
		return false
	}
	line: [512]u8
	text := libuser.cat_into(
		line[:],
		"key proto=noise user=", name, " dom=", dom, " !passphrase=", pass,
	)
	ok := libuser.write(int(ctl), transmute([]u8)text) == i64(len(text))
	_ = libuser.close(int(ctl))
	return ok
}

// read_pub answers the public half factotum holds for `name`, as hex, or "".
// A read of `ctl` lists every key as `key ... user=NAME ... pub=HEX`.
read_pub :: proc "contextless" (name: string, into: []u8) -> string #no_bounds_check {
	ctl := libuser.open(CTL, abi.O_RDONLY)
	if ctl < 0 {
		return ""
	}
	@(static) text: [4096]u8
	at := 0
	for at < len(text) {
		n := libuser.read(int(ctl), text[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	_ = libuser.close(int(ctl))

	all := string(text[:at])
	pos := 0
	for pos < len(all) {
		end := pos
		for end < len(all) && all[end] != '\n' {end += 1}
		ln := all[pos:end]
		if attr(ln, "user=") == name {
			pub := attr(ln, "pub=")
			if pub != "" {
				m := copy(into, pub)
				return string(into[:m])
			}
		}
		pos = end + 1
	}
	return ""
}

// attr answers the value of `key` in a line of `k=v` words, or "".
attr :: proc "contextless" (line, key: string) -> string #no_bounds_check {
	at := 0
	for at < len(line) {
		for at < len(line) && line[at] == ' ' {at += 1}
		start := at
		for at < len(line) && line[at] != ' ' {at += 1}
		word := line[start:at]
		if len(word) >= len(key) && word[:len(key)] == key {
			return word[len(key):]
		}
	}
	return ""
}

// -- newuser and passwd ------------------------------------------------------

// enrol derives `name`'s key from a passphrase and writes its public line to
// `/adm/keys`, or prints the line where `/adm` cannot be written. `rewrite`
// is `passwd`: the same, replacing the name's existing line rather than
// adding one.
enrol :: proc "contextless" (name, dom: string, groups: []string, rewrite: bool) {
	pass, ok := ask("passphrase for ")
	if !ok {
		say("auth: no passphrase\n")
		libuser.exits("passphrase")
	}
	if !derive(name, dom, pass) {
		say("auth: factotum would not take the key\n")
		libuser.exits("derive")
	}
	pubbuf: [128]u8
	pub := read_pub(name, pubbuf[:])
	if pub == "" {
		say("auth: factotum has no public key for ", name, "\n")
		libuser.exits("pub")
	}

	// The line: `name  hex  group ...`.
	line: [256]u8
	n := 0
	n += copy(line[n:], name)
	line[n] = ' '; n += 1
	n += copy(line[n:], pub)
	for g in groups {
		line[n] = ' '; n += 1
		n += copy(line[n:], g)
	}
	line[n] = '\n'; n += 1
	full := line[:n]

	if !write_keys(name, string(full), rewrite) {
		// A read-only `/adm`: print the line for the build to stage, the way
		// the first user's is staged. Not a failure -- it is how a bench
		// machine's database grows.
		say("auth: /adm/keys is read-only here; stage this line:\n")
		_ = libuser.write(1, full)
	}
	libuser.exits("")
}

// write_keys adds or replaces `name`'s line in `/adm/keys`. False when the
// file cannot be written, which the caller turns into a printed line.
write_keys :: proc "contextless" (name, line: string, rewrite: bool) -> bool #no_bounds_check {
	// Read the whole file, drop `name`'s old line when rewriting, append the
	// new one, and write it back. A create with truncation, because a wstat
	// of the length is more than the mode gives.
	@(static) text: [8192]u8
	at := 0
	fd := libuser.open(KEYS, abi.O_RDONLY)
	if fd >= 0 {
		for at < len(text) {
			n := libuser.read(int(fd), text[at:])
			if n <= 0 {
				break
			}
			at += int(n)
		}
		_ = libuser.close(int(fd))
	}

	@(static) out: [8192]u8
	w := 0
	all := string(text[:at])
	pos := 0
	for pos < len(all) {
		end := pos
		for end < len(all) && all[end] != '\n' {end += 1}
		ln := all[pos:end + (end < len(all) ? 1 : 0)]
		// A line for this name is dropped on a rewrite; kept otherwise.
		if !(rewrite && first_word(all[pos:end]) == name) {
			w += copy(out[w:], ln)
		}
		pos = end + 1
	}
	w += copy(out[w:], line)

	cfd := libuser.create(KEYS, abi.O_WRONLY, 0o664)
	if cfd < 0 {
		return false
	}
	ok := libuser.write(int(cfd), out[:w]) == i64(w)
	_ = libuser.close(int(cfd))
	return ok
}

first_word :: proc "contextless" (s: string) -> string #no_bounds_check {
	i := 0
	for i < len(s) && s[i] != ' ' && s[i] != '\t' {i += 1}
	return s[:i]
}

// -- login -------------------------------------------------------------------

// login makes this session a person's: the passphrase into factotum, the
// name into `/env/user` and the kernel's own word for the process, and a
// fresh shell exec'd in place. The kernel change is the host owner's to make
// and only for itself, which a login is: it inherits the host's user from
// the shell that ran it, spends it becoming the person, and execs.
login :: proc "contextless" (name, dom: string) {
	pass, ok := ask("passphrase for ")
	if !ok {
		say("auth: no passphrase\n")
		libuser.exits("passphrase")
	}
	if !derive(name, dom, pass) {
		say("auth: factotum would not take the key\n")
		libuser.exits("derive")
	}

	set_env("/env/user", name)
	set_env("/env/dom", dom)

	// Become the person in the kernel too, so `/proc` and a kill name the
	// right owner. `getpid`'s own ctl, no fork between, so the write is for
	// this very process. A refusal means this login did not run as the host.
	path: [48]u8
	pidbuf: [24]u8
	ctl := libuser.open(libuser.cat_into(path[:], "/proc/", itoa(libuser.getpid(), pidbuf[:]), "/ctl"), abi.O_WRONLY)
	if ctl >= 0 {
		line: [64]u8
		if libuser.write(int(ctl), transmute([]u8)libuser.cat_into(line[:], "user ", name)) < 0 {
			say("auth: could not become ", name, " -- not the host owner\n")
		}
		_ = libuser.close(int(ctl))
	}

	// The person's shell, in place of this one.
	argv := [?]string{"rc", "-i"}
	_ = libuser.exec("/bin/rc", argv[:])
	say("auth: could not exec the shell\n")
	libuser.exits("exec")
}

// set_env writes a variable to `/env`, replacing what was there, the way the
// shell does: open-with-truncate, or create. A plain create left the old
// value's tail behind, so `/env/user` read back the host's name with the
// person's written over its front.
set_env :: proc "contextless" (path, value: string) {
	fd := libuser.open_or_create(path, abi.O_WRONLY)
	if fd < 0 {
		return
	}
	_ = libuser.write(int(fd), transmute([]u8)value)
	_ = libuser.close(int(fd))
}

itoa :: proc "contextless" (v: u64, buf: []u8) -> string #no_bounds_check {
	if v == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	tmp: [24]u8
	n := 0
	x := v
	for x > 0 {
		tmp[n] = u8('0' + x % 10)
		n += 1
		x /= 10
	}
	for i in 0 ..< n {
		buf[i] = tmp[n - 1 - i]
	}
	return string(buf[:n])
}
