// mv -- move a file: a copy and a remove, because no server here renames
// yet. Into a directory when the target is one.
package mv

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	if len(args) < 2 {
		libuser.eprint("usage: mv from ... to\n")
		libuser.exits("usage")
	}
	target := args[len(args) - 1]
	sources := args[:len(args) - 1]
	st: abi.Stat
	into_dir := libuser.stat(target, &st) == 0 && st.mode & abi.DMDIR != 0
	if len(sources) > 1 && !into_dir {
		libuser.eprint("mv: ", target, " is not a directory\n")
		libuser.exits("usage")
	}
	status := ""
	for src in sources {
		dst := target
		if into_dir {
			dst = libuser.join(target, libuser.basename(src))
		}
		if !move(src, dst) {
			status = "move failed"
		}
	}
	libuser.exits(status)
}

move :: proc(src, dst: string) -> bool {
	// A rename first: the server keeps the file and moves the entry, which
	// is instant and keeps the qid. Two answers mean `copy instead`: EXDEV,
	// the names are on different servers; and EOPNOTSUPP, a server that
	// does not rename at all, which memfs and the static tree still are.
	// Any other refusal is the server's word and stands.
	renamed := libuser.rename(src, dst)
	if renamed == 0 {
		return true
	}
	if renamed != -i64(vectra9.EXDEV) && renamed != -i64(vectra9.EOPNOTSUPP) {
		libuser.eprint("mv: can't move ", src, " to ", dst, ": ", libuser.errstr(renamed), "\n")
		return false
	}
	data, ok := libuser.read_file(src, context.allocator)
	if !ok {
		libuser.eprint("mv: can't read ", src, "\n")
		return false
	}
	defer delete(data)
	out_fd := libuser.open_or_create(dst, abi.O_WRONLY)
	if out_fd < 0 {
		libuser.eprint("mv: can't create ", dst, ": ", libuser.errstr(out_fd), "\n")
		return false
	}
	wrote := libuser.write_full(int(out_fd), data)
	libuser.close(int(out_fd))
	if !wrote {
		libuser.eprint("mv: error writing ", dst, "\n")
		return false
	}
	if r := libuser.remove(src); r < 0 {
		libuser.eprint("mv: can't remove ", src, ": ", libuser.errstr(r), "\n")
		return false
	}
	return true
}


