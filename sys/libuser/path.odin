/*
What every tool does to a path and a directory, written once.

Five tools joined a directory and a name, four took the last element of a
path, three read a directory into a list of names, two sorted one, and
five opened a file for writing by trying `O_TRUNC` and then `create`. Each
was a dozen lines the next tool copied. These are those lines.
*/
package libuser

import "base:runtime"

import "vsys:abi"

// basename is the last element of a path, trailing slashes ignored: `c` of
// `/a/b/c/`, `/` of `/`.
basename :: proc "contextless" (path: string) -> string {
	end := len(path)
	for end > 1 && path[end - 1] == '/' {
		end -= 1
	}
	start := 0
	for i in 0 ..< end {
		if path[i] == '/' && i + 1 < end {
			start = i + 1
		}
	}
	return path[start:end]
}

// join is `dir/name`, from `allocator`, with no doubled slash.
join :: proc(dir, name: string, allocator := context.allocator) -> string {
	if len(dir) == 0 {
		return name
	}
	slash := dir[len(dir) - 1] != '/'
	out := make([]u8, len(dir) + (slash ? 1 : 0) + len(name), allocator)
	n := copy(out, dir)
	if slash {
		out[n] = '/'
		n += 1
	}
	copy(out[n:], name)
	return string(out)
}

// cat_into writes its pieces into `buf` one after another and answers what
// fits: a path built from a prefix, a pid and a file name, with no
// arithmetic on literal lengths.
cat_into :: proc "contextless" (buf: []u8, parts: ..string) -> string {
	n := 0
	for p in parts {
		n += copy(buf[n:], p)
	}
	return string(buf[:n])
}

// list_dir reads an open directory to its end and answers the names, each
// from `allocator`. The order is the server's.
list_dir :: proc(fd: int, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 16, allocator)
	entries: [16]abi.Dirent
	for {
		n := dirread(fd, entries[:])
		if n <= 0 {
			break
		}
		for i in 0 ..< int(n) {
			e := &entries[i]
			name := make([]u8, int(e.name_len), allocator)
			copy(name, e.name[:e.name_len])
			append(&out, string(name))
		}
	}
	return out[:]
}

// sort_strings sorts in place, a merge sort with one scratch slice from
// `allocator`: a directory of a thousand names is a thousand compares
// times ten, not times a thousand.
sort_strings :: proc(list: []string, allocator := context.allocator) {
	if len(list) < 2 {
		return
	}
	tmp := make([]string, len(list), allocator)
	defer delete(tmp, allocator)
	merge_strings(list, tmp)
}

@(private = "file")
merge_strings :: proc(a: []string, tmp: []string) {
	if len(a) < 2 {
		return
	}
	mid := len(a) / 2
	merge_strings(a[:mid], tmp[:mid])
	merge_strings(a[mid:], tmp[mid:])
	i, j, k := 0, mid, 0
	for i < mid && j < len(a) {
		if a[j] < a[i] {
			tmp[k] = a[j]
			j += 1
		} else {
			tmp[k] = a[i]
			i += 1
		}
		k += 1
	}
	for i < mid {
		tmp[k] = a[i]
		i += 1
		k += 1
	}
	for j < len(a) {
		tmp[k] = a[j]
		j += 1
		k += 1
	}
	copy(a, tmp[:len(a)])
}

// open_or_create opens a file for writing, emptied, or makes it: what `>`
// means. `flags` is O_WRONLY or O_RDWR.
open_or_create :: proc "contextless" (path: string, flags: u64, mode: u64 = 0o666) -> i64 {
	fd := open(path, flags | abi.O_TRUNC)
	if fd < 0 {
		fd = create(path, flags, mode)
	}
	return fd
}

// open_append opens a file for writing at its end, or makes it: `>>`.
open_append :: proc "contextless" (path: string, mode: u64 = 0o666) -> i64 {
	fd := open(path, abi.O_WRONLY)
	if fd < 0 {
		return create(path, abi.O_WRONLY, mode)
	}
	st: abi.Stat
	if fstat(int(fd), &st) == 0 {
		seek(int(fd), st.length)
	}
	return fd
}

/*
letters takes the leading `-abc` flag words off an argument list and answers
their letters as one string in `buf`, with what follows. A tool with only
single-letter flags is then a `for c in letters` over a switch. A word that
is just `-` or that takes a value is the tool's own to handle first.
*/
letters :: proc "contextless" (args: []string, buf: []u8) -> (flags: string, rest: []string) {
	rest = args
	n := 0
	for len(rest) > 0 && len(rest[0]) > 1 && rest[0][0] == '-' {
		for i in 1 ..< len(rest[0]) {
			if n < len(buf) {
				buf[n] = rest[0][i]
				n += 1
			}
		}
		rest = rest[1:]
	}
	return string(buf[:n]), rest
}

// read_dir is `list_dir` of a named directory; nil when it cannot be opened.
read_dir :: proc(path: string, allocator := context.allocator) -> (names: []string, ok: bool) {
	fd := open(path, abi.O_RDONLY)
	if fd < 0 {
		return nil, false
	}
	defer close(int(fd))
	return list_dir(int(fd), allocator), true
}

_ :: runtime
