/*
The Webmention endpoint: `docs/WEB.md` section 9's "the two-way link as
a W3C standard". A POST to `/mention` carries `source` and `target`,
form-encoded. `httpd` fetches the source through `webfs`, verifies it
links to the target, and writes it as a file under the mention store,
which `mentionfs` serves at `/mnt/mention`. A source that does not link
here is refused, the one control the plan names.

A mention file is `source`, `target` and `title` lines under
`<store>/mention/<hash>.txt`, where the hash is the source and target
made a name, so the same mention twice is one file.
*/
package httpd

import "vsys:abi"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libuser"

mention_store: string
mention_buf: [256]u8

take_post :: proc(wfd: int, target: string, headers: string, body: string) {
	if target != "/mention" {
		respond(wfd, 404, "text/plain", "not found\n", false)
		return
	}
	if mention_store == "" {
		respond(wfd, 400, "text/plain", "mentions are not accepted here\n", false)
		return
	}
	src: [1024]u8
	tgt: [1024]u8
	sn := form_value(body, "source", src[:])
	tn := form_value(body, "target", tgt[:])
	source := string(src[:sn])
	tg := string(tgt[:tn])
	if source == "" || tg == "" {
		respond(wfd, 400, "text/plain", "source and target are wanted\n", false)
		return
	}
	// The source, fetched, and the target found in it, or the mention is
	// refused: a source that does not link here is not a mention.
	page := make([dynamic]u8, 0, 8192)
	defer delete(page)
	if !fetch(source, &page) || !libodin.contains(string(page[:]), tg) {
		respond(wfd, 400, "text/plain", "the source does not link to the target\n", false)
		return
	}
	title := page_title(string(page[:]))
	// The file, its name the source and target hashed to a word.
	file := make([dynamic]u8, 0, 512)
	defer delete(file)
	libmsg.put(&file, "source: ")
	libmsg.put(&file, source)
	libmsg.put(&file, "\ntarget: ")
	libmsg.put(&file, tg)
	libmsg.put(&file, "\ntitle: ")
	libmsg.put(&file, title)
	libmsg.put(&file, "\n")
	name: [80]u8
	nn := hash_name(source, tg, name[:])
	dir: [320]u8
	_ = libuser.mkdir(mention_store)
	mdir := libuser.cat_into(dir[:], mention_store, "/mention")
	_ = libuser.mkdir(mdir)
	full: [400]u8
	fp := libuser.cat_into(full[:], mdir, "/", string(name[:nn]), ".txt")
	if old := libuser.open(fp, abi.O_RDONLY); old >= 0 {
		_ = libuser.close(int(old))
		_ = libuser.remove(fp)
	}
	fd := libuser.create(fp, abi.O_WRONLY, 0o644)
	if fd < 0 {
		respond(wfd, 500, "text/plain", "could not keep the mention\n", false)
		return
	}
	_ = libuser.write_full(int(fd), file[:])
	_ = libuser.close(int(fd))
	respond(wfd, 202, "text/plain", "accepted\n", false)
}

// fetch reads `url` through webfs into `into`, mounting webfs if it is
// not there. Plain file operations, since httpd serves one request at a
// time and has no other thread to keep running.
fetch :: proc(url: string, into: ^[dynamic]u8) -> bool {
	num: [16]u8
	n := read_small("/mnt/web/clone", num[:])
	if n <= 0 {
		if libuser.mount("/srv/web", "/mnt/web", 0) < 0 {
			return false
		}
		n = read_small("/mnt/web/clone", num[:])
		if n <= 0 {
			return false
		}
	}
	conv := string(num[:n])
	path: [128]u8
	line: [1200]u8
	ctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return false
	}
	req := libuser.cat_into(line[:], "url ", url)
	wrote := libuser.write(int(ctl), transmute([]u8)req) == i64(len(req))
	_ = libuser.close(int(ctl))
	if !wrote {
		return false
	}
	bfd := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/body"), abi.O_RDONLY)
	if bfd < 0 {
		return false
	}
	buf: [8192]u8
	for {
		got := libuser.read(int(bfd), buf[:])
		if got <= 0 {
			break
		}
		append(into, ..buf[:got])
	}
	_ = libuser.close(int(bfd))
	if hctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY); hctl >= 0 {
		_ = libuser.write(int(hctl), transmute([]u8)string("hangup"))
		_ = libuser.close(int(hctl))
	}
	return len(into) > 0
}

read_small :: proc(path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	total := 0
	for total < len(into) {
		n := libuser.read(int(fd), into[total:])
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

// form_value answers the value of `name` in a form-encoded body, its
// percent-escapes and pluses decoded, into `out`.
form_value :: proc "contextless" (body: string, name: string, out: []u8) -> int {
	at := 0
	for at < len(body) {
		e := at
		for e < len(body) && body[e] != '&' {
			e += 1
		}
		pair := body[at:e]
		if len(pair) > len(name) + 1 && pair[:len(name)] == name && pair[len(name)] == '=' {
			return libodin.url_decode(pair[len(name) + 1:], out)
		}
		at = e + 1
	}
	return 0
}



// hash_name answers a file name for a mention: a stable word of the
// source and target, so the same pair writes one file.
hash_name :: proc "contextless" (source: string, target: string, out: []u8) -> int {
	h: u64 = 1469598103934665603
	for c in transmute([]u8)source {
		h = (h ~ u64(c)) * 1099511628211
	}
	h = (h ~ '|') * 1099511628211
	for c in transmute([]u8)target {
		h = (h ~ u64(c)) * 1099511628211
	}
	hex := "0123456789abcdef"
	n := 0
	for shift := 60; shift >= 0 && n < len(out); shift -= 4 {
		out[n] = hex[(h >> u64(shift)) & 15]
		n += 1
	}
	return n
}

// page_title answers the text of a page's <title>, or "".
page_title :: proc "contextless" (html: string) -> string {
	open := "<title>"
	i := libodin.index(html, open)
	if i < 0 {
		return ""
	}
	start := i + len(open)
	j := libodin.index(html[start:], "</title>")
	if j < 0 {
		return ""
	}
	return html[start:start + j]
}


