/*
What a word is worth: a list of strings.

Every word evaluates to a list. `$x` is the variable's list, `(a b)` is
two, `$#x` is one string with a count in it, and a plain word is a list
of one. Concatenation distributes: a list of one against a list of many
gives many, two lists of the same length pair off, and anything else is an
error. That rule is the whole of rc's list algebra.

Pattern characters travel through evaluation as GLOB marks in the text.
Whoever consumes the list decides: a simple command's arguments are
matched against the filesystem, a `~` or `case` pattern is matched
against a string, and everywhere else the marks are simply removed.

Everything here allocates from the temporary arena, which the main loop
resets after each line. A value that outlives a line is copied out by the
variable table.
*/
package rc

import "vsys:abi"
import "vsys:libfmt"
import "vsys:libuser"

// eval_word evaluates one word node to its list, marks kept.
eval_word :: proc(sh: ^Shell, n: ^Node) -> []string {
	if n == nil {
		return nil
	}
	#partial switch n.kind {
	case .Word:
		out := make([]string, 1, sh.temp)
		out[0] = n.text
		return out
	case .Paren:
		return eval_words(sh, n.list[:])
	case .Var:
		name := join(sh, eval_word(sh, n.a), " ")
		list := lookup(sh, strip_marks(name))
		if n.b != nil {
			return subscript(sh, list, eval_words(sh, n.b.list[:]))
		}
		return list
	case .Count:
		name := join(sh, eval_word(sh, n.a), " ")
		list := lookup(sh, strip_marks(name))
		out := make([]string, 1, sh.temp)
		out[0] = itoa(sh, len(list))
		return out
	case .Join:
		name := join(sh, eval_word(sh, n.a), " ")
		list := lookup(sh, strip_marks(name))
		out := make([]string, 1, sh.temp)
		out[0] = join(sh, list, " ")
		return out
	case .Concat:
		return concat(sh, eval_word(sh, n.a), eval_word(sh, n.b), n.line)
	case .Backquote:
		return backquote(sh, n.a)
	}
	return nil
}

// eval_words evaluates a list of words into one flat list.
eval_words :: proc(sh: ^Shell, words: []^Node) -> []string {
	out := make([dynamic]string, 0, len(words), sh.temp)
	for w in words {
		append(&out, ..eval_word(sh, w))
	}
	return out[:]
}

// eval_plain evaluates a word and strips its marks: a name, a file, a value.
eval_plain :: proc(sh: ^Shell, n: ^Node) -> []string {
	return strip_all(sh, eval_word(sh, n))
}

// strip_all is a list with every word's marks removed, as a new list.
strip_all :: proc(sh: ^Shell, list: []string) -> []string {
	out := make([]string, len(list), sh.temp)
	for s, i in list {
		out[i] = strip_marks(s)
	}
	return out
}

// search_path is `$path`, or Plan 9's default when nothing set one.
search_path :: proc(sh: ^Shell) -> []string {
	path := lookup(sh, "path")
	if len(path) == 0 {
		return DEFAULT_PATH[:]
	}
	return path
}

DEFAULT_PATH := [?]string{".", "/bin"}

// eval_args evaluates a simple command's words, matching each against the
// filesystem where it has pattern characters.
eval_args :: proc(sh: ^Shell, words: []^Node) -> []string {
	out := make([dynamic]string, 0, len(words), sh.temp)
	for w in words {
		for s in eval_word(sh, w) {
			if has_marks(s) {
				append(&out, ..glob(sh, s))
			} else {
				append(&out, s)
			}
		}
	}
	return out[:]
}

@(private = "file")
concat :: proc(sh: ^Shell, a, b: []string, line: int) -> []string {
	switch {
	case len(a) == len(b):
		out := make([]string, len(a), sh.temp)
		for i in 0 ..< len(a) {
			out[i] = cat2(sh, a[i], b[i])
		}
		return out
	case len(a) == 1:
		out := make([]string, len(b), sh.temp)
		for i in 0 ..< len(b) {
			out[i] = cat2(sh, a[0], b[i])
		}
		return out
	case len(b) == 1:
		out := make([]string, len(a), sh.temp)
		for i in 0 ..< len(a) {
			out[i] = cat2(sh, a[i], b[0])
		}
		return out
	}
	libfmt.fprint(2, "rc: line %d: mismatched list lengths in concatenation\n", line)
	sh.flag_error = true
	return nil
}

