/*
Factotum, for a network's login: a key written to its ctl, and a
question asked over its rpc. A network puts a token there and asks for
it on every request, never keeping it, the way mail's password goes.
Factotum is mounted at /mnt/factotum from /srv/factotum when it is not
there already.
*/
package libmsg

import "vsys:abi"
import "vsys:libodin"
import "vsys:libuser"

// factotum_write writes one line to factotum's ctl: a key.
factotum_write :: proc(line: string) -> bool {
	ctl := libuser.open("/mnt/factotum/ctl", abi.O_WRONLY)
	if ctl < 0 {
		if libuser.mount("/srv/factotum", "/mnt/factotum", 0) < 0 {
			return false
		}
		ctl = libuser.open("/mnt/factotum/ctl", abi.O_WRONLY)
		if ctl < 0 {
			return false
		}
	}
	defer _ = libuser.close(int(ctl))
	return libuser.write(int(ctl), transmute([]u8)line) == i64(len(line))
}

// factotum_ask asks factotum one question over rpc and answers the value
// after `prefix` in its reply, `password ` or `token `, into `into`.
factotum_ask :: proc(question: string, prefix: string, into: []u8) -> (string, bool) {
	rpc := libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	if rpc < 0 {
		if libuser.mount("/srv/factotum", "/mnt/factotum", 0) < 0 {
			return "", false
		}
		rpc = libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
		if rpc < 0 {
			return "", false
		}
	}
	defer _ = libuser.close(int(rpc))
	if libuser.write(int(rpc), transmute([]u8)question) != i64(len(question)) {
		return "", false
	}
	n := libuser.read(int(rpc), into)
	if n <= 0 {
		return "", false
	}
	line := string(into[:n])
	for len(line) > 0 && line[len(line) - 1] == '\n' {
		line = line[:len(line) - 1]
	}
	if !libodin.has_prefix(line, prefix) {
		return "", false
	}
	return line[len(prefix):], true
}

// host_of answers a URL's host, with its port when it has one.
host_of :: proc "contextless" (url: string) -> string {
	s := url
	i := 0
	for i + 2 < len(s) && s[i:i + 3] != "://" {
		i += 1
	}
	if i + 3 <= len(s) {
		s = s[i + 3:]
	}
	e := 0
	for e < len(s) && s[e] != '/' {
		e += 1
	}
	return s[:e]
}
