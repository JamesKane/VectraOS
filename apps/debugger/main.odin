/*
debugger -- the debugger's window, a `sys/libmui` client of `servers/dbgfs`.

    debugger path args...    run the program under the engine, stopped at
                             its entry, and open the window on it

`docs/DEVTOOLS.md` section 7: the window is one more client of the files
under `/mnt/dbg`, beside `cmd/db` and a script. Every panel is a file read
and shown as rows, and every button is a word written to the target's ctl.
The window holds layout and nothing else. Two windows on one target agree,
because the engine holds the target.

    status      one line, the target's `status` file
    source      the file the counter is in, the current line marked `>`
                and a breakpoint's line `*`, from `/lib/src`
    stack       `bt`         variables  `vars`       registers  `regs`
    dis         `dis`        breaks     `breaks`
    _Cont _Stop _Step _Next _Break _Quit

A key is the button's hotkey. A word that runs the target answers when it
stops. So a proc of the window's own writes it, and the panels refresh at
the answer, while the window still paints and takes a `Stop`. A click on
a source row selects it, and `Break` sets or clears a breakpoint there.

**First cut.** The engine is started here when `/srv/dbg` is not posted.
`Quit` detaches, which lets the program run on. The program's output is
the engine's, not a panel. Source comes from `/lib/src`, which the build
stages for the programs a debugger is expected on. A file not there shows
as one row saying so.
*/
package debugger

import "vsys:abi"
import "vsys:libdebug"
import "vsys:libmui"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"

ID_CONT :: 1
ID_STOP :: 2
ID_STEP :: 3
ID_NEXT :: 4
ID_BREAK :: 5
ID_QUIT :: 9
ID_SOURCE :: 20

MAX_ROWS :: 256
PANEL_BYTES :: 8192
MAX_SRC_LINES :: 4096
PATH_MAX :: 128

// A panel is one file of the target's, read whole and split into rows.
Panel :: struct {
	list: ^libmui.Object,
	file: string,
	buf:  [PANEL_BYTES]u8,
	rows: [MAX_ROWS]string,
	n:    int,
}

win: libmui.Window
target: [16]u8
target_len: int
status: ^libmui.Object
status_buf: [256]u8
source: ^libmui.Object
stack, vars, regs, dis, breaks: Panel

// The source panel: the file loaded, its lines as read, and the rows as
// shown. A row is a number, a mark and the text with tabs opened.
src_file: [PATH_MAX]u8
src_file_len: int
src_raw: []u8
src_fmt: []u8
src_rows: [MAX_SRC_LINES]string
src_n: int
src_missing: [PATH_MAX + 32]u8
break_lines: [64]int
break_n: int

dbg: libdebug.Debug
has_dbg: bool

// The word out with the target's proc, and the proc's channel.
Word :: struct {
	text: [64]u8,
	n:    int,
}

words: ^libthread.Chan
asked: Word
running: bool

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	if len(args) == 0 {
		libuser.eprint("usage: debugger path args...\n")
		libuser.exits("usage")
	}
	prog_args = args
	libthread.main(debugger_main, nil)
}

prog_args: []string

debugger_main :: proc "contextless" (arg: rawptr) {
	_ = arg
	argv := prog_args
	if !ensure_engine() {
		libthread.threadexitsall("no engine")
	}
	if !run_target(argv) {
		libthread.threadexitsall("run")
	}
	build_tree()
	win.handler = on_press
	if !libmui.window_open(&win, "Debugger", win.root) {
		libthread.threadexitsall("open")
	}
	words = libthread.chancreate(size_of(rawptr), 0)
	if words == nil || libthread.threadcreate(word_thread, nil) < 0 {
		libthread.threadexitsall("no thread")
	}
	refresh()
	libmui.window_run(&win)
	libthread.threadexits("")
}

// -- The engine ---------------------------------------------------------------

// ensure_engine mounts `/srv/dbg` at `/mnt/dbg`, starting `dbgfs` first
// when nothing is posted, and waiting for the post.
ensure_engine :: proc "contextless" () -> bool {
	if libuser.mount("/srv/dbg", "/mnt/dbg", abi.ORDER_REPLACE) >= 0 {
		return true
	}
	names := [?]string{"dbgfs"}
	if libuser.spawn("/bin/dbgfs", abi.SPAWN_NS_COPY, names[:]) < 0 {
		libuser.eprint("debugger: cannot start dbgfs\n")
		return false
	}
	for _ in 0 ..< 50 {
		if libuser.mount("/srv/dbg", "/mnt/dbg", abi.ORDER_REPLACE) >= 0 {
			return true
		}
		_ = libuser.sleep(100)
	}
	libuser.eprint("debugger: dbgfs never posted /srv/dbg\n")
	return false
}

