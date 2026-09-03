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

// set_var replaces a variable with a copy of `list`, on the heap, and
// writes it to `/env`. An empty list removes the variable, in both places.
set_var :: proc(sh: ^Shell, name: string, list: []string) {
	if name == "*" {
		set_argv(sh, list)
		return
	}
	// The copy before the free: `x=($x more)` names the old value in the new.
	fresh := clone_list(list)
	if i := find_var(sh, name); i >= 0 {
		free_list(sh.vars[i].list)
		if len(fresh) > 0 {
			sh.vars[i].list = fresh
		} else {
			delete(sh.vars[i].name)
			unordered_remove(&sh.vars, i)
		}
	} else if len(fresh) > 0 {
		append(&sh.vars, Var_Entry{name = clone(name), list = fresh})
	}
	export(name, fresh)
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
	path := env_path(path_buf[:], name)
	if len(list) == 0 {
		libuser.remove(path)
		return
	}
	fd := libuser.open(path, abi.O_WRONLY | abi.O_TRUNC)
	if fd < 0 {
		fd = libuser.create(path, abi.O_WRONLY, 0o666)
	}
	if fd < 0 {
		return
	}
	for s, i in list {
		if i > 0 {
			libuser.write_full(int(fd), []u8{0})
		}
		libuser.write_full(int(fd), transmute([]u8)s)
	}
	libuser.close(int(fd))
}

@(private = "file")
env_path :: proc(buf: []u8, name: string) -> string {
	copy(buf, "/env/")
	n := copy(buf[5:], name)
	return string(buf[:5 + n])
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
			data, ok := read_file(env_path(path_buf[:], name))
			if !ok {
				continue
			}
			list := split_nul(sh, string(data))
			if vi := find_var(sh, name); vi >= 0 {
				free_list(sh.vars[vi].list)
				delete(sh.vars[vi].name)
				unordered_remove(&sh.vars, vi)
			}
			if len(list) > 0 {
				append(&sh.vars, Var_Entry{name = clone(name), list = clone_list(list)})
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
			if i > start || (i == len(data) && i == start && len(out) == 0 && len(data) > 0) {
				append(&out, data[start:i])
			}
			start = i + 1
		}
	}
	return out[:]
}
