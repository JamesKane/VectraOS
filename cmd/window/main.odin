/*
window -- run a command in a window, `rio`'s `window`.

`rio`'s `window` opens a window and runs a command in it, and the window
is the command's console. This is that. It claims a window, uploads the
font, and starts the command named on its own line, with two pipes for
the command's three descriptors. From then on it is two things at once:
the glass the command's output lands on, and the keyboard its input
comes from. `apps/terminal` was this with `/bin/rc` hard-coded, and
`docs/WORKBENCH.md` step 3 is where it became the general one.

The command is this program's own arguments. `window /bin/rc -i` runs
`rc -i`, and `window` with none runs `/bin/rc`. The first argument is the
path, and the whole list is the command's own argv. A bare name is
resolved in `/bin`, which is what a person types.

## Two pipes, two procs, one drawer

    rc's descriptor 0   the read end of a pipe this program writes finished
                        lines into
    rc's descriptors 1 and 2
                        the write end of a pipe this program reads and draws

Reading the shell's output and reading the window's keyboard both park, and
a proc cannot wait on two things. So this program is `sys/libthread`'s
shape: a thread per thing that parks, each reading through an io proc of
its own, in one proc. The drawer, the first thread, reads the shell's pipe
and puts what arrives into the grid. The typist reads the window's `cons`
raw, puts each key into the line `libedit` is editing, and hands a
finished line to the shell. Either way the glass is redrawn. Nothing here
is locked: both threads are one proc's, and a thread runs until it waits.

The drawer owns the ending. When the output pipe reaches its end the shell
is gone -- a typed `exit`, or a fault -- and `threadexitsall` takes the io
procs down and exits, which closes the window.

## The glass

The client area is a grid of cells, as many columns of eight pixels and
rows of sixteen as fit, with a cursor that the shell's output moves:
newline, return, backspace and tab mean what a terminal means by them, and
a line past the last row scrolls the rest up. The line being typed is drawn
at the cursor, over the row the shell last wrote on, with an underline
caret where the next character goes -- which is how a person sees the line
while it is still a line, since the draw server draws nothing and the shell
has not been given the characters yet.

The rendering is `docs/DRAW.md`'s economics: the font uploaded once as six
strip images, and every character after that a 36-byte blit. A row is
redrawn when it changes and a scroll redraws them all, which is what this
has instead of a scroll verb.
*/
package window

import "base:runtime"

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libedit"
import "vsys:libfont"
import "vsys:libpal"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

FG :: u32(libpal.AMBER[0]) << 16 | u32(libpal.AMBER[1]) << 8 | u32(libpal.AMBER[2])
BG :: u32(libpal.SLATE[0]) << 16 | u32(libpal.SLATE[1]) << 8 | u32(libpal.SLATE[2])

// The atlas: strips of sixteen 8x16 cells from image id 1 up, holding ASCII
// and the ranges `/lib/font` names past it. `libdraw.bake_atlas` fills it and
// uploads the strips in amber over slate, once, so its ranges are not known
// until then -- a var, not a constant like it was when the font stopped at
// ASCII.
atlas: libdraw.Atlas

// text_font is the font past ASCII, opened once from `/lib/font`. A failure
// is not fatal: `bake_atlas` bakes ASCII from the baked table alone.
text_font: libfont.Loader