// run_target asks the engine to run the program and keeps the target's
// number, which the read of ctl answers.
run_target :: proc "contextless" (argv: []string) -> bool {
	line: [512]u8
	sink := libodin.sink_from(line[:])
	libodin.put_str(&sink, "run")
	for a in argv {
		libodin.put_str(&sink, " ")
		libodin.put_str(&sink, a)
	}
	// Written and then read on a fresh open, as `db` does: a read on the
	// fid that wrote would start past the answer.
	if !write_root(libodin.str(&sink)) {
		libuser.eprint("debugger: the engine refused to run ", argv[0], "\n")
		return false
	}
	n := read_into("/mnt/dbg/ctl", target[:])
	if n <= 0 {
		libuser.eprint("debugger: the engine named no target\n")
		return false
	}
	target_len = int(n)
	for target_len > 0 && (target[target_len - 1] == '\n' || target[target_len - 1] == ' ') {
		target_len -= 1
	}
	load_debug(argv[0])
	return true
}

// load_debug opens the program's debug file, for the counter's source line.
load_debug :: proc "contextless" (path: string) {
	buf: [PATH_MAX]u8
	vxd := libuser.cat_into(buf[:], "/lib/debug/", libuser.basename(path), ".vxd")
	data := load_file(vxd)
	if data == nil {
		return
	}
	d, ok := libdebug.open(data)
	if !ok {
		libuser.heap_free(raw_data(data))
		return
	}
	dbg = d
	has_dbg = true
}

target_path :: proc "contextless" (buf: []u8, name: string) -> string {
	return libuser.cat_into(buf, "/mnt/dbg/", string(target[:target_len]), "/", name)
}

// -- The tree -------------------------------------------------------------------

build_tree :: proc "contextless" () {
	col := libmui.group(false)
	status = libmui.text("Starting")
	libmui.add(col, status)

	main_row := libmui.group(true)
	source = libmui.list(8)
	source.id = ID_SOURCE
	libmui.add(main_row, libmui.weigh(source, 3))
	side := libmui.group(false)
	libmui.add(side, libmui.text("Stack"))
	stack.list = libmui.list(3)
	stack.file = "bt"
	libmui.add(side, libmui.weigh(stack.list, 2))
	libmui.add(side, libmui.text("Variables"))
	vars.list = libmui.list(3)
	vars.file = "vars"
	libmui.add(side, libmui.weigh(vars.list, 3))
	libmui.add(side, libmui.text("Registers"))
	regs.list = libmui.list(3)
	regs.file = "regs"
	libmui.add(side, libmui.weigh(regs.list, 3))
	libmui.add(main_row, libmui.weigh(side, 2))
	libmui.add(col, libmui.weigh(main_row, 3))

	low := libmui.group(true)
	dis.list = libmui.list(6)
	dis.file = "dis"
	libmui.add(low, libmui.weigh(dis.list, 3))
	breaks.list = libmui.list(3)
	breaks.file = "breaks"
	libmui.add(low, libmui.weigh(breaks.list, 2))
	libmui.add(col, libmui.weigh(low, 2))

	row := libmui.group(true)
	libmui.add(row, id_button("_Cont", ID_CONT))
	libmui.add(row, id_button("St_op", ID_STOP))
	libmui.add(row, id_button("_Step", ID_STEP))
	libmui.add(row, id_button("_Next", ID_NEXT))
	libmui.add(row, id_button("_Break", ID_BREAK))
	libmui.add(row, id_button("_Quit", ID_QUIT))
	libmui.add(col, row)
	win.root = col
}

id_button :: proc "contextless" (label: string, id: int) -> ^libmui.Object {
	b := libmui.button(label)
	if b != nil {
		b.id = id
	}
	return b
}

// -- Presses --------------------------------------------------------------------

