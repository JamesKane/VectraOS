/*
terminal -- a window with a shell in it.

`rio` opens a window and runs `rc` in it, and the window is what the shell
reads from and writes to. This program is that, on the draw server. It
claims a window, uploads the font, starts `/bin/rc` with two pipes for its
three descriptors, and from then on it is two things at once: the glass the
shell's output lands on, and the keyboard the shell's input comes from.

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
package terminal

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
// uploads the strips in this program's amber over its slate, once, so its
// ranges are not known until then -- a var, not a constant like it was when
// the font stopped at ASCII.
PER_STRIP :: 16
atlas: libdraw.Atlas

// term_font is the font past ASCII, opened once from `/lib/font`. A failure
// is not fatal: `bake_atlas` bakes ASCII from the baked table alone.
term_font: libfont.Loader

// term_read is the font loader's I/O, and term_write the bake's sink -- the
// window's own `data` stream, which `send` writes to.
term_read :: proc "contextless" (data: rawptr, path: string, into: []u8) -> int {
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

term_write :: proc "contextless" (user: rawptr, data: []u8) -> bool {
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
SHELL :: "/bin/rc"
LINE_MAX :: 256

CMD_CAP :: vectra9.WIRE_SLOT - vectra9.IOHDRSZ
// The batch buffer, the drawer's alone.
cmd: [CMD_CAP]u8

BAND :: (CMD_CAP - libdraw.HEADER - 20) / (libfont.FONT_HEIGHT * 4)
band: [BAND * libfont.FONT_HEIGHT * 4]u8

// The grid, the cursor and the line being typed: the drawer's, and
// nobody else's. A cell is a rune, not a byte, so a program's output past
// ASCII lands whole -- `put_byte` decodes the UTF-8 the shell writes.
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
out_fd: int // The read end of the shell's descriptors 1 and 2
to_shell: int // The write end of the shell's descriptor 0
shell_pid: u64 // Whose group a typed ^C goes to

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
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()

	// The kernel's console is not this program's to touch: it reads the
	// window's, which the draw server cooks, and the serial line behind the
	// kernel's console may be a shell of its own that wants its echo. An
	// earlier terminal wrote `echooff` here, from the days it read the
	// kernel's console itself.
	if libuser.mount("/srv/draw", "/mnt", abi.ORDER_BEFORE) < 0 {
		libuser.exit(0x74)
	}

	// Which window is this one's, and then the claim on it: `/mnt/new` names
	// the window with no session, and opening its `data` is the claim.
	nfd := libuser.open("/mnt/new", abi.O_RDONLY)
	if nfd < 0 {
		libuser.exit(0x74)
	}
	nn := libuser.read(int(nfd), geo[:])
	_ = libuser.close(int(nfd))
	scan := 0
	mine, mok := libdraw.scan_int(geo[:max(int(nn), 0)], &scan)
	if !mok {
		libuser.exit(0x76)
	}

	fd := libuser.open(libdraw.win_path(path_buf[:], "/mnt", mine, "data"), abi.O_WRONLY)
	if fd < 0 {
		libuser.exit(0x75)
	}
	data_fd = int(fd)

	// The client area's geometry decides the grid, and the bar gets a name.
	ctl := libuser.open(libdraw.win_path(path_buf[:], "/mnt", mine, "ctl"), abi.O_RDWR)
	if ctl < 0 {
		libuser.exit(0x75)
	}
	n := libuser.read(int(ctl), geo[:])
	w, h, _, _, gok := libdraw.parse_geometry(geo[:max(int(n), 0)])
	if !gok || h < 56 || w < 80 {
		_ = libuser.close(int(ctl))
		libuser.exit(0x76)
	}
	cols = min((w - 2 * TEXT_X) / libfont.FONT_WIDTH, MAX_COLS)
	rows = min((h - 2 * TEXT_Y) / libfont.FONT_HEIGHT, MAX_ROWS)
	title := "name terminal"
	_ = libuser.write(int(ctl), transmute([]u8)title)
	_ = libuser.close(int(ctl))

	/*
	This window's own `/dev`, which is `rio`'s `filsysmount` one bind
	shorter: the window's directory over `/dev`, before everything else, so
	`/dev/cons` is this window's keyboard. Opened after the bind, because a
	bind does not move a file already held. Then raw, because this program
	is the one that draws what is typed.
	*/
	if libuser.bind(libdraw.win_dir(path_buf[:], "/mnt", mine), "/dev", abi.ORDER_BEFORE) < 0 {
		libuser.exit(0x78)
	}
	cons := libuser.open("/dev/cons", abi.O_RDONLY)
	if cons < 0 {
		libuser.exit(0x78)
	}
	wctl := libuser.open("/dev/consctl", abi.O_WRONLY)
	if wctl < 0 {
		libuser.exit(0x78)
	}
	raw := "rawon"
	if libuser.write(int(wctl), transmute([]u8)raw) != i64(len(raw)) {
		libuser.exit(0x78)
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
		libuser.exit(0x72)
	}
	in_r, in_w := abi.pipe_ends(in_pipe)
	out_r, out_w := abi.pipe_ends(out_pipe)

	// A note group of its own, so a typed `^C` reaches the shell and what
	// it runs, and not this program.
	shell := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFNOTEG)
	if shell < 0 {
		libuser.exit(0x72)
	}
	shell_pid = u64(shell)
	if shell == 0 {
		_ = libuser.dup(in_r, 0)
		_ = libuser.dup(out_w, 1)
		_ = libuser.dup(out_w, 2)
		libuser.close_from(3)
		argv := [?]string{"rc"}
		_ = libuser.exec(SHELL, argv[:])
		libuser.exit(0x72)
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
			// The shell is gone. Take the io procs down and let the
			// window go.
			libthread.threadexitsall("")
		}
		for i in 0 ..< int(got) {
			put_byte(out[i])
		}
		present()
	}
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

// The bytes of an output rune that has not finished arriving. The shell
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
		libuser.exit(0x78)
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
loop -- the same one `sys/libmui` and `cmd/window` bake through -- and fills
`atlas`. A bake that the server's pool refuses exits the program, as any draw
write that fails does; there is no half-drawn font to fall back to.
*/
upload_font :: proc "contextless" () #no_bounds_check {
	_ = libfont.loader_open(&term_font, "/lib/font/default.font", term_read, nil)
	if _, ok := libdraw.bake_atlas(&atlas, 1, &term_font, FG, BG, cmd[:], band[:], term_write, nil); !ok {
		libuser.exit(0x78)
	}
}
