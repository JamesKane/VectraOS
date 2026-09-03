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
	for len(args) > 0 && len(args[0]) > 1 && args[0][0] == '-' {
		for i in 1 ..< len(args[0]) {
			switch args[0][i] {
			case 'l':
				long = true
			case 'd':
				dir_itself = true
			case 'p':
				plain = true
			}
		}
		args = args[1:]
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
	names := make([dynamic]string)
	entries: [16]abi.Dirent
	for {
		n := libuser.dirread(int(fd), entries[:])
		if n <= 0 {
			break
		}
		for i in 0 ..< int(n) {
			e := &entries[i]
			name := make([]u8, int(e.name_len))
			copy(name, e.name[:e.name_len])
			append(&names, string(name))
		}
	}
	libuser.close(int(fd))
	sort_names(names[:])
	for name in names {
		full := name
		if !bare {
			joined := make([]u8, len(path) + 1 + len(name))
			copy(joined, path)
			joined[len(path)] = '/'
			copy(joined[len(path) + 1:], name)
			full = string(joined)
		}
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
		libuser.bio_puts(out, mode_string(st.mode))
		libuser.bio_putc(out, ' ')
		num: [24]u8
		s := libuser.itoa(num[:], i64(st.length))
		for _ in len(s) ..< 8 {
			libuser.bio_putc(out, ' ')
		}
		libuser.bio_puts(out, s)
		libuser.bio_putc(out, ' ')
	}
	name := path
	if plain {
		start_at := 0
		for i in 0 ..< len(path) {
			if path[i] == '/' && i + 1 < len(path) {
				start_at = i + 1
			}
		}
		name = path[start_at:]
	}
	libuser.bio_puts(out, name)
	libuser.bio_putc(out, '\n')
}

// mode_string is Plan 9's: `d` or `-`, then rwx three times.
mode_string :: proc(mode: u32) -> string {
	buf := make([]u8, 10)
	buf[0] = mode & abi.DMDIR != 0 ? 'd' : '-'
	bits := "rwxrwxrwx"
	for i in 0 ..< 9 {
		buf[1 + i] = mode & (1 << u32(8 - i)) != 0 ? bits[i] : '-'
	}
	return string(buf)
}

sort_names :: proc(list: []string) {
	for i in 1 ..< len(list) {
		for j := i; j > 0 && list[j] < list[j - 1]; j -= 1 {
			list[j], list[j - 1] = list[j - 1], list[j]
		}
	}
}
