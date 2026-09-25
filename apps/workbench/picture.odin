/*
picture -- the icon a path wears, `docs/CHROME.md` section 6.

An icon is a kind a `stat` can answer, `docs/WORKBENCH.md` section 6, with
the namespace as a second witness. This file names the icon for each path.
`sys/libmui` draws it when the theme names icons, and the kind's picture
when it does not.

    home      $home
    recycler  $home/lib/wb/recycler, where Delete... puts a file
    union     a directory with more than one member in the namespace
    remote    a directory mounted from a /srv name that is an ndb machine,
              which `import` posts
    served    a directory mounted from any other /srv name
    folder    any other directory
    srv       a name in /srv
    ctl       a file named ctl
    scheme    a file in /lib/themes or $home/lib/themes
    <name>    a tool: its own icon when there is a file of its name,
              else the kind's, `tool`
    file      anything else

The namespace is this program's own, `/proc/N/ns`, read again each time a
drawer reads its directory, so a bind made at a shell shows the next time.
*/
package workbench

import "vsys:libmui"
import "vsys:libuser"

MAX_NS_LINES :: 128

// One mount point of the namespace: its path, how many members it has, and
// its first member, which says what is mounted there.
Ns_Point :: struct {
	target:  string,
	members: int,
	source:  string,
	mounted: bool,
	// Each member's source, in bind order, the first four.
	sources: [4]string,
}

ns_text: []u8
ns_points: [MAX_NS_LINES]Ns_Point
ns_n: int

/*
ns_read reads this program's namespace into `ns_points`. A line is `bind` or
`mount`, `-a` and other flags for a member after the first, then the source
and the target. A member after the first adds to its mount point.
*/
ns_read :: proc "contextless" () {
	context = wb_ctx
	delete(ns_text)
	ns_text = nil
	ns_n = 0
	nb: [24]u8
	pb: [48]u8
	text, ok := libuser.read_file(libuser.cat_into(pb[:], "/proc/", libuser.itoa(nb[:], i64(libuser.getpid())), "/ns"), context.allocator)
	if !ok {
		return
	}
	ns_text = text
	i := 0
	s := string(text)
	for i < len(s) {
		start := i
		for i < len(s) && s[i] != '\n' {
			i += 1
		}
		line := s[start:i]
		i += 1
		verb, rest := libmui.word(line)
		if verb != "bind" && verb != "mount" {
			continue
		}
		words: [6]string
		n := 0
		for n < len(words) {
			w: string
			w, rest = libmui.word(rest)
			if w == "" {
				break
			}
			words[n] = w
			n += 1
		}
		if n < 2 {
			continue
		}
		source, target := words[n - 2], words[n - 1]
		if p := ns_find(target); p != nil {
			if p.members < len(p.sources) {
				p.sources[p.members] = source
			}
			p.members += 1
			continue
		}
		if ns_n < MAX_NS_LINES {
			ns_points[ns_n] = Ns_Point{target = target, members = 1, source = source, mounted = verb == "mount"}
			ns_points[ns_n].sources[0] = source
			ns_n += 1
		}
	}
}

ns_find :: proc "contextless" (target: string) -> ^Ns_Point {
	for k in 0 ..< ns_n {
		if ns_points[k].target == target {
			return &ns_points[k]
		}
	}
	return nil
}

/*
server_of is what serves a path. It is the source of the mount point that
covers it most closely: `/srv/kfs`, `#c`, or `import one` for a machine's. A path no
mount point covers is the root's, `/`.
*/
server_of :: proc "contextless" (path: string) -> string {
	best := -1
	for k in 0 ..< ns_n {
		t := ns_points[k].target
		covers := path == t || t == "/" || (has_prefix(path, t) && len(path) > len(t) && path[len(t)] == '/')
		if covers && (best < 0 || len(t) > len(ns_points[best].target)) {
			best = k
		}
	}
	if best < 0 {
		return "/"
	}
	p := &ns_points[best]
	if p.mounted && has_prefix(p.source, "/srv/") && is_machine(p.source[5:]) {
		@(static) buf: [96]u8
		n := copy(buf[:], "import ")
		n += copy(buf[n:], p.source[5:])
		return string(buf[:n])
	}
	return p.source
}

// is_machine answers whether ndb names a machine `name`, which is what
// `import` posts in /srv.
is_machine :: proc "contextless" (name: string) -> bool {
	context = wb_ctx
	buf: [64]u8
	_, ok := libuser.ndb_attr(name, "sys", buf[:])
	return ok
}

// picture_of is the icon for a path of a kind, by the table above. `name`
// is the path's last element.
picture_of :: proc "contextless" (path: string, name: string, kind: u8) -> string {
	if path == home_path() {
		return "home"
	}
	if path == recycler_path() {
		return "recycler"
	}
	if kind == libmui.ICON_DRAWER {
		if p := ns_find(path); p != nil {
			if p.members > 1 {
				return "union"
			}
			if p.mounted && has_prefix(p.source, "/srv/") {
				return is_machine(p.source[5:]) ? "remote" : "served"
			}
		}
		return "folder"
	}
	if has_prefix(path, "/srv/") {
		return "srv"
	}
	if name == "ctl" {
		return "ctl"
	}
	hb: [160]u8
	if has_prefix(path, "/lib/themes/") || has_prefix(path, libuser.cat_into(hb[:], home_path(), "/lib/themes/")) {
		return "scheme"
	}
	if kind == libmui.ICON_TOOL {
		return name
	}
	return "file"
}

has_prefix :: proc "contextless" (s: string, prefix: string) -> bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}
