/*
webmention -- tell each page a page of yours links to that it did:
`docs/WEB.md` section 9's "Webmention, both ways", the sending half. It
reads a published page, finds the links in it, discovers each target's
Webmention endpoint, and posts the mention, so the two-way link is made
the moment a page goes up.

    webmention -s SOURCE PAGE

`SOURCE` is the page's own URL, the way a reader reaches it, and `PAGE`
is the file on disk. For each link, `webmention` fetches the target
through `webfs`, reads its `Link: <url>; rel="webmention"` header, and
posts `source` and `target` form-encoded to the endpoint. A target with
no endpoint is skipped. It says how many mentions it sent.
*/
package webmention

import "vsys:abi"
import "vsys:libdoc"
import "vsys:libmark"
import "vsys:libodin"
import "vsys:libuser"

say :: proc "contextless" (parts: ..string) {
	libuser.eprint(..parts)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	source := ""
	page := ""
	for i := 1; i < len(args); i += 1 {
		if args[i] == "-s" && i + 1 < len(args) {
			source = args[i + 1]
			i += 1
		} else if page == "" {
			page = args[i]
		}
	}
	if source == "" || page == "" {
		say("usage: webmention -s SOURCE PAGE\n")
		libuser.exits("usage")
	}
	data, ok := libuser.read_file(page, context.allocator)
	if !ok {
		say("webmention: cannot read ", page, "\n")
		libuser.exits("no page")
	}
	d: libdoc.Doc
	libdoc.doc_init(&d)
	libmark.parse(&d, string(data))

	sent := 0
	for i in 0 ..< len(d.blocks) {
		b := &d.blocks[i]
		if b.kind != .Link && b.kind != .Image {
			continue
		}
		target := libdoc.block_href(&d, i)
		if !is_http(target) {
			continue
		}
		if send_one(source, target) {
			sent += 1
			say("webmention: told ", target, "\n")
		}
	}
	num: [24]u8
	say("webmention: sent ", libuser.itoa(num[:], i64(sent)), "\n")
	libuser.exits("")
}

// send_one discovers the target's endpoint and posts the mention, true
// when the endpoint accepted it.
send_one :: proc(source: string, target: string) -> bool {
	headers: [2048]u8
	hn, _ := fetch(target, "", "", headers[:])
	endpoint: [1024]u8
	en := endpoint_of(string(headers[:hn]), target, endpoint[:])
	if en == 0 {
		return false
	}
	// The mention, form-encoded, posted to the endpoint.
	form: [2200]u8
	fn := 0
	fn += copy(form[fn:], "source=")
	fn += libodin.url_encode(form[fn:], source)
	fn += copy(form[fn:], "&target=")
	fn += libodin.url_encode(form[fn:], target)
	rh: [512]u8
	_, pcode := fetch(string(endpoint[:en]), string(form[:fn]), "application/x-www-form-urlencoded", rh[:])
	return pcode >= 200 && pcode < 300
}

// endpoint_of answers the Webmention endpoint of a target, from its
// `Link: <url>; rel="webmention"` header, resolved against the target
// when the URL is relative. Zero when there is none.
endpoint_of :: proc "contextless" (headers: string, target: string, out: []u8) -> int {
	at := 0
	for at < len(headers) {
		e := at
		for e < len(headers) && headers[e] != '\n' {
			e += 1
		}
		line := headers[at:e]
		if line_is(line, "link") && has_webmention_rel(line) {
			// The URL is between the first `<` and `>`.
			lt := libodin.index(line, "<")
			gt := libodin.index(line, ">")
			if lt >= 0 && gt > lt {
				url := line[lt + 1:gt]
				return resolve(target, url, out)
			}
		}
		at = e + 1
	}
	return 0
}

has_webmention_rel :: proc "contextless" (line: string) -> bool {
	return libodin.index(line, "webmention") >= 0
}

// resolve joins a possibly-relative endpoint to the target's origin.
resolve :: proc "contextless" (target: string, url: string, out: []u8) -> int {
	if is_http(url) {
		return copy(out, url)
	}
	// The origin of the target: scheme, host, up to the first slash of the path.
	i := libodin.index(target, "://")
	if i < 0 {
		return copy(out, url)
	}
	host_start := i + 3
	slash := host_start
	for slash < len(target) && target[slash] != '/' {
		slash += 1
	}
	n := copy(out, target[:slash])
	if len(url) > 0 && url[0] != '/' && n < len(out) {
		out[n] = '/'
		n += 1
	}
	n += copy(out[n:], url)
	return n
}

/*
fetch reads `url` through webfs: a GET, or a POST when `body` is given.
Answers the response headers into `hbuf` and its length, and the status
code. Plain file operations, one request at a time.
*/
fetch :: proc(url: string, body: string, ctype: string, hbuf: []u8) -> (hlen: int, status: int) {
	drain: [1024]u8
	num: [16]u8
	n := read_small("/mnt/web/clone", num[:])
	if n <= 0 {
		if libuser.mount("/srv/web", "/mnt/web", 0) < 0 {
			return 0, 0
		}
		n = read_small("/mnt/web/clone", num[:])
		if n <= 0 {
			return 0, 0
		}
	}
	conv := string(num[:n])
	path: [128]u8
	line: [1200]u8
	ctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return 0, 0
	}
	ok := writeln(int(ctl), libuser.cat_into(line[:], "url ", url))
	if body != "" {
		ok = writeln(int(ctl), "method POST") && ok
		ok = writeln(int(ctl), libuser.cat_into(line[:], "header Content-Type: ", ctype)) && ok
	}
	_ = libuser.close(int(ctl))
	if !ok {
		return 0, 0
	}
	if body != "" {
		pb := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/postbody"), abi.O_WRONLY)
		if pb >= 0 {
			_ = libuser.write(int(pb), transmute([]u8)body)
			_ = libuser.close(int(pb))
		}
	}
	// The body is read to drive the fetch, then the headers and status.
	bfd := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/body"), abi.O_RDONLY)
	if bfd >= 0 {
		for {
			got := libuser.read(int(bfd), drain[:])
			if got <= 0 {
				break
			}
		}
		_ = libuser.close(int(bfd))
	}
	hlen = read_small(libuser.cat_into(path[:], "/mnt/web/", conv, "/headers"), hbuf)
	if hlen < 0 {
		hlen = 0
	}
	code: [64]u8
	if cn := read_small(libuser.cat_into(path[:], "/mnt/web/", conv, "/status"), code[:]); cn > 0 {
		for i in 0 ..< cn {
			if code[i] < '0' || code[i] > '9' {
				break
			}
			status = status * 10 + int(code[i] - '0')
		}
	}
	if hctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY); hctl >= 0 {
		_ = writeln(int(hctl), "hangup")
		_ = libuser.close(int(hctl))
	}
	return hlen, status
}

writeln :: proc(fd: int, s: string) -> bool {
	return libuser.write(fd, transmute([]u8)s) == i64(len(s))
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


is_http :: proc "contextless" (s: string) -> bool {
	return libodin.has_prefix(s, "http://") || libodin.has_prefix(s, "https://")
}

// line_is says whether a header line names `name`, its case ignored.
line_is :: proc "contextless" (line: string, name: string) -> bool {
	if len(line) < len(name) + 1 || line[len(name)] != ':' {
		return false
	}
	for i in 0 ..< len(name) {
		c := line[i]
		if c >= 'A' && c <= 'Z' {
			c += 32
		}
		if c != name[i] {
			return false
		}
	}
	return true
}