// on_press hears a gadget's id. A word that runs the target goes to the
// word proc, and a word that answers at once is written here. A source
// row press is the selection the list already made.
on_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	switch id {
	case ID_CONT:
		send_word("cont")
	case ID_STEP:
		send_word("step")
	case ID_NEXT:
		send_word("next")
	case ID_STOP:
		// The engine's `stop` answers at the stop, which comes soon. So
		// it is written here, and the word proc hears the stop of the
		// run it was out with.
		write_ctl("stop")
		if !running {
			refresh()
		}
	case ID_BREAK:
		toggle_break()
	case ID_QUIT, -1:
		write_root("detach ", string(target[:target_len]))
		w.done = true
	case ID_SOURCE:
	}
}

// send_word hands a blocking word to the word proc, unless one is out.
send_word :: proc "contextless" (word: string) {
	if running {
		return
	}
	running = true
	asked.n = copy(asked.text[:], word)
	set_status("Running")
	libmui.window_relayout(&win)
	libthread.sendp(words, &asked)
}

// word_thread writes each word through an io proc, which parks this
// thread alone until the target stops, and refreshes the panels then.
word_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		return
	}
	path: [64]u8
	for {
		w := (^Word)(libthread.recvp(words))
		fd := libuser.open(target_path(path[:], "ctl"), abi.O_WRONLY)
		if fd >= 0 {
			_ = libthread.iowrite(io, int(fd), w.text[:w.n])
			_ = libuser.close(int(fd))
		}
		running = false
		refresh()
	}
}

// write_ctl writes a word that answers at once to the target's ctl.
write_ctl :: proc "contextless" (parts: ..string) -> bool {
	path: [64]u8
	return write_line(target_path(path[:], "ctl"), ..parts)
}

write_root :: proc "contextless" (parts: ..string) -> bool {
	return write_line("/mnt/dbg/ctl", ..parts)
}

write_line :: proc "contextless" (path: string, parts: ..string) -> bool {
	line: [256]u8
	sink := libodin.sink_from(line[:])
	for p in parts {
		libodin.put_str(&sink, p)
	}
	fd := libuser.open(path, abi.O_WRONLY)
	if fd < 0 {
		return false
	}
	defer libuser.close(int(fd))
	return libuser.write_full(int(fd), transmute([]u8)libodin.str(&sink))
}

// toggle_break sets a breakpoint on the source panel's selected row, or
// deletes the one there.
toggle_break :: proc "contextless" () {
	if running || source.sel < 0 || src_file_len == 0 || src_raw == nil {
		return
	}
	line := source.sel + 1
	num: [24]u8
	for i in 0 ..< breaks.n {
		if k, ok := break_index_at(breaks.rows[i], line); ok {
			_ = write_ctl("delete ", libuser.itoa(num[:], i64(k)))
			refresh()
			return
		}
	}
	_ = write_ctl("break ", string(src_file[:src_file_len]), ":", libuser.itoa(num[:], i64(line)))
	refresh()
}

// break_index_at answers a breakpoint row's index when it sits on `line`
// of the loaded file. A row is `k 0xaddr in name at file:line hits n`.
break_index_at :: proc "contextless" (row: string, line: int) -> (int, bool) {
	fields: [12]string
	n := split_fields(row, fields[:])
	if n < 2 {
		return 0, false
	}
	k, kok := libuser.atoi(fields[0])
	if !kok {
		return 0, false
	}
	for i in 1 ..< n - 1 {
		if fields[i] != "at" {
			continue
		}
		place := fields[i + 1]
		colon := -1
		for j in 0 ..< len(place) {
			if place[j] == ':' {
				colon = j
			}
		}
		if colon < 0 {
			return 0, false
		}
		l, lok := libuser.atoi(place[colon + 1:])
		if lok && int(l) == line && place[:colon] == libuser.basename(string(src_file[:src_file_len])) {
			return int(k), true
		}
		return 0, false
	}
	return 0, false
}

// -- Refresh --------------------------------------------------------------------

// refresh reads every panel's file, places the source, and repaints.
refresh :: proc "contextless" () {
	path: [64]u8
	n := read_into(target_path(path[:], "status"), status_buf[:])
	text := trim(string(status_buf[:max(n, 0)]))
	set_status(len(text) > 0 ? text : "no status")
	read_panel(&stack)
	read_panel(&vars)
	read_panel(&regs)
	read_panel(&dis)
	read_panel(&breaks)
	place_source(text)
	libmui.window_relayout(&win)
}

// set_status keeps the line in its own buffer. A text already there is
// moved to the front, which `copy` does whole.
set_status :: proc "contextless" (text: string) {
	n := copy(status_buf[:], text)
	status.label = string(status_buf[:n])
}