cat2 :: proc(sh: ^Shell, a, b: string) -> string {
	out := make([]u8, len(a) + len(b), sh.temp)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

join :: proc(sh: ^Shell, list: []string, sep: string) -> string {
	if len(list) == 0 {
		return ""
	}
	if len(list) == 1 {
		return list[0]
	}
	total := 0
	for s in list {
		total += len(s)
	}
	total += (len(list) - 1) * len(sep)
	out := make([]u8, total, sh.temp)
	at := 0
	for s, i in list {
		if i > 0 {
			copy(out[at:], sep)
			at += len(sep)
		}
		copy(out[at:], s)
		at += len(s)
	}
	return string(out)
}

itoa :: proc(sh: ^Shell, v: int) -> string {
	buf: [24]u8
	digits := libuser.itoa(buf[:], i64(v))
	out := make([]u8, len(digits), sh.temp)
	copy(out, digits)
	return string(out)
}

atoi :: proc(s: string) -> (v: int, ok: bool) {
	big, bok := libuser.atoi(s)
	return int(big), bok
}

/*
subscript picks elements by one-based index: `$x(1)`, `$x(3 1)`, and the
ranges `$x(2-4)`, `$x(2-)`, `$x(-3)`. An index off the end contributes
nothing, as in rc.
*/
@(private = "file")
subscript :: proc(sh: ^Shell, list: []string, indices: []string) -> []string {
	out := make([dynamic]string, 0, len(indices), sh.temp)
	for ix in indices {
		s := strip_marks(ix)
		dash := -1
		for i in 0 ..< len(s) {
			if s[i] == '-' {
				dash = i
				break
			}
		}
		lo, hi := 1, len(list)
		if dash < 0 {
			v, ok := atoi(s)
			if !ok {
				continue
			}
			lo, hi = v, v
		} else {
			if dash > 0 {
				v, ok := atoi(s[:dash])
				if !ok {
					continue
				}
				lo = v
			}
			if dash + 1 < len(s) {
				v, ok := atoi(s[dash + 1:])
				if !ok {
					continue
				}
				hi = v
			}
		}
		for i := max(lo, 1); i <= hi && i <= len(list); i += 1 {
			append(&out, list[i - 1])
		}
	}
	return out[:]
}

// -- Marks ----------------------------------------------------------------------

has_marks :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] == GLOB {
			return true
		}
	}
	return false
}

// strip_marks removes GLOB marks. Answers the string itself when there
// are none, and a copy on the temporary arena otherwise.
strip_marks :: proc(s: string) -> string {
	if !has_marks(s) {
		return s
	}
	out := make([]u8, len(s), context.temp_allocator)
	n := 0
	for i in 0 ..< len(s) {
		if s[i] != GLOB {
			out[n] = s[i]
			n += 1
		}
	}
	return string(out[:n])
}

/*
match is rc's pattern match: GLOB-marked `*` matches any run, `?` one
character, `[...]` one of a class with `~` negating and `a-z` ranging.
Unmarked characters match themselves, so a quoted `*` is literal. The
subject has no marks.
*/
match :: proc(pat: string, s: string) -> bool {
	p, i := 0, 0
	for p < len(pat) {
		c := pat[p]
		if c == GLOB && p + 1 < len(pat) {
			p += 1
			switch pat[p] {
			case '*':
				p += 1
				for k := i; k <= len(s); k += 1 {
					if match(pat[p:], s[k:]) {
						return true
					}
				}
				return false
			case '?':
				if i >= len(s) {
					return false
				}
				p += 1
				i += 1
				continue
			case '[':
				if i >= len(s) {
					return false
				}
				p += 1
				negate := false
				if p < len(pat) && pat[p] == '~' {
					negate = true
					p += 1
				}
				hit := false
				first := true
				for p < len(pat) && (pat[p] != ']' || first) {
					first = false
					lo := pat[p]
					hi := lo
					if p + 2 < len(pat) && pat[p + 1] == '-' && pat[p + 2] != ']' {
						hi = pat[p + 2]
						p += 2
					}
					if s[i] >= lo && s[i] <= hi {
						hit = true
					}
					p += 1
				}
				if p < len(pat) {
					p += 1 // the ]
				}
				if hit == negate {
					return false
				}
				i += 1
				continue
			}
			// A mark before anything else is a literal mark; fall through.
			p -= 1
			c = pat[p]
		}
		if i >= len(s) || s[i] != c {
			return false
		}
		p += 1
		i += 1
	}
	return i == len(s)
}

