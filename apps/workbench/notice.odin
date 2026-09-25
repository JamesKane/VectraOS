/*
notice -- a line written to a file, `docs/WORKBENCH.md` section 6.

Workbench serves `/srv/wb`, posted before its first window opens so a
boot script finds it at once, and mounted at `/mnt/wb` by the desktop
itself, so every shell it opens can write one, and by `init`, for the
console's:

    notice     a write posts one: `source text[\tverb args]`. A read is the
               latest.
    history    the last ten, one per line, newest last.
    ctl        `quiet` and `loud`, and the verbs a notice's action may be:
               `open`, `run`, `ask`, `workspace`, each with the rest of the
               line as its argument. `recycle PATH` is `Delete...` on a
               path, and `empty` empties the Recycler, `recycler.odin`.
               `columns PATH` opens a drawer as columns.
    view       the drawer in front and how it is seen: its columns, a
               union's members, and the server behind it, `columns.odin`.

A notice draws as a toast below the bar's right corner for five seconds,
in a popup the machine's frame around it, and a click on it runs the
action. The action is a verb Workbench's own `ctl` knows and never a
shell string; the notice's text is never in it. Two notices with one
source and one text in a row are one notice with a count. Under `quiet`
nothing is drawn and the history still keeps them.

The plan drew `notice` as both a file and a directory. A file cannot be
both, so `history` and `ctl` sit beside it.
*/
package workbench

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

HISTORY :: 10
NOTICE_MAX :: 200
TOAST_MS :: 5000

Notice :: struct {
	text:   [NOTICE_MAX]u8,
	n:      int,
	action: [NOTICE_MAX]u8,
	an:     int,
	count:  int,
}

history: [HISTORY]Notice
history_n: int // How many are held, up to HISTORY; the newest is the last
quiet: bool

toast: ^libmui.Window
toast_seq: int // Counts toasts, so the sleeper closes only its own
toast_io: ^libthread.Ioproc // The sleeper's wait, off the proc's own thread

// The toast thread owns window creation. A notice arriving on the served
// tree's thread cannot open a window there -- that thread is inside the 9P
// serve loop -- so it records the notice and pokes this channel, and the
// toast thread opens the popup. `pending` is the notice to draw next.
toast_wake: ^libthread.Chan
pending: ^Notice

NODE_ROOT :: i32(0)
NODE_NOTICE :: i32(1)
NODE_HISTORY :: i32(2)
NODE_CTL :: i32(3)
NODE_VIEW :: i32(4)

fids: libuser.Fid_Table
srv: lib9p.Srv
FRAME :: 2048

// The served end of /srv/wb, posted by `notice_post` before any window
// opens, and read by `notice_thread`. Negative when the post failed.
notice_fd: int = -1

// notice_post posts /srv/wb. Called from `wb_main` first thing, so `init`
// finds the name posted as soon as the program is running rather than
// after the windows have painted. A failure is said and survived: the
// desktop works without notices.
notice_post :: proc "contextless" () {
	fd, perr := libuser.post("/srv/wb")
	if perr < 0 {
		tmp: [24]u8
		libuser.eprint("workbench: post /srv/wb failed: ")
		libuser.eprint(libuser.itoa(tmp[:], perr))
		libuser.eprint("\n")
		return
	}
	notice_fd = fd
}

// mount_thread mounts /srv/wb at /mnt/wb in the desktop's own namespace,
// which every shell it opens inherits. Through an io proc, because the
// server the mount waits on is `notice_thread`, a thread of this proc.
mount_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	if notice_fd >= 0 {
		if io := libthread.ioproc(); io != nil {
			_ = libthread.iomount(io, "/srv/wb", "/mnt/wb", abi.ORDER_REPLACE)
			libthread.ioclose(io)
		}
	}
	// The handshake is over, whichever way it went: the desktop may open its
	// windows now. See `main`.
	if notice_mounted != nil {
		libthread.sendul(notice_mounted, 1)
	}
	libthread.threadexits("")
}

// Told once the notice service's mount is done, for `main`.
notice_mounted: ^libthread.Chan

// notice_thread serves /srv/wb for as long as it is mounted.
notice_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	if notice_fd < 0 {
		libthread.threadexits("post")
	}
	srv = lib9p.Srv {
		fd      = notice_fd,
		handler = notice_handler,
		msize   = FRAME,
	}
	_, _ = lib9p.serve(&srv)
	lib9p.respond_all(&srv, vectra9.error_reply(vectra9.EIO))
	libthread.threadexits("")
}

