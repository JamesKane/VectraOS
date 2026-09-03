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
	path: [80]u8
	for name in libuser.list_dir(int(fd)) {
		data, ok := libuser.read_file(libuser.cat_into(path[:], "/env/", name), context.allocator)
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
	libuser.close(int(fd))
	libuser.bio_flush(&out)
	libuser.exits("")
}
