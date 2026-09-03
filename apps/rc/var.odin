/*
Variables, and the directory they are.

A variable is a list of strings, kept here and mirrored in `/env`, so a
program rc starts sees what rc set: the kernel copies the environment
group into every child. Plan 9 writes the list as its elements separated
by NUL, and so does this, and reads them back the same way at startup.

`$*` and `$0`, `$status` and `$apid` are rc's own and stay out of `/env`.
So does anything whose name is not a name: `$1` is `$*(1)` and no file.
*/
package rc

import "vsys:abi"
import "vsys:libuser"

// lookup answers a variable's list, `$*` and `$n` included. The slice is
// the table's own and must not be kept across a set.
lookup :: proc(sh: ^Shell, name: string) -> []string {
	switch name {
	case "*":
		return sh.argv
	case "0":
		out := make([]string, 1, sh.temp)
		out[0] = sh.arg0
		return out
	case "status":
		out := make([]string, 1, sh.temp)
		out[0] = status(sh)
		return out
	}
	if n, ok := atoi(name); ok && n > 0 {
		if n <= len(sh.argv) {
			out := make([]string, 1, sh.temp)
			out[0] = sh.argv[n - 1]
			return out
		}
		return nil
	}
	if i := find_var(sh, name); i >= 0 {
		return sh.vars[i].list
	}
	return nil
}

/*
set_var replaces a variable with a copy of `list`, on the heap. An empty
list removes it, from `/env` at once; a value waits, marked, for `updenv`
to write it before the next program starts, as Plan 9's rc does. A loop
that sets its variable a thousand times then costs the kernel nothing, and
a program still sees what the shell set.
*/
set_var :: proc(sh: ^Shell, name: string, list: []string) {
	if name == "*" {
		set_argv(sh, list)
		return
	}
	if set_local(sh, name, list) {
		export(name, nil)
	}
}

// set_local is the table's half of a set: the copy before the free, because
// `x=($x more)` names the old value in the new, and the removal of an
// emptied variable. Answers whether a variable was removed.
set_local :: proc(sh: ^Shell, name: string, list: []string) -> (removed: bool) {
	fresh := clone_list(list)
	if i := find_var(sh, name); i >= 0 {
		free_list(sh.vars[i].list)
		if len(fresh) > 0 {
			sh.vars[i].list = fresh
			sh.vars[i].dirty = true
			return false
		}
		delete(sh.vars[i].name)
		unordered_remove(&sh.vars, i)
		return true
	}
	if len(fresh) > 0 {
		append(&sh.vars, Var_Entry{name = clone(name), list = fresh, dirty = true})
	}
	return false
}

// updenv writes every variable set since the last time to `/env`, before
// a program is started that would read it.
updenv :: proc(sh: ^Shell) {
	for &e in sh.vars {
		if e.dirty {
			export(e.name, e.list)
			e.dirty = false
		}
	}
}

set_argv :: proc(sh: ^Shell, list: []string) {
	fresh := clone_list(list)
	free_list(sh.argv)
	sh.argv = fresh
}

// clone_list copies a list onto the heap.
clone_list :: proc(list: []string) -> []string {
	if len(list) == 0 {
		return nil
	}
	out := make([]string, len(list))
	for s, i in list {
		out[i] = clone(s)
	}
	return out
}

free_list :: proc(list: []string) {
	for s in list {
		delete(s)
	}
	delete(list)
}

clone :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

// exportable says whether a variable is `/env`'s business.
@(private = "file")
exportable :: proc(name: string) -> bool {
	switch name {
	case "*", "0", "status", "apid", "bqstatus", "pid":
		return false
	}
	if _, numeric := atoi(name); numeric {
		return false
	}
	return valid_name(name)
}

// export writes a variable to `/env`, its elements separated by NUL, or
// removes the file for an empty list.
@(private = "file")
export :: proc(name: string, list: []string) {
	if !exportable(name) {
		return
	}
	path_buf: [80]u8
	path := libuser.cat_into(path_buf[:], "/env/", name)
	if len(list) == 0 {
		libuser.remove(path)
		return
	}
	fd := libuser.open_or_create(path, abi.O_WRONLY)
	if fd < 0 {
		return
	}
	// One write: the elements with a NUL between each, built first.
	total := len(list) - 1
	for s in list {
		total += len(s)
	}
	value := make([]u8, total, context.temp_allocator)
	at := 0
	for s, i in list {
		if i > 0 {
			value[at] = 0
			at += 1
		}
		at += copy(value[at:], s)
	}
	libuser.write_full(int(fd), value)
	libuser.close(int(fd))
}

// import_env reads every variable in `/env` into the table, at startup.
import_env :: proc(sh: ^Shell) {
	fd := libuser.open("/env", abi.O_RDONLY)
	if fd < 0 {
		return
	}
	entries: [16]abi.Dirent
	for {
		n := libuser.dirread(int(fd), entries[:])
		if n <= 0 {
			break
		}
		for i in 0 ..< int(n) {
			e := &entries[i]
			name := string(e.name[:e.name_len])
			if !exportable(name) {
				continue
			}
			path_buf: [80]u8
			data, ok := libuser.read_file(libuser.cat_into(path_buf[:], "/env/", name), context.allocator)
			if !ok {
				continue
			}
			set_local(sh, name, split_nul(sh, string(data)))
			if vi := find_var(sh, name); vi >= 0 {
				sh.vars[vi].dirty = false // it came from /env; nothing to write back
			}
			delete(data)
		}
	}
	libuser.close(int(fd))
}

// split_nul is the inverse of export: elements separated by NUL, with one
// trailing NUL allowed for a value another program wrote.
@(private = "file")
split_nul :: proc(sh: ^Shell, data: string) -> []string {
	out := make([dynamic]string, 0, 4, sh.temp)
	start := 0
	for i in 0 ..= len(data) {
		if i == len(data) || data[i] == 0 {
			// A trailing NUL ends the last element rather than adding an
			// empty one; a value that is only a NUL is one empty element.
			lone_nul := len(data) > 0 && len(out) == 0 && i == len(data) && start == i
			if i > start || lone_nul {
				append(&out, data[start:i])
			}
			start = i + 1
		}
	}
	return out[:]
}