read_panel :: proc "contextless" (p: ^Panel) {
	path: [64]u8
	n := read_into(target_path(path[:], p.file), p.buf[:])
	p.n = split_lines(string(p.buf[:max(n, 0)]), p.rows[:])
	p.list.rows = p.rows[:p.n]
	if p.list.top >= p.n {
		p.list.top = 0
	}
}

/*
place_source finds the file and line the counter is on, from the `pc=`
in the status line and the debug file. It loads the file when it is
another, marks the breakpoints' lines, and scrolls the panel to the
current line. A status with no counter, the program exited, leaves the
file up and nothing selected.
*/
place_source :: proc "contextless" (status_text: string) {
	source.sel = -1
	pc, pok := pc_of(status_text)
	if !pok || !has_dbg {
		format_source(-1)
		return
	}
	file, line, lok := libdebug.line_at(&dbg, pc)
	if !lok {
		format_source(-1)
		return
	}
	if file != string(src_file[:src_file_len]) {
		load_source(file)
	}
	format_source(int(line) - 1)
	if src_raw != nil {
		source.sel = int(line) - 1
		libmui.list_show(source, source.sel, &win.theme)
	}
}

// pc_of reads the counter out of a status line's `pc=0x...`.
pc_of :: proc "contextless" (text: string) -> (u64, bool) {
	for i in 0 ..< len(text) {
		if !has_prefix(text[i:], "pc=0x") {
			continue
		}
		end := i + 5
		for end < len(text) && text[end] != ' ' {
			end += 1
		}
		return parse_hex(text[i + 5:end])
	}
	return 0, false
}

// load_source reads `/lib/src/<file>` and splits it into lines.
load_source :: proc "contextless" (file: string) {
	if src_raw != nil {
		libuser.heap_free(raw_data(src_raw))
		src_raw = nil
	}
	if src_fmt != nil {
		libuser.heap_free(raw_data(src_fmt))
		src_fmt = nil
	}
	src_file_len = copy(src_file[:], file)
	src_n = 0
	src_raw = load_source_file(file)
	if src_raw == nil {
		return
	}
	// Room for every line's number and mark, and a tab opened to four.
	size := len(src_raw) * 4 + 8 * MAX_SRC_LINES + 64
	block := libuser.heap_alloc(size)
	if block == nil {
		libuser.heap_free(raw_data(src_raw))
		src_raw = nil
		return
	}
	src_fmt = ([^]u8)(block)[:size]
}

// load_source_file opens the file under `/lib/src`. A debug file names a
// file as the compiler saw it, which is the build machine's absolute path
// for some units. So the path is tried whole and then from each `/` in,
// which finds `tests/debuggee/main.odin` under whatever root built it.
load_source_file :: proc "contextless" (file: string) -> []u8 {
	path: [PATH_MAX * 2]u8
	if data := load_file(libuser.cat_into(path[:], "/lib/src/", file)); data != nil {
		return data
	}
	for i in 0 ..< len(file) {
		if file[i] != '/' || i + 1 >= len(file) {
			continue
		}
		if data := load_file(libuser.cat_into(path[:], "/lib/src/", file[i + 1:])); data != nil {
			return data
		}
	}
	return nil
}

// format_source writes the rows the panel shows: a line number, `>` on
// the current line, `*` on a breakpoint's, and the text.
format_source :: proc "contextless" (current: int) {
	gather_break_lines()
	if src_raw == nil {
		sink := libodin.sink_from(src_missing[:])
		if src_file_len == 0 {
			libodin.put_str(&sink, "no source: the program has no debug file")
		} else {
			libodin.put_str(&sink, "no source under /lib/src for ")
			libodin.put_str(&sink, libuser.basename(string(src_file[:src_file_len])))
		}
		src_rows[0] = libodin.str(&sink)
		src_n = 1
		source.rows = src_rows[:1]
		return
	}
	sink := libodin.sink_from(src_fmt)
	src_n = 0
	start := 0
	for i := 0; i <= len(src_raw) && src_n < MAX_SRC_LINES; i += 1 {
		if i < len(src_raw) && src_raw[i] != '\n' {
			continue
		}
		if i == len(src_raw) && start == i {
			break
		}
		row_start := len(libodin.str(&sink))
		put_padded(&sink, src_n + 1, 4)
		mark: u8 = ' '
		if src_n == current {
			mark = '>'
		} else if is_break_line(src_n + 1) {
			mark = '*'
		}
		libodin.put_byte(&sink, mark)
		libodin.put_byte(&sink, ' ')
		for j in start ..< i {
			if src_raw[j] == '\t' {
				libodin.put_str(&sink, "    ")
			} else if src_raw[j] != '\r' {
				libodin.put_byte(&sink, src_raw[j])
			}
		}
		src_rows[src_n] = libodin.str(&sink)[row_start:]
		src_n += 1
		start = i + 1
	}
	source.rows = src_rows[:src_n]
}

