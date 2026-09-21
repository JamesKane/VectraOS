/*
mkfeed -- an Atom feed for a directory: `docs/WEB.md` section 9's "a
site is a feed the moment it exists". Each page in the directory becomes
an entry: its title the first `# ` heading of a `.md` file or the file
name, its link and id the base URL and the file's path, its updated the
time the feed is made. A person with `feedfs` follows the result as they
follow anything.

    mkfeed -b BASE [-t TITLE] DIR [out]

`BASE` is the site's URL, `DIR` the tree served, and `out` the file to
write, or standard output. A `.md` is linked as `.html`, the way `httpd`
serves it. Only the top of the directory is walked, so a feed is the
pages a person publishes and not the whole tree.
*/
package mkfeed

import "vsys:abi"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libuser"

say :: proc "contextless" (parts: ..string) {
	libuser.eprint(..parts)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	base := ""
	title := "A site"
	dir := ""
	out := ""
	for i := 1; i < len(args); i += 1 {
		if args[i] == "-b" && i + 1 < len(args) {
			base = args[i + 1]
			i += 1
		} else if args[i] == "-t" && i + 1 < len(args) {
			title = args[i + 1]
			i += 1
		} else if dir == "" {
			dir = args[i]
		} else if out == "" {
			out = args[i]
		}
	}
	if base == "" || dir == "" {
		say("usage: mkfeed -b BASE [-t TITLE] DIR [out]\n")
		libuser.exits("usage")
	}
	names, ok := libuser.read_dir(dir, context.allocator)
	if !ok {
		say("mkfeed: cannot read ", dir, "\n")
		libuser.exits("no dir")
	}
	libuser.sort_strings(names)
	now: [40]u8
	when_ := libmsg.format_3339(libmsg.now_seconds(), now[:])

	feed := make([dynamic]u8, 0, 4096)
	put(&feed, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\">\n  <title>")
	put_escaped(&feed, title)
	put(&feed, "</title>\n  <link href=\"")
	put_attr(&feed, base)
	put(&feed, "\" rel=\"alternate\"/>\n  <updated>")
	put(&feed, when_)
	put(&feed, "</updated>\n  <id>")
	put_attr(&feed, base)
	put(&feed, "</id>\n")

	entries := 0
	for name in names {
		if name == "." || name == ".." || !is_page(name) {
			continue
		}
		full: [512]u8
		path := libuser.cat_into(full[:], dir, "/", name)
		heading := page_title(path)
		link: [512]u8
		href := libuser.cat_into(link[:], base, "/", web_name(name))
		put(&feed, "  <entry>\n    <title>")
		put_escaped(&feed, heading == "" ? name : heading)
		put(&feed, "</title>\n    <link href=\"")
		put_attr(&feed, href)
		put(&feed, "\"/>\n    <id>")
		put_attr(&feed, href)
		put(&feed, "</id>\n    <updated>")
		put(&feed, when_)
		put(&feed, "</updated>\n  </entry>\n")
		entries += 1
	}
	put(&feed, "</feed>\n")

	if out == "" {
		_ = libuser.write_full(1, feed[:])
	} else {
		if old := libuser.open(out, abi.O_RDONLY); old >= 0 {
			_ = libuser.close(int(old))
			_ = libuser.remove(out)
		}
		fd := libuser.create(out, abi.O_WRONLY, 0o644)
		if fd < 0 {
			say("mkfeed: cannot write ", out, "\n")
			libuser.exits("no out")
		}
		_ = libuser.write_full(int(fd), feed[:])
		_ = libuser.close(int(fd))
	}
	libuser.exits("")
}

// page_title answers the first `# ` heading of a file, or "".
page_title :: proc(path: string) -> string {
	@(static) keep: [256]u8
	data, ok := libuser.read_file(path, context.allocator)
	if !ok {
		return ""
	}
	defer delete(data)
	s := string(data)
	at := 0
	for at < len(s) {
		e := at
		for e < len(s) && s[e] != '\n' {
			e += 1
		}
		line := s[at:e]
		if len(line) > 2 && line[0] == '#' && line[1] == ' ' {
			n := copy(keep[:], line[2:])
			return string(keep[:n])
		}
		at = e + 1
	}
	return ""
}

// is_page says whether a file name is a page a feed lists.
is_page :: proc "contextless" (name: string) -> bool {
	return has_suffix(name, ".md") || has_suffix(name, ".html") || has_suffix(name, ".htm") || has_suffix(name, ".gmi")
}

// web_name answers the name a page is linked as: a `.md` becomes `.html`.
web_name :: proc "contextless" (name: string) -> string {
	@(static) buf: [256]u8
	if has_suffix(name, ".md") {
		n := copy(buf[:], name[:len(name) - 3])
		n += copy(buf[n:], ".html")
		return string(buf[:n])
	}
	return name
}

put :: proc(out: ^[dynamic]u8, s: string) {
	append(out, ..transmute([]u8)s)
}

put_escaped :: proc(out: ^[dynamic]u8, s: string) {
	for c in transmute([]u8)s {
		switch c {
		case '<':
			put(out, "&lt;")
		case '>':
			put(out, "&gt;")
		case '&':
			put(out, "&amp;")
		case:
			append(out, c)
		}
	}
}

put_attr :: proc(out: ^[dynamic]u8, s: string) {
	for c in transmute([]u8)s {
		switch c {
		case '"':
			put(out, "&quot;")
		case '&':
			put(out, "&amp;")
		case:
			append(out, c)
		}
	}
}

has_suffix :: proc "contextless" (s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

_ :: libodin
