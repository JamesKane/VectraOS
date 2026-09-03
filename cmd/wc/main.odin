// wc -- count lines, words and characters. -l, -w, -c pick; the default is
// all three. A total follows more than one file.
package wc

import "vsys:abi"
import "vsys:libuser"

show_l, show_w, show_c: bool

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	for len(args) > 0 && len(args[0]) > 1 && args[0][0] == '-' {
		for i in 1 ..< len(args[0]) {
			switch args[0][i] {
			case 'l':
				show_l = true
			case 'w':
				show_w = true
			case 'c':
				show_c = true
			}
		}
		args = args[1:]
	}
	if !show_l && !show_w && !show_c {
		show_l, show_w, show_c = true, true, true
	}
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	status := ""
	tl, tw, tc: i64
	if len(args) == 0 {
		l, w, c := count(0)
		report(&out, l, w, c, "")
	}
	for name in args {
		fd := libuser.open(name, abi.O_RDONLY)
		if fd < 0 {
			libuser.eprint("wc: can't open ", name, ": ", libuser.errstr(fd), "\n")
			status = "can't open"
			continue
		}
		l, w, c := count(int(fd))
		libuser.close(int(fd))
		report(&out, l, w, c, name)
		tl += l
		tw += w
		tc += c
	}
	if len(args) > 1 {
		report(&out, tl, tw, tc, "total")
	}
	libuser.bio_flush(&out)
	libuser.exits(status)
}

count :: proc(fd: int) -> (lines, words, chars: i64) {
	buf: [8192]u8
	in_word := false
	for {
		n := libuser.read(fd, buf[:])
		if n <= 0 {
			break
		}
		chars += n
		for c in buf[:n] {
			if c == '\n' {
				lines += 1
			}
			if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
				in_word = false
			} else if !in_word {
				in_word = true
				words += 1
			}
		}
	}
	return
}

report :: proc(out: ^libuser.Bio, l, w, c: i64, name: string) {
	num: [24]u8
	if show_l {
		pad(out, libuser.itoa(num[:], l))
	}
	if show_w {
		pad(out, libuser.itoa(num[:], w))
	}
	if show_c {
		pad(out, libuser.itoa(num[:], c))
	}
	if len(name) > 0 {
		libuser.bio_putc(out, ' ')
		libuser.bio_puts(out, name)
	}
	libuser.bio_putc(out, '\n')
}

pad :: proc(out: ^libuser.Bio, s: string) {
	for _ in len(s) ..< 7 {
		libuser.bio_putc(out, ' ')
	}
	libuser.bio_puts(out, s)
}
