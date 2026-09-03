/*
grep -- print the lines that match a pattern, from files or standard input.

    -c  count matching lines instead of printing them
    -i  ignore case
    -n  number the lines
    -s  say nothing about files that cannot be opened
    -v  print the lines that do not match

The pattern is `sys/libregex`'s dialect, which is Plan 9's. With more than
one file each line is prefixed by its file's name. The status is empty when
something matched, `no match` when nothing did.
*/
package grep

import "vsys:abi"
import "vsys:libregex"
import "vsys:libuser"

count_only, fold, number, silent, invert: bool

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	for len(args) > 0 && len(args[0]) > 1 && args[0][0] == '-' {
		for i in 1 ..< len(args[0]) {
			switch args[0][i] {
			case 'c':
				count_only = true
			case 'i':
				fold = true
			case 'n':
				number = true
			case 's':
				silent = true
			case 'v':
				invert = true
			}
		}
		args = args[1:]
	}
	if len(args) < 1 {
		libuser.eprint("usage: grep [-cinsv] pattern [file ...]\n")
		libuser.exits("usage")
	}
	re, ok := libregex.compile(args[0], fold, context.allocator)
	if !ok {
		libuser.eprint("grep: bad pattern ", args[0], "\n")
		libuser.exits("bad pattern")
	}
	files := args[1:]
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	matched := false
	if len(files) == 0 {
		matched = search(&out, re, 0, "", false) || matched
	}
	for name in files {
		fd := libuser.open(name, abi.O_RDONLY)
		if fd < 0 {
			if !silent {
				libuser.eprint("grep: can't open ", name, ": ", libuser.errstr(fd), "\n")
			}
			continue
		}
		matched = search(&out, re, int(fd), name, len(files) > 1) || matched
		libuser.close(int(fd))
	}
	libuser.bio_flush(&out)
	libuser.exits(matched ? "" : "no match")
}

search :: proc(out: ^libuser.Bio, re: ^libregex.Regex, fd: int, name: string, prefix: bool) -> bool {
	r: libuser.Reader
	libuser.reader_init(&r, fd)
	hits: i64 = 0
	line_no: i64 = 0
	num: [24]u8
	for {
		line, ok := libuser.read_line(&r)
		if !ok {
			break
		}
		line_no += 1
		_, _, hit := libregex.match(re, line)
		if hit == invert {
			continue
		}
		hits += 1
		if count_only {
			continue
		}
		if prefix {
			libuser.bio_puts(out, name)
			libuser.bio_putc(out, ':')
		}
		if number {
			libuser.bio_puts(out, libuser.itoa(num[:], line_no))
			libuser.bio_putc(out, ':')
		}
		libuser.bio_puts(out, line)
		libuser.bio_putc(out, '\n')
	}
	if count_only {
		if prefix {
			libuser.bio_puts(out, name)
			libuser.bio_putc(out, ':')
		}
		libuser.bio_puts(out, libuser.itoa(num[:], hits))
		libuser.bio_putc(out, '\n')
	}
	return hits > 0
}