/*
post_notice takes one: the source, the text, and the action, which may be
empty. A repeat of the last one counts rather than adds. Then the toast,
unless quiet.
*/
post_notice :: proc "contextless" (source: string, text: string, action: string) {
	if history_n > 0 {
		last := &history[history_n - 1]
		if same_notice(last, source, text) {
			last.count += 1
			wake_toast(last)
			return
		}
	}
	if history_n == HISTORY {
		for i in 1 ..< HISTORY {
			history[i - 1] = history[i]
		}
		history_n -= 1
	}
	n := &history[history_n]
	history_n += 1
	n.n = copy(n.text[:], source)
	n.n += copy(n.text[n.n:], "\t")
	n.n += copy(n.text[n.n:], text)
	n.an = copy(n.action[:], action)
	n.count = 1
	status_set(text)
	wake_toast(n)
}

// wake_toast points the toast thread at a notice and pokes it. A poke that
// finds the channel full is dropped: a toast is already on its way.
wake_toast :: proc "contextless" (n: ^Notice) {
	if quiet {
		return
	}
	pending = n
	if toast_wake != nil {
		_ = libthread.nbsendp(toast_wake, rawptr(n))
	}
}

// toast_thread is the one that opens toast windows, so the serve thread
// never does. It waits for a poke, then draws whatever notice is pending.
toast_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = wb_ctx
	toast_wake = libthread.chancreate(size_of(rawptr), 4)
	if toast_wake == nil {
		libthread.threadexits("")
	}
	for {
		_ = libthread.recvp(toast_wake)
		if pending != nil {
			show_toast(pending)
		}
	}
}

same_notice :: proc "contextless" (n: ^Notice, source: string, text: string) -> bool {
	want := len(source) + 1 + len(text)
	if n.n != want {
		return false
	}
	return string(n.text[:len(source)]) == source && string(n.text[len(source) + 1:n.n]) == text
}

// show_toast opens the popup below the bar's right corner, or repaints the
// one that is up, and starts the sleeper that takes it down.
show_toast :: proc "contextless" (n: ^Notice) {
	context = wb_ctx
	if quiet {
		return
	}
	// A record of its own per toast, freed by the thread that runs it. The
	// toast before it, if still up, is asked to go and goes on its own
	// time; a record reused under a window's running threads is what
	// wedged the second toast once.
	if toast != nil && !toast.done {
		libmui.window_end(toast)
	}
	t := new(libmui.Window)
	if t == nil {
		return
	}
	line: [NOTICE_MAX + 24]u8
	at := copy(line[:], toast_text(n))
	if n.count > 1 {
		tmp: [24]u8
		at += copy(line[at:], " (x")
		at += copy(line[at:], libuser.itoa(tmp[:], i64(n.count)))
		at += copy(line[at:], ")")
	}
	b := libmui.button(clone_string(string(line[:at])))
	b.id = 1
	col := libmui.group(false)
	libmui.add(col, b)
	theme := libmui.default_theme
	libmui.fit(col, &theme)
	t.kind = .Popup
	t.bind_dev = false
	t.own_exit = false
	t.set_up = true
	t.placed = true
	t.want_w, t.want_h = col.minw, col.minh
	// Left of the dock, when there is one.
	t.at_x = max(screen_w - (has_tiles() ? TILES_W : 0) - col.minw - 8, 0)
	t.at_y = BAR_H + 4
	t.handler = toast_press
	t.user = rawptr(n)
	if !libmui.window_open(t, "notice", col) {
		free(t)
		return
	}
	toast = t
	toast_seq += 1
	_ = libthread.threadcreate(toast_window_thread, t)
	_ = libthread.threadcreate(toast_sleeper, rawptr(uintptr(toast_seq)))
}

// toast_window_thread runs one toast's window and frees its record after,
// which is when no thread of the window is left to touch it.
toast_window_thread :: proc "contextless" (arg: rawptr) {
	context = wb_ctx
	w := (^libmui.Window)(arg)
	libmui.window_run(w)
	if toast == w {
		toast = nil
	}
	free(w)
	libthread.threadexits("")
}

// toast_text is what the toast says: the text, without the source.
toast_text :: proc "contextless" (n: ^Notice) -> string {
	i := 0
	for i < n.n && n.text[i] != '\t' {
		i += 1
	}
	if i < n.n {
		i += 1
	}
	return string(n.text[i:n.n])
}

// toast_press: a click runs the action, and the toast goes.
toast_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	n := (^Notice)(w.user)
	w.done = true
	if id == 1 && n != nil && n.an > 0 {
		run_action(string(n.action[:n.an]))
	}
}