// font_read is the loader's I/O, and font_write the bake's sink -- the
// window's own `data` stream, which `send` writes to.
font_read :: proc "contextless" (data: rawptr, path: string, into: []u8) -> int {
	_ = data
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	at := 0
	for at < len(into) {
		n := libuser.read(int(fd), into[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	_ = libuser.close(int(fd))
	return at
}

font_write :: proc "contextless" (user: rawptr, data: []u8) -> bool {
	_ = user
	return libuser.write_full(data_fd, data)
}

// The grid's origin inside the client area, and its ceiling. The origin
// keeps the first column clear of the window's edge; the ceiling bounds
// the cells kept in memory.
TEXT_X :: 8
TEXT_Y :: 8
MAX_COLS :: 96
MAX_ROWS :: 32

CARET_H :: 2

// The shell, and how a line reaches it.
DEFAULT :: "/bin/rc"
LINE_MAX :: 256

CMD_CAP :: vectra9.WIRE_SLOT - vectra9.IOHDRSZ
// The batch buffer, the drawer's alone.
cmd: [CMD_CAP]u8

BAND :: (CMD_CAP - libdraw.HEADER - 20) / (libfont.FONT_HEIGHT * 4)
band: [BAND * libfont.FONT_HEIGHT * 4]u8

// The grid, the cursor and the line being typed: the drawer's, and
// nobody else's.
cells: [MAX_ROWS][MAX_COLS]rune
row_dirty: [MAX_ROWS]bool
cols, rows: int
crow, ccol: int

editing: [LINE_MAX]u8
edit: libedit.Line
keys: [256]u8
out: [1024]u8
finished: [LINE_MAX + 1]u8
geo: [160]u8
path_buf: [32]u8

data_fd: int
cons_fd: int
out_fd: int // The read end of the command's descriptors 1 and 2
to_shell: int // The write end of the command's descriptor 0
shell_pid: u64 // Whose group a typed ^C goes to

// The command to run, from this program's own arguments. Set in `start`
// before any thread, so the fork below sees it. A slice of the argument
// block the kernel left on the stack, which lives for the program's life.
cmd_path: string
cmd_argv: []string
one_arg: [1]string

/*
_start claims a window, starts the shell, and hands the process to the
thread library, whose first thread serves the shell from both sides.

The exits each name their failure: 0x74 the mount was refused, 0x75 a
mounted file would not open, 0x76 a geometry this program cannot draw on,
0x78 a draw write refused or the window's own console would not open,
0x72 the shell would not start. From `threadmain` on a failure is a word:
`ioproc`, `threadcreate`, or `read` for a keyboard that ended. Zero is the
shell ending.
*/
// resolve turns a bare command name into a `/bin` path, which is what a
// person types and what `rio` does. A name with a slash is a path
// already and is left alone. The `exec` call searches no path of its
// own, so this is the one convention `window` keeps.
path_buf2: [64]u8

// die says why this window could not be, on the desktop's error stream, and
// exits with the code the comment above names. It is spawned detached, so
// the code alone reaches nobody.
die :: proc "contextless" (code: u64, why: string, err: i64) -> ! {
	libuser.eprint("window: ", why, err < 0 ? ": " : "", err < 0 ? libuser.errstr(err) : "", "\n")
	libuser.exit(code)
}

resolve :: proc "contextless" (name: string) -> string #no_bounds_check {
	for i in 0 ..< len(name) {
		if name[i] == '/' {
			return name
		}
	}
	at := copy(path_buf2[:], "/bin/")
	at += copy(path_buf2[at:], name)
	return string(path_buf2[:at])
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()

	// The command, from this program's own arguments. The first is the
	// path and the whole list is its argv. With none, `/bin/rc` and a
	// one-element argv this program owns.
	args := libuser.args(block)
	if len(args) > 1 {
		cmd_path = resolve(args[1])
		cmd_argv = args[1:]
	} else {
		one_arg[0] = DEFAULT
		cmd_path = DEFAULT
		cmd_argv = one_arg[:]
	}

	// The kernel's console is not this program's to touch: it reads the
	// window's, which the draw server cooks, and the serial line behind the
	// kernel's console may be a shell of its own that wants its echo. An
	// earlier terminal wrote `echooff` here, from the days it read the
	// kernel's console itself.
	if e := libuser.mount("/srv/draw", "/mnt", abi.ORDER_BEFORE); e < 0 {
		die(0x74, "the draw server would not mount", e)
	}

	// Which window is this one's, and then the claim on it: `/mnt/new` names
	// the window with no session, and opening its `data` is the claim.
	nfd := libuser.open("/mnt/new", abi.O_RDONLY)
	if nfd < 0 {
		die(0x74, "no window to claim, /mnt/new", nfd)
	}
	nn := libuser.read(int(nfd), geo[:])
	_ = libuser.close(int(nfd))
	scan := 0
	mine, mok := libdraw.scan_int(geo[:max(int(nn), 0)], &scan)
	if !mok {
		die(0x76, "/mnt/new named no window", 0)
	}

	fd := libuser.open(libdraw.win_path(path_buf[:], "/mnt", mine, "data"), abi.O_WRONLY)
	if fd < 0 {
		die(0x75, "the window's data would not open", fd)
	}
	data_fd = int(fd)

	// The client area's geometry decides the grid, and the bar gets a name.
	ctl := libuser.open(libdraw.win_path(path_buf[:], "/mnt", mine, "ctl"), abi.O_RDWR)
	if ctl < 0 {
		die(0x75, "the window's ctl would not open", ctl)
	}
	n := libuser.read(int(ctl), geo[:])
	w, h, _, _, gok := libdraw.parse_geometry(geo[:max(int(n), 0)])
	if !gok || h < 56 || w < 80 {
		_ = libuser.close(int(ctl))
		die(0x76, "a window too small to draw on", 0)
	}
	cols = min((w - 2 * TEXT_X) / libfont.FONT_WIDTH, MAX_COLS)
	rows = min((h - 2 * TEXT_Y) / libfont.FONT_HEIGHT, MAX_ROWS)
	title := "name terminal"
	_ = libuser.write(int(ctl), transmute([]u8)title)
	_ = libuser.close(int(ctl))
	// The program the window runs, for the server's rules: `app` on `wctl`.
	if wfd := libuser.open(libdraw.win_path(path_buf[:], "/mnt", mine, "wctl"), abi.O_WRONLY); wfd >= 0 {
		app: [48]u8
		_ = libuser.write(int(wfd), transmute([]u8)libuser.cat_into(app[:], "app ", libuser.basename(cmd_path)))
		_ = libuser.close(int(wfd))
	}

	/*
	This window's own `/dev`, which is `rio`'s `filsysmount` one bind
	shorter: the window's directory over `/dev`, before everything else, so
	`/dev/cons` is this window's keyboard. Opened after the bind, because a
	bind does not move a file already held. Then raw, because this program
	is the one that draws what is typed.
	*/
	if e := libuser.bind(libdraw.win_dir(path_buf[:], "/mnt", mine), "/dev", abi.ORDER_BEFORE); e < 0 {
		die(0x78, "the window would not bind over /dev", e)
	}
	cons := libuser.open("/dev/cons", abi.O_RDONLY)
	if cons < 0 {
		die(0x78, "the window's cons would not open", cons)
	}
	wctl := libuser.open("/dev/consctl", abi.O_WRONLY)
	if wctl < 0 {
		die(0x78, "the window's consctl would not open", wctl)
	}
	raw := "rawon"
	if e := libuser.write(int(wctl), transmute([]u8)raw); e != i64(len(raw)) {
		die(0x78, "rawon was refused", e)
	}

	for r in 0 ..< MAX_ROWS {
		for c in 0 ..< MAX_COLS {
			cells[r][c] = ' '
		}
	}
	edit = libedit.Line{buf = editing[:]}

	upload_font()
	for r in 0 ..< rows {
		row_dirty[r] = true
	}
	present()

	/*
	The shell, with the pipes as its three descriptors.

	`rfork(RFPROC | RFFDG)` gives the child a copy of the table to rearrange.
	It puts the pipes on 0, 1 and 2, closes everything above -- the window's
	data stream among them, which would otherwise keep the window claimed
	past this program's life -- and execs. The exec keeps the namespace, so
	a program the shell runs that opens `/dev/cons` gets this window's.
	*/
	in_pipe := libuser.pipe()
	out_pipe := libuser.pipe()
	if in_pipe < 0 || out_pipe < 0 {
		die(0x72, "no pipe for the shell", min(in_pipe, out_pipe))
	}
	in_r, in_w := abi.pipe_ends(in_pipe)
	out_r, out_w := abi.pipe_ends(out_pipe)

	// A note group of its own, so a typed `^C` reaches the shell and what
	// it runs, and not this program.
	shell := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOTEG)
	if shell < 0 {
		die(0x72, "the shell's fork was refused", shell)
	}
	shell_pid = u64(shell)
	if shell == 0 {
		_ = libuser.dup(in_r, 0)
		_ = libuser.dup(out_w, 1)
		_ = libuser.dup(out_w, 2)
		libuser.close_from(3)
		e := libuser.exec(cmd_path, cmd_argv)
		die(0x72, "the command would not run", e)
	}
	_ = libuser.close(in_r)
	_ = libuser.close(out_w)
	to_shell = in_w
	out_fd = out_r
	cons_fd = int(cons)

	libthread.main(threadmain, nil)
}

/*
threadmain is the drawer: the typist thread, and then the shell's output
into the grid for as long as the shell lives. The read goes through an io
proc, so the typist runs while it parks.
*/
threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	if libthread.threadcreate(type_thread, nil) < 0 {
		libthread.threadexitsall("threadcreate")
	}
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexitsall("ioproc")
	}
	for {
		got := libthread.ioread(io, out_fd, out[:])
		if got <= 0 {
			// The shell is gone -- a typed `exit` or a fault. Collect it,
			// and if it faulted, post the desktop's notice before the
			// window goes. Take the io procs down and let the window go.
			fault_notice()
			libthread.threadexitsall("")
		}
		for i in 0 ..< int(got) {
			put_byte(out[i])
		}
		present()
	}
}

