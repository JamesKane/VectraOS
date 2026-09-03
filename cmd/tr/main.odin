// tr -- translate characters: `tr set1 set2` maps each of set1 to the
// corresponding one of set2, `tr -d set1` deletes them. Sets take ranges
// like `a-z`, and set2 extends with its last character.
package tr

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	del := false
	if len(args) > 0 && args[0] == "-d" {
		del = true
		args = args[1:]
	}
	if len(args) < 1 || (!del && len(args) < 2) {
		libuser.eprint("usage: tr [-d] set1 [set2]\n")
		libuser.exits("usage")
	}
	from := expand(args[0])
	to: []u8
	if !del {
		to = expand(args[1])
	}
	table: [256]u8
	drop: [256]bool
	for i in 0 ..< 256 {
		table[i] = u8(i)
	}
	for c, i in from {
		if del {
			drop[c] = true
		} else if len(to) > 0 {
			table[c] = i < len(to) ? to[i] : to[len(to) - 1]
		}
	}
	buf: [8192]u8
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	for {
		n := libuser.read(0, buf[:])
		if n <= 0 {
			break
		}
		for c in buf[:n] {
			if drop[c] {
				continue
			}
			libuser.bio_putc(&out, table[c])
		}
	}
	libuser.bio_flush(&out)
	libuser.exits("")
}

expand :: proc(set: string) -> []u8 {
	out := make([dynamic]u8, 0, len(set))
	i := 0
	for i < len(set) {
		c := set[i]
		if c == '\\' && i + 1 < len(set) {
			i += 1
			switch set[i] {
			case 'n':
				c = '\n'
			case 't':
				c = '\t'
			case:
				c = set[i]
			}
			append(&out, c)
			i += 1
			continue
		}
		if i + 2 < len(set) && set[i + 1] == '-' {
			hi := set[i + 2]
			for k := int(c); k <= int(hi); k += 1 {
				append(&out, u8(k))
			}
			i += 3
			continue
		}
		append(&out, c)
		i += 1
	}
	return out[:]
}