put_padded :: proc "contextless" (sink: ^libodin.Sink, v: int, width: int) {
	num: [24]u8
	s := libuser.itoa(num[:], i64(v))
	for _ in len(s) ..< width {
		libodin.put_byte(sink, ' ')
	}
	libodin.put_str(sink, s)
}

// gather_break_lines lists the lines of the loaded file that carry a
// breakpoint, from the breaks panel.
gather_break_lines :: proc "contextless" () {
	break_n = 0
	if src_file_len == 0 {
		return
	}
	for i in 0 ..< breaks.n {
		if break_n >= len(break_lines) {
			break
		}
		if line, ok := break_line_of(breaks.rows[i]); ok {
			break_lines[break_n] = line
			break_n += 1
		}
	}
}

break_line_of :: proc "contextless" (row: string) -> (int, bool) {
	fields: [12]string
	n := split_fields(row, fields[:])
	for i in 1 ..< n - 1 {
		if fields[i] != "at" {
			continue
		}
		place := fields[i + 1]
		colon := -1
		for j in 0 ..< len(place) {
			if place[j] == ':' {
				colon = j
			}
		}
		if colon < 0 || place[:colon] != libuser.basename(string(src_file[:src_file_len])) {
			return 0, false
		}
		l, lok := libuser.atoi(place[colon + 1:])
		return int(l), lok
	}
	return 0, false
}

is_break_line :: proc "contextless" (line: int) -> bool {
	for i in 0 ..< break_n {
		if break_lines[i] == line {
			return true
		}
	}
	return false
}

// -- Files and text -------------------------------------------------------------

read_into :: proc "contextless" (path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	defer libuser.close(int(fd))
	at := 0
	for at < len(into) {
		n := libuser.read(int(fd), into[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	return at
}

load_file :: proc "contextless" (path: string) -> []u8 {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return nil
	}
	defer libuser.close(int(fd))
	st: abi.Stat
	if libuser.fstat(int(fd), &st) != 0 || st.length == 0 || st.length > 8 << 20 {
		return nil
	}
	size := int(st.length)
	block := libuser.heap_alloc(size)
	if block == nil {
		return nil
	}
	data := ([^]u8)(block)[:size]
	at := 0
	for at < size {
		n := libuser.read(int(fd), data[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	if at != size {
		libuser.heap_free(block)
		return nil
	}
	return data
}

split_lines :: proc "contextless" (text: string, out: []string) -> int {
	n := 0
	start := 0
	for i in 0 ..< len(text) {
		if text[i] != '\n' {
			continue
		}
		if n >= len(out) {
			return n
		}
		out[n] = text[start:i]
		n += 1
		start = i + 1
	}
	if start < len(text) && n < len(out) {
		out[n] = text[start:]
		n += 1
	}
	return n
}

split_fields :: proc "contextless" (s: string, out: []string) -> int {
	n := 0
	i := 0
	for i < len(s) && n < len(out) {
		for i < len(s) && s[i] == ' ' {
			i += 1
		}
		if i >= len(s) {
			break
		}
		start := i
		for i < len(s) && s[i] != ' ' {
			i += 1
		}
		out[n] = s[start:i]
		n += 1
	}
	return n
}

trim :: proc "contextless" (s: string) -> string {
	end := len(s)
	for end > 0 && (s[end - 1] == '\n' || s[end - 1] == ' ' || s[end - 1] == '\r') {
		end -= 1
	}
	return s[:end]
}

has_prefix :: proc "contextless" (s, p: string) -> bool {
	return len(s) >= len(p) && s[:len(p)] == p
}

parse_hex :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	for c in transmute([]u8)s {
		d: u64
		switch {
		case c >= '0' && c <= '9': d = u64(c - '0')
		case c >= 'a' && c <= 'f': d = u64(c - 'a' + 10)
		case c >= 'A' && c <= 'F': d = u64(c - 'A' + 10)
		case:
			return 0, false
		}
		v = v << 4 | d
	}
	return v, true
}