/*
fault_notice collects the ended shell and, when it died by a trap rather
than a clean exit or a caught signal, posts the desktop's fault notice,
`docs/WORKBENCH.md` section 6: `window <prog> faulted: <trap>` to
`/mnt/wb/notice`, the toast in the bar's corner.

`window` runs every program the desktop starts, so `window` is what sees one
die. `await` answers `<pid> <status>`, and the status is how the kernel ended
it: a program taken down by an uncaught trap says `fault` (`kernel/user/spawn.
odin`'s word for that ending), a typed `exit` says its pid alone, a `^C` or a
`kill` says `interrupt` or `kill`, a breakpoint `sys: breakpoint`. Only the
first is a fault, and only it posts a notice.

**The trap's detail is not in the status.** The kernel keeps the faulting
`addr` and `pc` in the exit record but does not serialise them into the await
word on the ending path, so today's notice can only say *that* a program
faulted, not where. The `sys: trap: addr=... pc=...` text `post_trap_note`
builds reaches `await` only when a debugger was watching (which parks instead
of ending); this reads it too, for that day, but the plain `fault` word is the
case the desktop hits.

**The ghost's half is not here.** With the ghost on, `window` parks the
process on the fault and the notice's action is `ask -c debug -p N`, a click
that hands the parked process to the agent -- `docs/GHOST.md` step 3. That day
this notice grows the action, the parking, and the trap detail; until then it
is the honest statement that a program faulted, and nothing waits.
*/
fault_notice :: proc "contextless" () #no_bounds_check {
	buf: [256]u8
	n := libuser.await(shell_pid, buf[:])
	if n <= 0 {
		return
	}
	// await answers `<pid> <status>`; the status is after the first space, and
	// a child that exited cleanly answers with its pid alone.
	status := string(buf[:n])
	sp := -1
	for i in 0 ..< len(status) {
		if status[i] == ' ' {sp = i;break}
	}
	if sp < 0 {
		return
	}
	word := status[sp + 1:]
	// Is it a fault? The kernel's ending word is `fault`; a debugger-watched
	// trap instead carries the `sys: trap: <kind> addr=... pc=...` detail. A
	// clean exit, a `^C`/`kill`, or an `exits` string is not a fault.
	TRAP :: "sys: trap: "
	detail := ""
	switch {
	case word == "fault":
	case len(word) >= len(TRAP) && string(word[:len(TRAP)]) == TRAP:
		detail = word[len(TRAP):]
	case:
		return
	}

	line: [320]u8
	at := copy(line[:], "window ")
	at += copy(line[at:], libuser.basename(cmd_path))
	at += copy(line[at:], " faulted")
	if len(detail) > 0 {
		at += copy(line[at:], ": ")
		at += copy(line[at:], detail)
	}
	// No desktop mounted, no notices; the console's own `window` still runs.
	fd := libuser.open("/mnt/wb/notice", abi.O_WRONLY)
	if fd < 0 {
		return
	}
	_ = libuser.write(int(fd), line[:at])
	_ = libuser.close(int(fd))
}

