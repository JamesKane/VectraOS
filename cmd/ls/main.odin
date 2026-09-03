/*
ls -- list files. Names alone, or with -l each file's mode, size and name.
-d lists a directory as itself rather than its contents. -p prints the
last element of each path only.
*/
package ls

import "vsys:abi"
import "vsys:libuser"

long, dir_itself, plain: bool
status := ""

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	flag_buf: [8]u8
	letters, rest := libuser.letters(args, flag_buf[:])
	args = rest
	for c in transmute([]u8)letters {
		switch c {
		case 'l':
			long = true
		case 'd':
			dir_itself = true
		case 'p':
			plain = true
		}
	}
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	if len(args) == 0 {
		list(&out, ".", true)
	}
	for name in args {
		list(&out, name, false)
	}
	libuser.bio_flush(&out)
	libuser.exits(status)
}

list :: proc(out: ^libuser.Bio, path: string, bare: bool) {
	st: abi.Stat
	if r := libuser.stat(path, &st); r < 0 {
		libuser.eprint("ls: ", path, ": ", libuser.errstr(r), "\n")
		status = "can't stat"
		return
	}
	if st.mode & abi.DMDIR == 0 || dir_itself {
		entry(out, path, &st)
		return
	}
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		libuser.eprint("ls: can't open ", path, "\n")
		status = "can't open"
		return
	}
	names := libuser.list_dir(int(fd))
	libuser.close(int(fd))
	libuser.sort_strings(names)
	for name in names {
		full := bare ? name : libuser.join(path, name)
		if long {
			cst: abi.Stat
			if libuser.stat(full, &cst) == 0 {
				entry(out, full, &cst)
				continue
			}
		}
		entry(out, full, nil)
	}
}

entry :: proc(out: ^libuser.Bio, path: string, st: ^abi.Stat) {
	if long && st != nil {
		mode: [10]u8
		libuser.bio_puts(out, mode_string(mode[:], st.mode))
		libuser.bio_putc(out, ' ')
		num: [24]u8
		s := libuser.itoa(num[:], i64(st.length))
		for _ in len(s) ..< 8 {
			libuser.bio_putc(out, ' ')
		}
		libuser.bio_puts(out, s)
		libuser.bio_putc(out, ' ')
	}
	libuser.bio_puts(out, plain ? libuser.basename(path) : path)
	libuser.bio_putc(out, '\n')
}

// mode_string is Plan 9's: `d` or `-`, then rwx three times, into the
// caller's ten bytes.
mode_string :: proc(buf: []u8, mode: u32) -> string {
	buf[0] = mode & abi.DMDIR != 0 ? 'd' : '-'
	bits := "rwxrwxrwx"
	for i in 0 ..< 9 {
		buf[1 + i] = mode & (1 << u32(8 - i)) != 0 ? bits[i] : '-'
	}
	return string(buf[:10])
}
