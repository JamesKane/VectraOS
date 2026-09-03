// sort -- sort lines. -r reverses, -n compares leading numbers, -u drops
// repeats. Files, or standard input.
package sort

import "vsys:abi"
import "vsys:libuser"

reverse, numeric, unique: bool

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	for len(args) > 0 && len(args[0]) > 1 && args[0][0] == '-' {
		for i in 1 ..< len(args[0]) {
			switch args[0][i] {
			case 'r':
				reverse = true
			case 'n':
				numeric = true
			case 'u':
				unique = true
			}
		}
		args = args[1:]
	}
	lines := make([dynamic]string)
	status := ""
	if len(args) == 0 {
		gather(0, &lines)
	}
	for name in args {
		fd := libuser.open(name, abi.O_RDONLY)
		if fd < 0 {
			libuser.eprint("sort: can't open ", name, ": ", libuser.errstr(fd), "\n")
			status = "can't open"
			continue
		}
		gather(int(fd), &lines)
		libuser.close(int(fd))
	}
	merge_sort(lines[:])
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	for line, i in lines {
		if unique && i > 0 && line == lines[i - 1] {
			continue
		}
		libuser.bio_puts(&out, line)
		libuser.bio_putc(&out, '\n')
	}
	libuser.bio_flush(&out)
	libuser.exits(status)
}

gather :: proc(fd: int, lines: ^[dynamic]string) {
	data, ok := libuser.read_all(fd, context.allocator)
	if !ok {
		return
	}
	start_at := 0
	for c, i in data {
		if c == '\n' {
			append(lines, string(data[start_at:i]))
			start_at = i + 1
		}
	}
	if start_at < len(data) {
		append(lines, string(data[start_at:]))
	}
}

less :: proc(a, b: string) -> bool {
	r := false
	if numeric {
		x, _ := leading(a)
		y, _ := leading(b)
		r = x != y ? x < y : a < b
	} else {
		r = a < b
	}
	return reverse ? !r && a != b : r
}

// leading is the number a line starts with, after blanks.
leading :: proc(s: string) -> (v: i64, ok: bool) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	neg := false
	if i < len(s) && s[i] == '-' {
		neg = true
		i += 1
	}
	digits := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + i64(s[i] - '0')
		i += 1
		digits += 1
	}
	return neg ? -v : v, digits > 0
}

merge_sort :: proc(a: []string) {
	if len(a) < 2 {
		return
	}
	tmp := make([]string, len(a))
	defer delete(tmp)
	sort_into(a, tmp)
}

sort_into :: proc(a: []string, tmp: []string) {
	if len(a) < 2 {
		return
	}
	mid := len(a) / 2
	sort_into(a[:mid], tmp[:mid])
	sort_into(a[mid:], tmp[mid:])
	i, j, k := 0, mid, 0
	for i < mid && j < len(a) {
		if less(a[j], a[i]) {
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
