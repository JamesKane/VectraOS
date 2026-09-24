/*
recycler -- where a deleted file goes, `docs/CHROME.md` section 6.

`Delete...` moves a file to `$home/lib/wb/recycler` in place of removing it.
So a delete on the desktop can be taken back: open the Recycler and drag the
file out. `Empty Recycler`, on the Workbench menu, removes what is in it, a
drawer and all it holds. A delete of something already in the Recycler
removes it at once, as there is nowhere further for it to go. A `rm` at a
shell is still a remove, and the Recycler is the desktop's alone.

The move is a rename when the file and the Recycler are on one server, which
keeps a drawer whole. Across servers a file is copied and removed, and a
drawer is refused. A move of one is a recursion this cut does not do.
A name the Recycler already holds takes a number, `notes.2`, so a second
delete of a file of the same name keeps the first.
*/
package workbench

import "vsys:abi"
import "vsys:libmui"
import "vsys:libuser"

@(private = "file")
recycler_buf: [160]u8

// recycler_path is `$home/lib/wb/recycler`.
recycler_path :: proc "contextless" () -> string {
	return libuser.cat_into(recycler_buf[:], home_path(), "/lib/wb/recycler")
}

// recycler_make makes the Recycler and the directories over it, if they are
// not there. False when it cannot be had.
recycler_make :: proc "contextless" () -> bool {
	pb: [160]u8
	home := home_path()
	_ = libuser.mkdir(libuser.cat_into(pb[:], home, "/lib"))
	_ = libuser.mkdir(libuser.cat_into(pb[:], home, "/lib/wb"))
	_ = libuser.mkdir(recycler_path())
	st: abi.Stat
	return libuser.stat(recycler_path(), &st) == 0
}

// in_recycler answers whether a path is in the Recycler, or is it.
in_recycler :: proc "contextless" (path: string) -> bool {
	r := recycler_path()
	return path == r || has_prefix(path, r) && len(path) > len(r) && path[len(r)] == '/'
}

/*
recycle moves `path` into the Recycler, or removes it when it is there
already. False, with the file left where it was, when it could do neither.
*/
recycle :: proc "contextless" (path: string, kind: u8) -> bool {
	context = wb_ctx
	if in_recycler(path) {
		return remove_tree(path)
	}
	if !recycler_make() {
		return false
	}
	name := base_name(path)
	tb: [256]u8
	target := libuser.cat_into(tb[:], recycler_path(), "/", name)
	st: abi.Stat
	nb: [24]u8
	for k := 2; libuser.stat(target, &st) == 0 && k < 1000; k += 1 {
		target = libuser.cat_into(tb[:], recycler_path(), "/", name, ".", libuser.itoa(nb[:], i64(k)))
	}
	if libuser.rename(path, target) == 0 {
		return true
	}
	// Across servers: a file is copied and removed, and a drawer stays.
	if kind == libmui.ICON_DRAWER {
		return false
	}
	return move_file(path, target)
}

/*
remove_tree removes a file, or a directory and everything under it,
deepest first. False when anything would not go, though what would goes.
*/
remove_tree :: proc "contextless" (path: string) -> bool {
	context = wb_ctx
	st: abi.Stat
	if libuser.stat(path, &st) < 0 {
		return false
	}
	ok := true
	if st.mode & abi.DMDIR != 0 || st.qid_kind & abi.QTDIR != 0 {
		if fd := libuser.open(path, abi.O_RDONLY); fd >= 0 {
			names := libuser.list_dir(int(fd))
			_ = libuser.close(int(fd))
			for name in names {
				child := libuser.join(path, name)
				if !remove_tree(child) {
					ok = false
				}
				delete(child)
			}
			delete(names)
		}
	}
	if libuser.remove(path) < 0 {
		ok = false
	}
	return ok
}

// recycler_empty removes everything in the Recycler and keeps the Recycler.
recycler_empty :: proc "contextless" () -> bool {
	context = wb_ctx
	fd := libuser.open(recycler_path(), abi.O_RDONLY)
	if fd < 0 {
		return true
	}
	names := libuser.list_dir(int(fd))
	_ = libuser.close(int(fd))
	ok := true
	for name in names {
		child := libuser.join(recycler_path(), name)
		if !remove_tree(child) {
			ok = false
		}
		delete(child)
	}
	delete(names)
	return ok
}
