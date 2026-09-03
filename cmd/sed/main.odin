/*
sed -- edit a stream, one line at a time, by a script of commands.

    sed [-n] [-e script] ... [script] [file ...]

    [addr[,addr]]p        print the line
    [addr[,addr]]d        delete it; the next line starts the script over
    [addr]q               print (unless -n) and stop
    [addr[,addr]]s/re/repl/[g][p]
                          substitute; `&` in repl is the match, `\/` a slash
    !                     after an address: the lines it does not name

An address is a line number, `$` for the last line, or `/re/`. Without -n
every line is printed after the script ran over it. Enough of sed for a
build script and a `s///` at a prompt; the rest waits for a reason.
*/
package sed

import "vsys:abi"
import "vsys:libregex"
import "vsys:libuser"

Addr_Kind :: enum u8 {
	None,
	Line,
	Last,
	Regex,
}

Addr :: struct {
	kind: Addr_Kind,
	line: i64,
	re:   ^libregex.Regex,
}

Command :: struct {
	a1, a2:  Addr,
	negate:  bool,
	op:      u8, // 'p' 'd' 'q' 's'
	re:      ^libregex.Regex, // s
	repl:    string, // s
	global:  bool, // s///g
	print:   bool, // s///p
	// A range is live from the line a1 matched until a2 matches.
	in_range: bool,
}

commands: [dynamic]Command
quiet: bool

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	commands = make([dynamic]Command)
	scripted := false
	for len(args) > 0 && len(args[0]) > 1 && args[0][0] == '-' {
		switch args[0] {
		case "-n":
			quiet = true
			args = args[1:]
		case "-e":
			if len(args) < 2 {
				usage()
			}
			parse_script(args[1])
			scripted = true
			args = args[2:]
		case:
			usage()
		}
	}
	if !scripted {
		if len(args) == 0 {
			usage()
		}
		parse_script(args[0])
		args = args[1:]
	}
	out: libuser.Bio
	libuser.bio_init(&out, 1)
	status := ""
	if len(args) == 0 {
		edit(&out, 0)
	}
	for name in args {
		fd := libuser.open(name, abi.O_RDONLY)
		if fd < 0 {
			libuser.eprint("sed: can't open ", name, ": ", libuser.errstr(fd), "\n")
			status = "can't open"
			continue
		}
		edit(&out, int(fd))
		libuser.close(int(fd))
	}
	libuser.bio_flush(&out)
	libuser.exits(status)
}

usage :: proc() -> ! {
	libuser.eprint("usage: sed [-n] [-e script] ... [script] [file ...]\n")
	libuser.exits("usage")
}

// -- The script -----------------------------------------------------------------------

Script :: struct {
	text: string,
	pos:  int,
}

parse_script :: proc(text: string) {
	s := Script{text = text}
	for {
		skip_blanks(&s)
		if s.pos >= len(s.text) {
			return
		}
		c := s.text[s.pos]
		if c == ';' || c == '\n' {
			s.pos += 1
			continue
		}
		cmd: Command
		cmd.a1 = parse_addr(&s)
		if s.pos < len(s.text) && s.text[s.pos] == ',' {
			s.pos += 1
			cmd.a2 = parse_addr(&s)
		}
		skip_blanks(&s)
		if s.pos < len(s.text) && s.text[s.pos] == '!' {
			cmd.negate = true
			s.pos += 1
			skip_blanks(&s)
		}
		if s.pos >= len(s.text) {
			bad("missing command")
		}
		cmd.op = s.text[s.pos]
		s.pos += 1
		switch cmd.op {
		case 'p', 'd', 'q':
		case 's':
			parse_subst(&s, &cmd)
		case:
			bad("unknown command")
		}
		append(&commands, cmd)
	}
}

skip_blanks :: proc(s: ^Script) {
	for s.pos < len(s.text) && (s.text[s.pos] == ' ' || s.text[s.pos] == '\t') {
		s.pos += 1
	}
}

parse_addr :: proc(s: ^Script) -> Addr {
	skip_blanks(s)
	if s.pos >= len(s.text) {
		return Addr{}
	}
	c := s.text[s.pos]
	switch {
	case c == '$':
		s.pos += 1
		return Addr{kind = .Last}
	case c >= '0' && c <= '9':
		v: i64
		for s.pos < len(s.text) && s.text[s.pos] >= '0' && s.text[s.pos] <= '9' {
			v = v * 10 + i64(s.text[s.pos] - '0')
			s.pos += 1
		}
		return Addr{kind = .Line, line = v}
	case c == '/':
		s.pos += 1
		pat := delimited(s, '/')
		re, ok := libregex.compile(pat, false, context.allocator)
		if !ok {
			bad("bad address pattern")
		}
		return Addr{kind = .Regex, re = re}
	}
	return Addr{}
}

