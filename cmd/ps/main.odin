// ps -- list the processes, from /proc: pid, state and name, one per line.
package ps

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	_ = libuser.args(block)
	fd := libuser.open("/proc", abi.O_RDONLY)
	if fd < 0 {
		libuser.eprint("ps: can't open /proc: ", libuser.errstr(fd), "\n")
		libuser.exits("can't open")
	}
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	entries: [16]abi.Dirent
	path: [64]u8
	for {
		n := libuser.dirread(int(fd), entries[:])
		if n <= 0 {
			break
		}
		for i in 0 ..< int(n) {
			e := &entries[i]
			pid := string(e.name[:e.name_len])
			copy(path[:], "/proc/")
			copy(path[6:], pid)
			copy(path[6 + len(pid):], "/status")
			data, ok := libuser.read_file(string(path[:13 + len(pid)]), context.allocator)
			if !ok {
				continue
			}
			// name pid parent state group held cwd
			fields: [8]string
			count := split_fields(string(data), fields[:])
			if count >= 4 {
				pad(&out, fields[1], 6)
				libuser.bio_putc(&out, ' ')
				pad(&out, fields[3], 8)
				libuser.bio_putc(&out, ' ')
				// The name is the path the program was started from; the
				// last element is what a person calls it.
				libuser.bio_puts(&out, basename(fields[0]))
				libuser.bio_putc(&out, '\n')
			}
			delete(data)
		}
	}
	libuser.close(int(fd))
	libuser.bio_flush(&out)
	libuser.exits("")
}

basename :: proc(path: string) -> string {
	start_at := 0
	for i in 0 ..< len(path) {
		if path[i] == '/' && i + 1 < len(path) {
			start_at = i + 1
		}
	}
	return path[start_at:]
}

split_fields :: proc(s: string, out: []string) -> int {
	n := 0
	start_at := -1
	for i in 0 ..= len(s) {
		blank := i == len(s) || s[i] == ' ' || s[i] == '\n'
		if blank {
			if start_at >= 0 && n < len(out) {
				out[n] = s[start_at:i]
				n += 1
			}
			start_at = -1
		} else if start_at < 0 {
			start_at = i
		}
	}
	return n
}

pad :: proc(out: ^libuser.Bio, s: string, width: int) {
	libuser.bio_puts(out, s)
	for _ in len(s) ..< width {
		libuser.bio_putc(out, ' ')
	}
}
