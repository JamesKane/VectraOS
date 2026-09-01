/*
terminal -- the first program in apps/, and the draw server's first client.

Every server so far stood behind a name and waited. This is the other
side of the economy: a program that consumes two services at once. It
reads lines from `/dev/cons`, and it draws them through `/srv/draw` --
which it mounts itself, the first ring 3 mount in the tree. A namespace
is a process's own to arrange, and this program is the first to exercise
that sentence rather than inherit its arrangement.

The rendering is `docs/DRAW.md`'s economics in miniature. At start the
terminal uploads the font once: six strip images of sixteen cells, the
kernel's own 8x16 ASCII table expanded from one bit to one word per
pixel. From then on a character costs one 36-byte blit, and a line is a
batch of them. `sys/libfont` carries the table and `sys/libdraw`'s
`put_text` owns the arithmetic from a byte to its blit.

One number rules every batch: the posted-pipe wire moves at most 1000
payload bytes per write, and a command split across two writes is a
frame the server refuses. So the command buffer is sized to that bound,
the font uploads in bands as wide as one write carries, and `put_text`'s
consumed-count return is what lets a long line pump through in batches.

The kernel's console owns the echo of typed bytes, and this program does
not want two renderers on one line. So it writes `echooff` to
`/dev/consctl` first and holds that file for its whole life -- the mode
reverts when the descriptor closes, which is exit. What a person types
appears once, drawn by this program, when the line completes.

That write reaches `kernel/devfs`, because it happens before this program
mounts anything. The draw server holds the same file *raw* for its own
reasons, and raw mode turns the echo off with it, so this is belt and braces
now rather than the thing that turns it off. A window's own `consctl` is a
different file and this program has no reason to write to it.

A line of `exit` ends it, status zero. The line discipline hands over
whole lines, so the loop is: read descriptor zero, strip the newline,
render or obey.
*/
package terminal

import "base:runtime"

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libedit"
import "vsys:libfont"
import "vsys:libpal"
import "vsys:libuser"
import "vsys:vectra9"

// The terminal's two colors, in the 32-bit format `/dev/fbctl` reports.
// The two colours, out of the one table both privilege levels read. They were
// written out as pixel words here until `sys/libpal` existed, which is one of
// the three copies that file's own comment promised to retire.
FG :: u32(libpal.AMBER[0]) << 16 | u32(libpal.AMBER[1]) << 8 | u32(libpal.AMBER[2])
BG :: u32(libpal.SLATE[0]) << 16 | u32(libpal.SLATE[1]) << 8 | u32(libpal.SLATE[2])

// The well the field sits in: `kernel/splash.odin`'s console well, one
// privilege level out and a few hundred pixels across. The padding is what
// keeps the bevel clear of the text, so no glyph lands on an edge.
WELL_PAD :: 4

// The atlas: six strips of sixteen 8x16 cells, ids 1..6, holding the
// font's 95 glyphs. Strip six carries fifteen and its last cell stays
// blank. Six of the server's eight images -- a client is a guest here.
STRIPS :: 6
PER_STRIP :: 16
GLYPHS :: libfont.FONT_LAST - libfont.FONT_FIRST + 1

ATLAS :: libdraw.Atlas {
	first_image_id = 1,
	per_image      = PER_STRIP,
	cell_w         = libfont.FONT_WIDTH,
	cell_h         = libfont.FONT_HEIGHT,
	first_char     = libfont.FONT_FIRST,
	count          = GLYPHS,
}

/*
The field: one line of text at a fixed place near the screen's bottom
edge, below the kernel console's well. A fixed width rather than the
screen's, so the self-test's save buffer has a fixed size too. The
prompt takes the first two cells and the input the other forty-two.
*/
FIELD_X :: 8
FIELD_W :: 352
FIELD_H :: libfont.FONT_HEIGHT
PROMPT :: "> "
INPUT_X :: FIELD_X + 2 * libfont.FONT_WIDTH
MAX_COLS :: 42

field_y: u32

/*
The command buffer, sized to exactly what one posted-pipe write carries.
`sys_write` splits anything larger at this boundary -- which would tear
a command in half -- and the bound is derived from the same constant the
kernel cuts the wire's arena from, so the two cannot drift apart.
*/
CMD_CAP :: vectra9.WIRE_SLOT - vectra9.IOHDRSZ
cmd: [CMD_CAP]u8

// One load's worth of pixels: a band as wide as one write can carry,
// derived from the wire bound rather than chosen. Fifteen columns today.
BAND :: (CMD_CAP - libdraw.HEADER - 20) / (libfont.FONT_HEIGHT * 4)
STRIP_W :: PER_STRIP * libfont.FONT_WIDTH
band: [BAND * libfont.FONT_HEIGHT * 4]u8

line: [256]u8

// The line under construction, which this program holds because it is the one
// that draws. `MAX_COLS` is what the field shows; a longer line keeps its
// beginning, which is the part somebody meant.
editing: [MAX_COLS]u8
geo: [160]u8

// Where the two paths into this client's own window directory are built.
// `libdraw.win_path` owns the layout, because the server walks the same names
// and a second app would otherwise copy this.
path_buf: [32]u8