/*
type_thread is the typist: keys off the window's console through an io
proc, into the line `libedit` edits and drawn where they are, and a
finished line to the shell. A newline finishes the line, which is echoed
into the grid before it is sent so it stays on the glass above whatever
the shell says about it. `^C` is `rio`'s interrupt: the line goes, and
the shell's group hears about it. The write to the shell is the one call
here that can park, when the shell is slow to read, and it parks the proc.
*/
type_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexitsall("ioproc")
	}
	for {
		got := libthread.ioread(io, cons_fd, keys[:])
		if got <= 0 {
			libthread.threadexitsall("read")
		}
		send_line := 0
		for i in 0 ..< int(got) {
			if keys[i] == 0x03 {
				libedit.clear(&edit)
				row_dirty[crow] = true
				_ = libuser.notepg(shell_pid, "interrupt")
				continue
			}
			switch libedit.put(&edit, keys[i]) {
			case .Done:
				text := libedit.text(&edit)
				for j in 0 ..< len(text) {
					put_byte(text[j])
				}
				put_byte('\n')
				send_line = copy(finished[:], text)
				finished[send_line] = '\n'
				send_line += 1
				libedit.clear(&edit)
			case .Edited:
				row_dirty[crow] = true
			case .Full, .Pending:
			}
		}
		present()
		if send_line > 0 {
			_ = libuser.write_full(to_shell, finished[:send_line])
		}
	}
}

