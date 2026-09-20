/*
A network's source: a URL through `webfs`, or a saved answer's path
read as it is, so a network is proven offline on a file and reads the
wire the same way. Every read goes through the caller's io proc, so a
server's other threads run meanwhile. `docs/WEB.md` section 4.
*/
package libmsg

import "vsys:abi"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"

SOURCE_MAX :: 512
SOURCE_BYTES :: 1024 * 1024 // The most a source may answer

// read_source reads a URL through webfs, or a path as it is.
read_source :: proc(io: ^libthread.Ioproc, source: string) -> (text: []u8, ok: bool) {
	if is_url(source) {
		return read_url(io, source)
	}
	fd := libuser.open(source, abi.O_RDONLY)
	if fd < 0 {
		return nil, false
	}
	defer _ = libuser.close(int(fd))
	return read_all(io, int(fd))
}

// read_url fetches `url` through webfs at /mnt/web, mounting it from
// /srv/web when it is not there, and answers the body.
read_url :: proc(io: ^libthread.Ioproc, url: string) -> (text: []u8, ok: bool) {
	num: [16]u8
	n := read_small(io, "/mnt/web/clone", num[:])
	if n <= 0 {
		_ = libthread.iomount(io, "/srv/web", "/mnt/web", 0)
		n = read_small(io, "/mnt/web/clone", num[:])
		if n <= 0 {
			return nil, false
		}
	}
	conv := string(num[:n])
	path: [128]u8
	line: [SOURCE_MAX + 8]u8
	ctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return nil, false
	}
	req := libuser.cat_into(line[:], "url ", url)
	wrote := libthread.iowrite(io, int(ctl), transmute([]u8)req) == i64(len(req))
	_ = libuser.close(int(ctl))
	if !wrote {
		return nil, false
	}
	body := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/body"), abi.O_RDONLY)
	if body < 0 {
		return nil, false
	}
	text, ok = read_all(io, int(body))
	_ = libuser.close(int(body))
	if hctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY); hctl >= 0 {
		_ = libthread.iowrite(io, int(hctl), transmute([]u8)string("hangup"))
		_ = libuser.close(int(hctl))
	}
	return text, ok
}

/*
request makes one request through webfs with more than a URL: a method,
header lines, and a body for a POST. It answers the response's body
and its status code, and false when the conversation would not run.
`headers` is zero or more `Name: value` lines, one per line.
*/
request :: proc(io: ^libthread.Ioproc, url: string, method: string, headers: string, body: string) -> (text: []u8, status: int, ok: bool) {
	text, status, _, ok = request_with(io, url, method, headers, body, "", nil)
	return text, status, ok
}

/*
request_with is `request`, and one response header answered too: the
value of `want` into `hbuf`, `hlen` its length, or zero when the
response did not carry it. A server that binds a token to a key gives
its nonce in one, `DPoP-Nonce`, and a request must carry it back.
*/
request_with :: proc(io: ^libthread.Ioproc, url: string, method: string, headers: string, body: string, want: string, hbuf: []u8) -> (text: []u8, status: int, hlen: int, ok: bool) {
	num: [16]u8
	n := read_small(io, "/mnt/web/clone", num[:])
	if n <= 0 {
		_ = libthread.iomount(io, "/srv/web", "/mnt/web", 0)
		n = read_small(io, "/mnt/web/clone", num[:])
		if n <= 0 {
			return nil, 0, 0, false
		}
	}
	conv := string(num[:n])
	path: [128]u8
	// A header line may carry a signed proof, which is longer than a URL.
	line: [4096]u8
	ctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return nil, 0, 0, false
	}
	req := libuser.cat_into(line[:], "url ", url)
	wrote := libthread.iowrite(io, int(ctl), transmute([]u8)req) == i64(len(req))
	if wrote && method != "" {
		req = libuser.cat_into(line[:], "method ", method)
		wrote = libthread.iowrite(io, int(ctl), transmute([]u8)req) == i64(len(req))
	}
	at := 0
	for wrote && at < len(headers) {
		e := at
		for e < len(headers) && headers[e] != '\n' {
			e += 1
		}
		if e > at {
			req = libuser.cat_into(line[:], "header ", headers[at:e])
			wrote = libthread.iowrite(io, int(ctl), transmute([]u8)req) == i64(len(req))
		}
		at = e + 1
	}
	_ = libuser.close(int(ctl))
	if !wrote {
		return nil, 0, 0, false
	}
	if len(body) > 0 {
		pb := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/postbody"), abi.O_WRONLY)
		if pb < 0 {
			return nil, 0, 0, false
		}
		sent := libthread.iowrite(io, int(pb), transmute([]u8)body) == i64(len(body))
		_ = libuser.close(int(pb))
		if !sent {
			return nil, 0, 0, false
		}
	}
	bfd := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/body"), abi.O_RDONLY)
	if bfd < 0 {
		return nil, 0, 0, false
	}
	text, ok = read_all(io, int(bfd))
	_ = libuser.close(int(bfd))
	if want != "" && hbuf != nil {
		// The response's headers, for the one wanted, whatever its case.
		hfd := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/headers"), abi.O_RDONLY)
		if hfd >= 0 {
			if all, hok := read_all(io, int(hfd)); hok {
				hlen = header_of(string(all), want, hbuf)
				delete(all)
			}
			_ = libuser.close(int(hfd))
		}
	}
	code: [64]u8
	if cn := read_small(io, libuser.cat_into(path[:], "/mnt/web/", conv, "/status"), code[:]); cn > 0 {
		for i in 0 ..< cn {
			if code[i] < '0' || code[i] > '9' {
				break
			}
			status = status * 10 + int(code[i] - '0')
		}
	}
	if hctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY); hctl >= 0 {
		_ = libthread.iowrite(io, int(hctl), transmute([]u8)string("hangup"))
		_ = libuser.close(int(hctl))
	}
	return text, status, hlen, ok
}

