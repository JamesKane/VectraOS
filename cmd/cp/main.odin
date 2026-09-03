// cp -- copy a file to a file, or files into a directory.
package cp

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	if len(args) < 2 {
		libuser.eprint("usage: cp from ... to\n")
		libuser.exits("usage")
	}
	target := args[len(args) - 1]
	sources := args[:len(args) - 1]
	st: abi.Stat
	into_dir := libuser.stat(target, &st) == 0 && st.mode & abi.DMDIR != 0
	if len(sources) > 1 && !into_dir {
		libuser.eprint("cp: ", target, " is not a directory\n")
		libuser.exits("usage")
	}
	status := ""
	for src in sources {
		dst := target
		if into_dir {
			dst = join(target, basename(src))
		}
		if !copy_file(src, dst) {
			status = "copy failed"
		}
	}
	libuser.exits(status)
}

copy_file :: proc(src, dst: string) -> bool {
	in_fd := libuser.open(src, abi.O_RDONLY)
	if in_fd < 0 {
		libuser.eprint("cp: can't open ", src, ": ", libuser.errstr(in_fd), "\n")
		return false
	}
	defer libuser.close(int(in_fd))
	out_fd := libuser.open(dst, abi.O_WRONLY | abi.O_TRUNC)
	if out_fd < 0 {
		out_fd = libuser.create(dst, abi.O_WRONLY, 0o666)
	}
	if out_fd < 0 {
		libuser.eprint("cp: can't create ", dst, ": ", libuser.errstr(out_fd), "\n")
		return false
	}
	defer libuser.close(int(out_fd))
	buf: [8192]u8
	for {
		n := libuser.read(int(in_fd), buf[:])
		if n < 0 {
			libuser.eprint("cp: error reading ", src, "\n")
			return false
		}
		if n == 0 {
			return true
		}
		if !libuser.write_full(int(out_fd), buf[:n]) {
			libuser.eprint("cp: error writing ", dst, "\n")
			return false
		}
	}
}

basename :: proc(path: string) -> string {
	end := len(path)
	for end > 1 && path[end - 1] == '/' {
		end -= 1
	}
	start := 0
	for i in 0 ..< end {
		if path[i] == '/' {
			start = i + 1
		}
	}
	return path[start:end]
}

join :: proc(dir, name: string) -> string {
	out := make([]u8, len(dir) + 1 + len(name))
	copy(out, dir)
	out[len(dir)] = '/'
	copy(out[len(dir) + 1:], name)
	return string(out)
}