data_fd: int

/*
_start quiets the echo, mounts the draw server, learns the screen,
uploads the font, and serves a person.

The exits each name their failure: 0x77 the echo would not turn off,
0x74 the mount was refused, 0x75 a mounted file would not open, 0x76 a
geometry this program cannot draw on, 0x78 a draw write refused, 0x79 a
read of descriptor zero failed. Zero is the typed `exit`.
*/
@(export, link_name = "_start")
start :: proc "sysv" (data: uintptr, arg: u64, arg2: u64) {
	context = {}
	#force_no_inline runtime._startup_runtime()

	// First, before anything draws. The write is synchronous, so once the
	// prompt is on the glass the echo is already off. The descriptor is
	// held for life -- the mode reverts when it closes, which is exit.
	consctl := libuser.open("/dev/consctl", abi.O_WRONLY)
	if consctl < 0 {
		libuser.exit(0x77)
	}
	off := "echooff"
	if libuser.write(int(consctl), transmute([]u8)off) != i64(len(off)) {
		libuser.exit(0x77)
	}

	if libuser.mount("/srv/draw", "/mnt", 0) < 0 {
		libuser.exit(0x74)
	}

	/*
	Which window is this one's, and then the claim on it.

	The draw server's tree is a directory per window now, so a client asks
	`/mnt/new` which one has no session and then opens that one's `data`.
	Reading `new` reserves nothing: the claim is the open, and a client that
	loses the race between the two is refused and would have to ask again.
	One app cannot lose it, and the day two do is the day this loop is worth
	writing.
	*/
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

	/*
	The controls, opened both ways: the geometry comes out and a name goes
	in.

	The geometry is this program's *client area*, which is the window with
	its border and title bar taken off. A client is never told there is a
	frame, and this one does not need to be: it lays itself out in the
	rectangle it was given and the server puts it where it goes.

	Only the height steers the layout. The width goes unused because the
	field is fixed and the server clips, and the depth is the server's own
	refusal.
	*/
	ctl := libuser.open(libdraw.win_path(path_buf[:], "/mnt", mine, "ctl"), abi.O_RDWR)
	if ctl < 0 {
		libuser.exit(0x75)
	}
	n := libuser.read(int(ctl), geo[:])
	_, h, _, _, gok := libdraw.parse_geometry(geo[:max(int(n), 0)])
	if !gok || h < 56 {
		_ = libuser.close(int(ctl))
		libuser.exit(0x76)
	}
	field_y = u32(h - 40)

	// And the bar across the top says whose window it is. The first thing in
	// the tree to use the fourth `ctl` line, and the whole of what a program
	// has to do to be named. The descriptor goes after, because a `ctl` fid
	// held for life would deny the controls to anything else.
	title := "name terminal"
	_ = libuser.write(int(ctl), transmute([]u8)title)
	_ = libuser.close(int(ctl))

	/*
	And this window's own `/dev`, which is how a program reads the keyboard
	it was typed at.

	**This is `rio`'s `filsysmount`, one bind shorter.** `rio` mounts its
	per-window file set at `/mnt/wsys` with the window's id as the attach
	`aname`, then binds that over `/dev` before everything else, so a program
	in a window opens plain `/dev/cons` and gets the window's. The draw server
	here already serves a directory per window, so the mount is done and the
	bind is of that directory.

	`ORDER_BEFORE` and not `ORDER_REPLACE`: `/dev/consctl`, `/dev/fb` and
	every other device still have to resolve behind it. Only the names this
	window serves -- `cons` among them -- are taken over.

	The descriptor comes after the bind, because a bind does not move a file
	somebody already holds open. Descriptor zero is still the kernel's console
	from before this program started, and this is the one that replaces it.
	*/
	if libuser.bind(libdraw.win_dir(path_buf[:], "/mnt", mine), "/dev", abi.ORDER_BEFORE) < 0 {
		libuser.exit(0x78)
	}
	cons := libuser.open("/dev/cons", abi.O_RDONLY)
	if cons < 0 {
		libuser.exit(0x78)
	}

	/*
	And this window's keyboard raw, because this program is the one that
	draws.

	**A person has to see the characters as they are typed**, and the only
	thing that can show them is whatever owns the pixels. In `rio` that is the
	window itself, which is why a `rio` window echoes and the program in it
	never has to. Here the draw server holds the line and this program holds
	the glass, so the two cannot both be right -- and the one that draws is
	the one that must hold the line.

	Every Plan 9 program that draws its own text does this. `vt`, `con`,
	`ssh` and `sam` all write `rawon` and edit for themselves, because there
	is no read that answers a line that is not finished yet.

	**`/dev/consctl` is a different file than it was ten lines ago.** The
	`echooff` above went to `kernel/devfs`, because it happened before the
	bind. This one resolves through the window's own directory, so it is that
	window's mode and nobody else's. That is the namespace doing exactly what
	it is for.
	*/
	wctl := libuser.open("/dev/consctl", abi.O_WRONLY)
	if wctl < 0 {
		libuser.exit(0x78)
	}
	raw := "rawon"
	if libuser.write(int(wctl), transmute([]u8)raw) != i64(len(raw)) {
		libuser.exit(0x78)
	}

	upload_font()
	prompt()

	edit := libedit.Line{buf = editing[:]}
	for {
		got := libuser.read(int(cons), line[:])
		if got <= 0 {
			libuser.exit(0x79)
		}
		/*
		Characters now, not lines, and this program cooks them.

		`libedit` is the same discipline `servers/intuition` runs for a window
		that has not asked for raw -- one set of rules about what the erase
		keys mean, worn by both sides of a window's `cons`. What this side
		adds is the echo: every edit redraws the field, so a person sees the
		line while it is still a line.

		A finished line leaves the field showing it. There is no scrollback
		here, so clearing on Enter would take the answer away at the moment it
		arrived, and the next character clears it anyway -- `render` fills the
		field before it draws.
		*/
		for i in 0 ..< int(got) {
			switch libedit.put(&edit, line[i]) {
			case .Done:
				if libedit.text(&edit) == "exit" {
					libuser.exit(0)
				}
				libedit.clear(&edit)
			case .Edited:
				render(libedit.text(&edit))
			case .Full:
			}
		}
	}
}