// -- The grid -------------------------------------------------------------------

// The bytes of an output rune that has not finished arriving. The command
// writes UTF-8 and `put_byte` takes it a byte at a time, so a rune past ASCII
// waits here until it is whole. Never longer than one rune.
out_pend: [4]u8
out_need: int
out_have: int

/*
put_byte moves the cursor and the cells the way a terminal does, and gathers
the UTF-8 of a rune past ASCII across the bytes it arrives in. A byte that is
no continuation of a half-gathered rune abandons it -- 9front's `chartorune`
answering `Runeerror` and moving on -- and is then handled fresh, so a stream
this cannot read makes progress rather than stalling.
*/
put_byte :: proc "contextless" (b: u8) #no_bounds_check {
	if out_need != 0 {
		if b & 0xC0 == 0x80 {
			out_pend[out_have] = b
			out_have += 1
			if out_have == out_need {
				r, _ := libdraw.decode_rune(out_pend[:out_have])
				out_need, out_have = 0, 0
				place_rune(r)
			}
			return
		}
		out_need, out_have = 0, 0 // Not a continuation: the half rune is dropped.
	}
	switch b {
	case '\n':
		newline()
	case '\r':
		ccol = 0
	case '\b':
		if ccol > 0 {
			ccol -= 1
		}
	case '\t':
		next := (ccol + 8) / 8 * 8
		for ccol < next && ccol < cols {
			cells[crow][ccol] = ' '
			ccol += 1
		}
		row_dirty[crow] = true
	case:
		if b < 0x20 {
			return
		}
		if b < 0x80 {
			place_rune(rune(b))
			return
		}
		// A UTF-8 lead byte: how many bytes the rune is, then gather them.
		switch {
		case b & 0xE0 == 0xC0:
			out_need = 2
		case b & 0xF0 == 0xE0:
			out_need = 3
		case b & 0xF8 == 0xF0:
			out_need = 4
		case:
			return // A stray continuation or an invalid lead: dropped.
		}
		out_pend[0] = b
		out_have = 1
	}
}

// place_rune puts one whole rune at the cursor and steps it, wrapping to the
// next row at the right edge.
place_rune :: proc "contextless" (r: rune) #no_bounds_check {
	if ccol >= cols {
		newline()
	}
	cells[crow][ccol] = r
	ccol += 1
	row_dirty[crow] = true
}

// newline moves to the next row, scrolling when the last is used up.
newline :: proc "contextless" () #no_bounds_check {
	ccol = 0
	if crow + 1 < rows {
		crow += 1
		return
	}
	for r in 1 ..< rows {
		cells[r - 1] = cells[r]
		row_dirty[r - 1] = true
	}
	for c in 0 ..< MAX_COLS {
		cells[rows - 1][c] = ' '
	}
	row_dirty[rows - 1] = true
}

