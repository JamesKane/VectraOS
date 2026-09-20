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
