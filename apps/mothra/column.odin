/*
The column: what points at the page. `docs/WEB.md` section 5.

The window is two panes, the page on the left and its column on the
right. For a message the column is what it answers, its replies, and the
`notify/` messages of its network that answer it. For a page it is the
backlinks: the reader keeps `$home/lib/web/links`, one line per link it
laid out, the page it was on and the page it names, and read backwards
that is what pointed here. A press in the column opens on the left, and
the column follows.
*/
package mothra

import "vsys:abi"
import "vsys:libdoc"
import "vsys:libmsg"
import "vsys:libmui"
import "vsys:libodin"
import "vsys:libuser"

MAX_COL :: 128
COL_HREF :: 512
LINKS_MAX :: 1024 * 1024

col: ^libmui.Object
col_rows: []string
col_styles: []u8
col_hrefs: [MAX_COL][COL_HREF]u8
col_href_len: [MAX_COL]int
col_text: [MAX_COL][ROW_MAX]u8
col_n: int

// fill_column rebuilds the column for the current page.
fill_column :: proc() {
	col_n = 0
	cur := string(current[:current_len])
	if in_place && libmsg.is_message(cur) {
		column_of_message(cur)
	} else if !in_place {
		column_of_page(cur)
	}
	col.rows = col_rows[:col_n]
	col.styles = col_styles[:col_n]
	col.top = 0
	col.sel = -1
}

@(private = "file")
col_add :: proc(text: string, href: string, style: u8) {
	if col_n >= MAX_COL {
		return
	}
	n := copy(col_text[col_n][:], text)
	col_rows[col_n] = string(col_text[col_n][:n])
	col_href_len[col_n] = copy(col_hrefs[col_n][:], href)
	col_styles[col_n] = style
	col_n += 1
}

@(private = "file")
col_add_msg :: proc(dir: string, m: ^libmsg.Msg) {
	line: [ROW_MAX]u8
	when_: [16]u8
	text := libuser.cat_into(line[:], libmsg.format_time(m.date, when_[:]), "  ", m.from, ": ", libmsg.first_line(m))
	path: [ROW_MAX]u8
	col_add(text, libuser.cat_into(path[:], dir, "/", m.id), libmui.STYLE_LINK)
}

@(private = "file")
column_of_message :: proc(dir: string) {
	m, ok := libmsg.read_msg(dir)
	if !ok {
		return
	}
	defer libmsg.msg_free(&m)
	parent := parent_of(dir)
	path: [ROW_MAX]u8
	if len(m.replyto) > 0 {
		col_add("In reply to", "", libmui.STYLE_HEADING)
		if p, pok := libmsg.read_msg(libuser.cat_into(path[:], parent, "/", m.replyto)); pok {
			col_add_msg(parent, &p)
			libmsg.msg_free(&p)
		} else {
			col_add(m.replyto, libuser.cat_into(path[:], parent, "/", m.replyto), libmui.STYLE_LINK)
		}
	}
	replies_dir := libuser.cat_into(path[:], dir, "/replies")
	if replies, has := libmsg.read_conv(replies_dir); has {
		if len(replies) > 0 {
			col_add("Replies", "", libmui.STYLE_HEADING)
			for &r in replies {
				col_add_msg(replies_dir, &r)
			}
		}
		libmsg.rows_free(replies)
	}
	// The network's notify conversation: what came back that answers this.
	notify_buf: [ROW_MAX]u8
	notify := libuser.cat_into(notify_buf[:], parent_of(parent), "/notify")
	if libmsg.path_is_dir(notify) {
		if notes, has := libmsg.read_conv(notify); has {
			added := false
			for &n in notes {
				if n.replyto != m.id {
					continue
				}
				if !added {
					col_add("Notify", "", libmui.STYLE_HEADING)
					added = true
				}
				col_add_msg(notify, &n)
			}
			libmsg.rows_free(notes)
		}
	}
}

// column_of_page reads the links index backwards: every page that names
// this one is a backlink.
@(private = "file")
column_of_page :: proc(cur: string) {
	text, ok := libuser.read_file(links_path(), context.allocator)
	if !ok {
		return
	}
	defer delete(text)
	at := 0
	added := false
	for at < len(text) {
		end := at
		for end < len(text) && text[end] != '\n' {
			end += 1
		}
		line := string(text[at:end])
		at = end + 1
		sp := -1
		for i in 0 ..< len(line) {
			if line[i] == ' ' {
				sp = i
				break
			}
		}
		if sp < 0 || line[sp + 1:] != cur || line[:sp] == cur {
			continue
		}
		if !added {
			col_add("Backlinks", "", libmui.STYLE_HEADING)
			added = true
		}
		col_add(line[:sp], line[:sp], libmui.STYLE_LINK)
	}
}

// column_press opens the column's row on the left.
column_press :: proc(row: int) {
	if row < 0 || row >= col_n || col_href_len[row] == 0 {
		return
	}
	target: [COL_HREF]u8
	n := copy(target[:], col_hrefs[row][:col_href_len[row]])
	go(string(target[:n]), true)
}

/*
record_links keeps the page's links: one line per link block, the page it
is on and the page it names, appended to the index unless the index has
that line already. The index is the store's, beside `names`.
*/
record_links :: proc() {
	cur := string(current[:current_len])
	have, _ := libuser.read_file(links_path(), context.allocator)
	defer delete(have)
	if len(have) > LINKS_MAX {
		return
	}
	fd := libuser.open(links_path(), abi.O_WRONLY)
	if fd < 0 {
		ensure_store()
		fd = libuser.create(links_path(), abi.O_WRONLY, 0o644)
		if fd < 0 {
			return
		}
	}
	defer _ = libuser.close(int(fd))
	st: abi.Stat
	at: u64 = 0
	if libuser.fstat(int(fd), &st) >= 0 {
		at = st.length
	}
	target: [URL_MAX]u8
	line: [2 * URL_MAX + 2]u8
	for b in 0 ..< len(doc.blocks) {
		if doc.blocks[b].kind != .Link {
			continue
		}
		n := resolve(libdoc.block_href(&doc, b), target[:])
		if n <= 0 {
			continue
		}
		text := libuser.cat_into(line[:], cur, " ", string(target[:n]), "\n")
		if libodin.contains(string(have), text) {
			continue
		}
		wrote := libuser.pwrite(int(fd), transmute([]u8)text, at)
		if wrote != i64(len(text)) {
			return
		}
		at += u64(len(text))
	}
}

@(private = "file")
links_buf: [256]u8

@(private = "file")
links_path :: proc "contextless" () -> string {
	home_buf: [128]u8
	home := libuser.getenv("home", home_buf[:])
	if home == "" {
		home = "/usr/glenda"
	}
	return libuser.cat_into(links_buf[:], home, "/lib/web/links")
}

@(private = "file")
ensure_store :: proc "contextless" () {
	p := links_path()
	// The directory above the file, and the one above that.
	for cut := len(p) - 1; cut > 0; cut -= 1 {
		if p[cut] == '/' {
			dir := p[:cut]
			for c2 := len(dir) - 1; c2 > 0; c2 -= 1 {
				if dir[c2] == '/' {
					_ = libuser.mkdir(dir[:c2])
					break
				}
			}
			_ = libuser.mkdir(dir)
			break
		}
	}
}

parent_of :: proc "contextless" (path: string) -> string {
	for i := len(path) - 1; i > 0; i -= 1 {
		if path[i] == '/' {
			return path[:i]
		}
	}
	return path
}