// delimited reads up to the next unescaped `delim`, unescaping `\delim`,
// and leaves the position after it.
delimited :: proc(s: ^Script, delim: u8) -> string {
	out := make([dynamic]u8)
	for {
		if s.pos >= len(s.text) {
			bad("unterminated pattern")
		}
		c := s.text[s.pos]
		s.pos += 1
		if c == delim {
			break
		}
		if c == '\\' && s.pos < len(s.text) && s.text[s.pos] == delim {
			append(&out, delim)
			s.pos += 1
			continue
		}
		append(&out, c)
	}
	return string(out[:])
}

parse_subst :: proc(s: ^Script, cmd: ^Command) {
	if s.pos >= len(s.text) {
		bad("s wants a delimiter")
	}
	delim := s.text[s.pos]
	s.pos += 1
	pat := delimited(s, delim)
	cmd.repl = delimited(s, delim)
	re, ok := libregex.compile(pat, false, context.allocator)
	if !ok {
		bad("bad pattern in s")
	}
	cmd.re = re
	for s.pos < len(s.text) {
		switch s.text[s.pos] {
		case 'g':
			cmd.global = true
		case 'p':
			cmd.print = true
		case:
			return
		}
		s.pos += 1
	}
}

bad :: proc(what: string) -> ! {
	libuser.eprint("sed: ", what, "\n")
	libuser.exits("bad script")
}

// -- The edit ---------------------------------------------------------------------------

edit :: proc(out: ^libuser.Bio, fd: int) {
	r: libuser.Reader
	libuser.reader_init(&r, fd)
	line_no: i64 = 0
	pattern := make([dynamic]u8)
	next_line, has_next := libuser.read_line(&r)
	for has_next {
		clear(&pattern)
		append(&pattern, ..transmute([]u8)next_line)
		next_line, has_next = libuser.read_line(&r)
		last := !has_next
		line_no += 1

		deleted := false
		stop := false
		for &cmd in commands {
			if !selects(&cmd, string(pattern[:]), line_no, last) {
				continue
			}
			switch cmd.op {
			case 'p':
				libuser.bio_write(out, pattern[:])
				libuser.bio_putc(out, '\n')
			case 'd':
				deleted = true
			case 'q':
				stop = true
			case 's':
				if substitute(&cmd, &pattern) && cmd.print {
					libuser.bio_write(out, pattern[:])
					libuser.bio_putc(out, '\n')
				}
			}
			if deleted || stop {
				break
			}
		}
		if !deleted && !quiet {
			libuser.bio_write(out, pattern[:])
			libuser.bio_putc(out, '\n')
		}
		if stop {
			return
		}
	}
}

// selects says whether a command applies to this line, tracking ranges.
selects :: proc(cmd: ^Command, line: string, line_no: i64, last: bool) -> bool {
	hit := false
	switch {
	case cmd.a1.kind == .None:
		hit = true
	case cmd.a2.kind == .None:
		hit = addr_matches(&cmd.a1, line, line_no, last)
	case cmd.in_range:
		hit = true
		if addr_matches(&cmd.a2, line, line_no, last) || (cmd.a2.kind == .Line && line_no >= cmd.a2.line) {
			cmd.in_range = false
		}
	case:
		if addr_matches(&cmd.a1, line, line_no, last) {
			hit = true
			// A range whose end is already behind is one line long.
			cmd.in_range = !(cmd.a2.kind == .Line && cmd.a2.line <= line_no)
		}
	}
	return hit != cmd.negate
}

addr_matches :: proc(a: ^Addr, line: string, line_no: i64, last: bool) -> bool {
	switch a.kind {
	case .None:
		return false
	case .Line:
		return line_no == a.line
	case .Last:
		return last
	case .Regex:
		_, _, ok := libregex.match(a.re, line)
		return ok
	}
	return false
}

// substitute rewrites the pattern space in place and says whether anything
// matched. `&` in the replacement is the matched text.
substitute :: proc(cmd: ^Command, pattern: ^[dynamic]u8) -> bool {
	text := string(pattern[:])
	out := &subst_scratch
	clear(out)
	at := 0
	any := false
	for at <= len(text) {
		start_at, end, ok := libregex.match_from(cmd.re, text, at)
		if !ok {
			break
		}
		any = true
		append(out, ..transmute([]u8)text[at:start_at])
		expand(out, cmd.repl, text[start_at:end])
		if end == start_at {
			// An empty match: keep one character so the scan moves.
			if start_at < len(text) {
				append(out, text[start_at])
			}
			at = start_at + 1
		} else {
			at = end
		}
		if !cmd.global {
			break
		}
	}
	if !any {
		return false
	}
	if at < len(text) {
		append(out, ..transmute([]u8)text[at:])
	}
	clear(pattern)
	append(pattern, ..out[:])
	return true
}

// The rewritten line, kept between substitutions rather than made per line.
subst_scratch: [dynamic]u8

expand :: proc(out: ^[dynamic]u8, repl: string, matched: string) {
	i := 0
	for i < len(repl) {
		c := repl[i]
		switch {
		case c == '&':
			append(out, ..transmute([]u8)matched)
		case c == '\\' && i + 1 < len(repl):
			i += 1
			switch repl[i] {
			case 'n':
				append(out, '\n')
			case:
				append(out, repl[i])
			}
		case:
			append(out, c)
		}
		i += 1
	}
}