// toast_sleeper takes the toast down after its five seconds, if it is still
// the one it was started for.
toast_sleeper :: proc "contextless" (arg: rawptr) {
	seq := int(uintptr(arg))
	if toast_io == nil {
		toast_io = libthread.ioproc()
	}
	if toast_io == nil {
		libthread.threadexits("")
	}
	_ = libthread.iosleep(toast_io, TOAST_MS)
	if toast != nil && toast_seq == seq && !toast.done {
		libmui.window_end(toast)
	}
	libthread.threadexits("")
}

// -- The served tree ---------------------------------------------------------------

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if node == NODE_ROOT {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

name_of :: proc "contextless" (node: i32) -> string {
	switch node {
	case NODE_NOTICE:
		return "notice"
	case NODE_HISTORY:
		return "history"
	case NODE_CTL:
		return "ctl"
	case NODE_VIEW:
		return "view"
	}
	return ""
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	switch name {
	case ".":
		return from
	case "..":
		return NODE_ROOT
	}
	if from != NODE_ROOT {
		return -1
	}
	switch name {
	case "notice":
		return NODE_NOTICE
	case "history":
		return NODE_HISTORY
	case "ctl":
		return NODE_CTL
	case "view":
		return NODE_VIEW
	}
	return -1
}

notice_handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state
	_ = s
	_ = tag
	if !libuser.default_reply(request, reply) {
		return
	}
	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)
	case vectra9.Tattach:
		libuser.attach(&fids, m, reply, NODE_ROOT, qid_of)
	case vectra9.Twalk:
		libuser.walk(&fids, m, reply, step, qid_of)
	case vectra9.Tlopen:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		libuser.fid_open(&fids, m.fid)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}
	case vectra9.Tread:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		room := min(len(buf), int(m.count))
		text: [HISTORY * (NOTICE_MAX + 2)]u8
		n := 0
		switch node {
		case NODE_NOTICE:
			if history_n > 0 {
				n = notice_line(text[:], 0, &history[history_n - 1])
			}
		case NODE_HISTORY:
			for i in 0 ..< history_n {
				n = notice_line(text[:], n, &history[i])
			}
		case NODE_CTL:
			n = copy(text[:], quiet ? "quiet\n" : "loud\n")
		case NODE_VIEW:
			n = view_report(text[:])
		case:
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		if m.offset >= u64(n) {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		take := min(room, n - int(m.offset))
		copy(buf[:take], text[int(m.offset):int(m.offset) + take])
		reply^ = vectra9.Rread{data = buf[:take]}
	case vectra9.Twrite:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		line := string(m.data)
		if len(line) > 0 && line[len(line) - 1] == '\n' {
			line = line[:len(line) - 1]
		}
		switch node {
		case NODE_NOTICE:
			source, rest := first_word(line)
			if source == "" {
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
			text := rest
			action := ""
			if tab := index_byte(rest, '\t'); tab >= 0 {
				text = rest[:tab]
				action = rest[tab + 1:]
			}
			post_notice(source, text, action)
		case NODE_CTL:
			switch line {
			case "quiet":
				quiet = true
			case "loud":
				quiet = false
			case:
				verb, _ := first_word(line)
				switch verb {
				case "open", "run", "ask", "workspace", "execute", "shell", "recycle", "empty", "columns":
					run_action(line)
				case:
					reply^ = vectra9.error_reply(vectra9.EINVAL)
					return
				}
			}
		case:
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}
	case vectra9.Treaddir:
		readdir(m, reply, buf)
	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := node == NODE_ROOT
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100666,
			nlink   = dir ? 2 : 1,
			size    = 0,
			blksize = 512,
		}
	case vectra9.Tclunk:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rclunk{}
	case vectra9.Tremove:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}
	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

// notice_line writes one notice as a line: `source<tab>text[<tab>action] xN`.
notice_line :: proc "contextless" (out: []u8, at: int, n: ^Notice) -> int {
	k := at
	k += copy(out[k:], string(n.text[:n.n]))
	if n.an > 0 {
		k += copy(out[k:], "\t")
		k += copy(out[k:], string(n.action[:n.an]))
	}
	if n.count > 1 {
		tmp: [24]u8
		k += copy(out[k:], " x")
		k += copy(out[k:], libuser.itoa(tmp[:], i64(n.count)))
	}
	k += copy(out[k:], "\n")
	return k
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	if node != NODE_ROOT {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	for child := i32(m.offset) + 1; child <= NODE_VIEW; child += 1 {
		if vectra9.remaining(&c) < vectra9.dirent_size(name_of(child)) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent{qid = qid_of(child), offset = u64(child), type = vectra9.DT_REG, name = name_of(child)},
		)
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