// match_any says whether any pattern in the list matches any subject.
match_any :: proc(patterns: []string, subjects: []string) -> bool {
	for pat in patterns {
		for s in subjects {
			if match(pat, s) {
				return true
			}
		}
	}
	return false
}

// -- Globbing ---------------------------------------------------------------------

/*
glob expands a marked word against the filesystem, component by component.
A component without marks is taken as written; one with them lists the
directory before it and keeps every matching name, sorted, skipping names
that start with `.` unless the pattern does. A word that matches nothing
is the word itself, marks removed, which is rc's rule and the one that
lets `rm *.tmp` say `no such file` rather than remove nothing silently.
*/
glob :: proc(sh: ^Shell, word: string) -> []string {
	out := make([dynamic]string, 0, 8, sh.temp)
	prefix := ""
	rest := word
	if len(rest) > 0 && rest[0] == '/' {
		prefix = "/"
		rest = rest[1:]
	}
	glob_walk(sh, prefix, rest, &out)
	if len(out) == 0 {
		single := make([]string, 1, sh.temp)
		single[0] = strip_marks(word)
		return single
	}
	return out[:]
}

@(private = "file")
glob_walk :: proc(sh: ^Shell, prefix: string, rest: string, out: ^[dynamic]string) {
	// Split off the next component.
	end := len(rest)
	for i in 0 ..< len(rest) {
		if rest[i] == '/' {
			end = i
			break
		}
	}
	comp := rest[:end]
	after := end < len(rest) ? rest[end + 1:] : ""
	last := end == len(rest)

	if !has_marks(comp) {
		path := path_join(sh, prefix, strip_marks(comp))
		if last {
			if len(prefix) == 0 || exists(path) {
				append(out, path)
			}
			return
		}
		glob_walk(sh, path, after, out)
		return
	}

	dir := len(prefix) == 0 ? "." : prefix
	names := list_dir(sh, dir)
	libuser.sort_strings(names, sh.temp)
	for name in names {
		if name[0] == '.' && (len(comp) < 2 || comp[0] != '.') {
			continue
		}
		if !match(comp, name) {
			continue
		}
		path := path_join(sh, prefix, name)
		if last {
			append(out, path)
		} else {
			glob_walk(sh, path, after, out)
		}
	}
}

path_join :: proc(sh: ^Shell, dir, name: string) -> string {
	return libuser.join(dir, name, sh.temp)
}

exists :: proc(path: string) -> bool {
	st: abi.Stat
	return libuser.stat(path, &st) == 0
}

// list_dir names everything in a directory, on the temporary arena.
list_dir :: proc(sh: ^Shell, dir: string) -> []string {
	names, _ := libuser.read_dir(dir, sh.temp)
	return names
}

// split_ifs breaks command output into words at the characters in $ifs,
// dropping empty words, which is how `{...} becomes a list.
split_ifs :: proc(sh: ^Shell, text: string) -> []string {
	ifs := join(sh, lookup(sh, "ifs"), "")
	if len(lookup(sh, "ifs")) == 0 {
		ifs = " \t\n"
	}
	out := make([dynamic]string, 0, 8, sh.temp)
	start := -1
	for i in 0 ..= len(text) {
		sep := i == len(text)
		if !sep {
			for k in 0 ..< len(ifs) {
				if text[i] == ifs[k] {
					sep = true
					break
				}
			}
		}
		if sep {
			if start >= 0 {
				append(&out, text[start:i])
				start = -1
			}
		} else if start < 0 {
			start = i
		}
	}
	return out[:]
}