// send puts one finished batch on the wire, whole. A refusal or an
// encode failure is the same exit: a terminal that cannot draw has
// nothing left to say.
send :: proc "contextless" (at: int) {
	if at <= 0 || !libuser.write_full(data_fd, cmd[:at]) {
		libuser.exit(0x78)
	}
}

/*
upload_font pays the once-per-life cost: six allocs in one write, then
each strip in bands as wide as one write carries. A band crosses cell
boundaries, so a pixel finds its glyph by the atlas arithmetic run
backwards -- column over cell width, through the same `ATLAS` fields
`put_text` blits by -- and a cell past the last glyph loads as
background. Fifty-five writes move the whole set, and every blit
afterwards is 36 bytes. That trade is the design's whole argument.
*/
upload_font :: proc "contextless" () #no_bounds_check {
	at := 0
	for s in 0 ..< STRIPS {
		at = libdraw.put_alloc(cmd[:], at, u32(1 + s), STRIP_W, libfont.FONT_HEIGHT)
	}
	send(at)

	for s in 0 ..< STRIPS {
		for bx := 0; bx < STRIP_W; bx += BAND {
			bw := min(BAND, STRIP_W - bx)
			for y in 0 ..< libfont.FONT_HEIGHT {
				for i in 0 ..< bw {
					px := bx + i
					g := s * ATLAS.per_image + px / ATLAS.cell_w
					v := BG
					if g < GLYPHS {
						bits := libfont.font_8x16[g][y]
						if bits & (0x80 >> u8(px % ATLAS.cell_w)) != 0 {
							v = FG
						}
					}
					libdraw.put_u32(band[:], (y * bw + i) * 4, v)
				}
			}
			send(libdraw.put_load(cmd[:], 0, u32(1 + s), u32(bx), 0, u32(bw), libfont.FONT_HEIGHT, band[:bw * libfont.FONT_HEIGHT * 4]))
		}
	}
}

/*
prompt paints the field once: the well it sits in, the two prompt cells, and a
flush. One write carries all of it.

The well's face is `SLATE`, which is what `BG` already was, so the text lands
on it with nothing between. Its edges are `libdraw`'s decomposition sent down
the wire as ordinary fills -- there is no chrome verb, and section 5 of
`docs/DRAW.md` is why there is not.
*/
prompt :: proc "contextless" () {
	pieces: [libdraw.MAX_PIECES]libdraw.Piece
	n := libdraw.well(
		pieces[:],
		FIELD_X - WELL_PAD,
		int(field_y) - WELL_PAD,
		FIELD_W + 2 * WELL_PAD,
		FIELD_H + 2 * WELL_PAD,
	)
	at := libdraw.put_pieces(cmd[:], 0, 0, pieces[:n])
	at, _ = libdraw.put_text(cmd[:], at, ATLAS, 0, FIELD_X, field_y, PROMPT)
	send(libdraw.put_flush(cmd[:], at))
}

/*
render replaces the input cells with one typed line, truncated to the
field. The first batch carries the background fill and as many blits as
fit; `put_text`'s consumed count pumps the rest through in more batches;
the flush rides the last one.
*/
render :: proc "contextless" (text: string) {
	shown := text[:min(len(text), MAX_COLS)]

	at := libdraw.put_fill(cmd[:], 0, 0, INPUT_X, field_y, FIELD_W - (INPUT_X - FIELD_X), FIELD_H, BG)
	done := 0
	for {
		nat, put := libdraw.put_text(
			cmd[:],
			at,
			ATLAS,
			0,
			u32(INPUT_X + done * libfont.FONT_WIDTH),
			field_y,
			shown[done:],
		)
		done += put
		if done >= len(shown) {
			send(libdraw.put_flush(cmd[:], nat))
			return
		}
		// A batch boundary: write what fits and continue. A buffer that
		// takes nothing would arrive here as zero, and `send` names it.
		send(nat)
		at = 0
	}
}