// -- Drawing --------------------------------------------------------------------

send :: proc "contextless" (buf: []u8, at: int) {
	if at <= 0 || !libuser.write_full(data_fd, buf[:at]) {
		die(0x78, "a draw write was refused", 0)
	}
}

cell_x :: proc "contextless" (col: int) -> u32 {
	return u32(TEXT_X + col * libfont.FONT_WIDTH)
}

cell_y :: proc "contextless" (row: int) -> u32 {
	return u32(TEXT_Y + row * libfont.FONT_HEIGHT)
}

/*
present draws what changed: every row marked dirty, then the line being
typed over the cursor's row and the caret after it, and one flush.

The drawer is the one thread that touches the grid and the line, so what
it reads here is what it drew from, and the round trips to the draw
server keep nobody waiting but the drawer.
*/
present :: proc "contextless" () #no_bounds_check {
	dirty: [MAX_ROWS]bool
	text_copy: [LINE_MAX]u8
	dirty = row_dirty
	for r in 0 ..< MAX_ROWS {
		row_dirty[r] = false
	}
	// The cursor's row carries the typed line, so it is redrawn with it.
	row := crow
	col := ccol
	dirty[row] = true
	text := libedit.text(&edit)
	n := copy(text_copy[:], text)
	caret := col + libedit.cursor(&edit)

	buf: [CMD_CAP]u8
	at := 0
	for r in 0 ..< rows {
		if dirty[r] {
			at = draw_row(buf[:], at, r)
		}
	}
	shown := string(text_copy[:min(n, max(cols - col, 0))])
	done := 0
	for done < len(shown) {
		nat, put, _ := libdraw.put_text(buf[:], at, atlas, 0, cell_x(col + done), cell_y(row), shown[done:])
		done += put
		if done < len(shown) {
			send(buf[:], nat)
			at = 0
		} else {
			at = nat
		}
	}
	if caret < cols {
		at = libdraw.put_fill(
			buf[:],
			at,
			0,
			cell_x(caret),
			cell_y(row) + u32(libfont.FONT_HEIGHT - CARET_H),
			u32(libfont.FONT_WIDTH),
			CARET_H,
			FG,
		)
	}
	send(buf[:], libdraw.put_flush(buf[:], at))
}

// draw_row fills a row and blits its glyphs, in as many batches as it
// takes. Answers where the open batch ends.
draw_row :: proc "contextless" (buf: []u8, start: int, r: int) -> int #no_bounds_check {
	at := libdraw.put_fill(buf, start, 0, cell_x(0), cell_y(r), u32(cols * libfont.FONT_WIDTH), libfont.FONT_HEIGHT, BG)
	end := cols
	for end > 0 && cells[r][end - 1] == ' ' {
		end -= 1
	}
	runes := cells[r][:end]
	done := 0
	for done < len(runes) {
		nat, put := libdraw.put_runes(buf, at, atlas, 0, cell_x(done), cell_y(r), runes[done:])
		done += put
		if done < len(runes) {
			send(buf, nat)
			at = 0
		} else {
			at = nat
		}
	}
	return at
}

/*
upload_font pays the once-per-life cost: the font opened from `/lib/font`,
then ASCII and the ranges past it baked into strips in amber over slate and
uploaded through the window's `data` stream. `libdraw.bake_atlas` owns the
loop -- the same one `sys/libmui` and `apps/terminal` bake through -- and
fills `atlas`. A bake the server's pool refuses exits the program, as any
draw write that fails does; there is no half-drawn font to fall back to.
*/
upload_font :: proc "contextless" () #no_bounds_check {
	_ = libfont.loader_open(&text_font, "/lib/font/default.font", font_read, nil)
	if _, ok := libdraw.bake_atlas(&atlas, 1, &text_font, FG, BG, cmd[:], band[:], font_write, nil); !ok {
		die(0x78, "the draw server's image pool refused the font", 0)
	}
}
