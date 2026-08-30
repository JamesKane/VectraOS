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
frame the server refuses. So the command buffer stays under that bound,
one glyph load goes per write, and `put_text`'s consumed-count return is
what lets a long line pump through in batches.

The kernel's console owns the echo of typed bytes, and this program does
not want two renderers on one line. So it writes `echooff` to
`/dev/consctl` first and holds that file for its whole life -- the mode
reverts when the descriptor closes, which is exit. What a person types
appears once, drawn by this program, when the line completes.

A line of `exit` ends it, status zero. The line discipline hands over
whole lines, so the loop is: read descriptor zero, strip the newline,
render or obey.
*/
package terminal

import "base:runtime"

import "vsys:abi"
import "vsys:libdraw"
import "vsys:libfont"
import "vsys:libuser"
import "vsys:vectra9"

// The terminal's two colors, in the 32-bit format `/dev/fbctl` reports.
FG :: u32(0x00FFB028)
BG :: u32(0x00181F28)

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

// One glyph expanded to pixels: 8x16 cells, four bytes each.
rowbuf: [libfont.FONT_WIDTH * libfont.FONT_HEIGHT * 4]u8

line: [256]u8
geo: [160]u8

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

	ctl := libuser.open("/mnt/ctl", abi.O_RDONLY)
	if ctl < 0 {
		libuser.exit(0x75)
	}
	n := libuser.read(int(ctl), geo[:])
	_ = libuser.close(int(ctl))
	// Only the height steers the layout. The width goes unused because
	// the field is fixed and the server clips, and the depth is the
	// server's own refusal.
	_, h, _, _, gok := libdraw.parse_geometry(geo[:max(int(n), 0)])
	if !gok || h < 56 {
		libuser.exit(0x76)
	}
	field_y = u32(h - 40)

	fd := libuser.open("/mnt/data", abi.O_WRONLY)
	if fd < 0 {
		libuser.exit(0x75)
	}
	data_fd = int(fd)

	upload_font()
	prompt()

	for {
		got := libuser.read(0, line[:])
		if got <= 0 {
			libuser.exit(0x79)
		}
		// The discipline hands over whole lines. Up to the first newline
		// is this line, and a second one queued behind it can wait for
		// the next read.
		end := 0
		for end < int(got) && line[end] != '\n' {
			end += 1
		}
		text := string(line[:end])
		if text == "exit" {
			libuser.exit(0)
		}
		render(text)
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
one load per glyph, one write each. A glyph's load is 536 bytes -- two
would cross the wire bound -- so the loop is 95 small writes, and every
blit afterwards is 36. That trade is the design's whole argument.
*/
upload_font :: proc "contextless" () #no_bounds_check {
	at := 0
	for s in 0 ..< STRIPS {
		at = libdraw.put_alloc(cmd[:], at, u32(1 + s), PER_STRIP * libfont.FONT_WIDTH, libfont.FONT_HEIGHT)
	}
	send(at)

	for g in 0 ..< GLYPHS {
		for y in 0 ..< libfont.FONT_HEIGHT {
			bits := libfont.font_8x16[g][y]
			for x in 0 ..< libfont.FONT_WIDTH {
				v := bits & (0x80 >> u8(x)) != 0 ? FG : BG
				libdraw.put_u32(rowbuf[:], (y * libfont.FONT_WIDTH + x) * 4, v)
			}
		}
		// The cell comes from the same arithmetic `put_text` blits by, so
		// the uploader and the blitter cannot disagree about the layout.
		image, sx := libdraw.atlas_cell(ATLAS, g)
		send(libdraw.put_load(cmd[:], 0, image, sx, 0, libfont.FONT_WIDTH, libfont.FONT_HEIGHT, rowbuf[:]))
	}
}

// prompt paints the field once: background, the two prompt cells, and a
// flush. One write carries all of it.
prompt :: proc "contextless" () {
	at := libdraw.put_fill(cmd[:], 0, 0, FIELD_X, field_y, FIELD_W, FIELD_H, BG)
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
