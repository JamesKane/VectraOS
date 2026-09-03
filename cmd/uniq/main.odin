// uniq -- drop repeated adjacent lines. -c counts them, -d prints only the
// repeated, -u only the unrepeated.
package uniq

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	count, only_dup, only_uniq := false, false, false
	flag_buf: [8]u8
	letters, rest := libuser.letters(args, flag_buf[:])
	args = rest
	for c in transmute([]u8)letters {
		switch c {
		case 'c':
			count = true
		case 'd':
			only_dup = true
		case 'u':
			only_uniq = true
		}
	}
	fd := 0
	if len(args) > 0 {
		f := libuser.open(args[0], abi.O_RDONLY)
		if f < 0 {
			libuser.eprint("uniq: can't open ", args[0], ": ", libuser.errstr(f), "\n")
			libuser.exits("can't open")
		}
		fd = int(f)
	}
	r: libuser.Reader
	libuser.reader_init(&r, fd)
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	prev := make([dynamic]u8)
	have := false
	repeats: i64 = 0
	emit :: proc(out: ^libuser.Bio, line: []u8, repeats: i64, count, only_dup, only_uniq: bool) {
		if only_dup && repeats == 1 {
			return
		}
		if only_uniq && repeats > 1 {
			return
		}
		if count {
			num: [24]u8
			s := libuser.itoa(num[:], repeats)
			for _ in len(s) ..< 4 {
				libuser.bio_putc(out, ' ')
			}
			libuser.bio_puts(out, s)
			libuser.bio_putc(out, ' ')
		}
		libuser.bio_write(out, line)
		libuser.bio_putc(out, '\n')
	}
	for {
		line, ok := libuser.read_line(&r)
		if !ok {
			break
		}
		if have && line == string(prev[:]) {
			repeats += 1
			continue
		}
		if have {
			emit(&out, prev[:], repeats, count, only_dup, only_uniq)
		}
		clear(&prev)
		append(&prev, ..transmute([]u8)line)
		have = true
		repeats = 1
	}
	if have {
		emit(&out, prev[:], repeats, count, only_dup, only_uniq)
	}
	libuser.bio_flush(&out)
	libuser.exits("")
}