// header_of answers the value of the header `name` in a block of header
// lines, its case ignored, copied into `into`; zero when absent.
header_of :: proc "contextless" (all: string, name: string, into: []u8) -> int {
	at := 0
	for at < len(all) {
		e := at
		for e < len(all) && all[e] != '\n' {
			e += 1
		}
		line := all[at:e]
		at = e + 1
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if len(line) <= len(name) || line[len(name)] != ':' {
			continue
		}
		same := true
		for i in 0 ..< len(name) {
			a := line[i]
			b := name[i]
			if a >= 'A' && a <= 'Z' {
				a += 32
			}
			if b >= 'A' && b <= 'Z' {
				b += 32
			}
			if a != b {
				same = false
				break
			}
		}
		if !same {
			continue
		}
		v := line[len(name) + 1:]
		for len(v) > 0 && v[0] == ' ' {
			v = v[1:]
		}
		return copy(into, v)
	}
	return 0
}

// read_all reads a descriptor to its end, up to SOURCE_BYTES.
read_all :: proc(io: ^libthread.Ioproc, fd: int) -> (text: []u8, ok: bool) {
	buf := make([dynamic]u8, 0, 16384)
	chunk: [8192]u8
	for len(buf) < SOURCE_BYTES {
		got := libthread.ioread(io, fd, chunk[:])
		if got < 0 {
			delete(buf)
			return nil, false
		}
		if got == 0 {
			break
		}
		append(&buf, ..chunk[:got])
	}
	return buf[:], true
}

// read_small reads a small file whole, its trailing newline off.
read_small :: proc(io: ^libthread.Ioproc, path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	total := 0
	for total < len(into) {
		n := libthread.ioread(io, int(fd), into[total:])
		if n <= 0 {
			break
		}
		total += int(n)
	}
	_ = libuser.close(int(fd))
	for total > 0 && (into[total - 1] == '\n' || into[total - 1] == '\r') {
		total -= 1
	}
	return total
}

// now_seconds answers the clock, seconds since the epoch, off /dev/time.
now_seconds :: proc "contextless" () -> i64 {
	fd := libuser.open("/dev/time", abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	line: [96]u8
	n := libuser.read(int(fd), line[:])
	_ = libuser.close(int(fd))
	sec: i64
	for i in 0 ..< int(n) {
		c := line[i]
		if c < '0' || c > '9' {
			break
		}
		sec = sec * 10 + i64(c - '0')
	}
	return sec
}

// keep_sent writes what a network answered for a message written to
// `new` under `dir/sent/<id>.json`, the record or the activity as the
// server sent it, so what the person wrote is theirs before the network
// has it. Nothing is kept when `dir` is empty.
keep_sent :: proc(dir: string, id: string, text: string) -> bool {
	if dir == "" {
		return true
	}
	path: [512]u8
	_ = libuser.mkdir(dir)
	sent := libuser.cat_into(path[:], dir, "/sent")
	_ = libuser.mkdir(sent)
	full: [512]u8
	name := libuser.cat_into(full[:], sent, "/", id, ".json")
	_ = libuser.remove(name)
	fd := libuser.create(name, abi.O_WRONLY, 0o644)
	if fd < 0 {
		return false
	}
	ok := libuser.write_full(int(fd), transmute([]u8)text)
	_ = libuser.close(int(fd))
	return ok
}

// name_for is the conversation a source is called when no name is given:
// a URL's host, or a path's last element without its suffix.
name_for :: proc "contextless" (source: string) -> string {
	s := source
	if is_url(s) {
		i := 0
		for i + 2 < len(s) && s[i:i + 3] != "://" {
			i += 1
		}
		s = s[i + 3:]
		e := 0
		for e < len(s) && s[e] != '/' && s[e] != ':' {
			e += 1
		}
		return s[:e]
	}
	base := libuser.basename(s)
	for i := len(base) - 1; i > 0; i -= 1 {
		if base[i] == '.' {
			return base[:i]
		}
	}
	return base
}

is_url :: proc "contextless" (s: string) -> bool {
	return libodin.has_prefix(s, "http://") || libodin.has_prefix(s, "https://") || libodin.has_prefix(s, "gemini://")
}
