// env -- print the environment: one `name=value` per line, a list's
// elements separated by spaces.
package env

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	_ = libuser.args(block)
	fd := libuser.open("/env", abi.O_RDONLY)
	if fd < 0 {
		libuser.eprint("env: can't open /env\n")
		libuser.exits("can't open")
	}
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	entries: [16]abi.Dirent
	path: [80]u8
	copy(path[:], "/env/")
	for {
		n := libuser.dirread(int(fd), entries[:])
		if n <= 0 {
			break
		}
		for i in 0 ..< int(n) {
			e := &entries[i]
			name := string(e.name[:e.name_len])
			copy(path[5:], name)
			data, ok := libuser.read_file(string(path[:5 + len(name)]), context.allocator)
			if !ok {
				continue
			}
			for &c in data {
				if c == 0 {
					c = ' '
				}
			}
			libuser.bio_puts(&out, name)
			libuser.bio_putc(&out, '=')
			libuser.bio_write(&out, data)
			libuser.bio_putc(&out, '\n')
			delete(data)
		}
	}
	libuser.close(int(fd))
	libuser.bio_flush(&out)
	libuser.exits("")
}
