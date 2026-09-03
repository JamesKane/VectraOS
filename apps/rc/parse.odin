/*
The grammar, by hand.

Plan 9's rc is a yacc grammar. This is the same grammar as a recursive
descent, one procedure per level of precedence, lowest first:

    line      cmd (; cmd | cmd &)* newline
    cmd       bang (&& bang | || bang)*
    bang      ! bang | @ bang | pipeline
    pipeline  unit (| unit)*
    unit      { body } | if (...) cmd | if not cmd | for(...) cmd
              | while (...) cmd | switch word { cases } | fn names [{ body }]
              | ~ word patterns | name=value [cmd] | simple
    simple    word (word | redir)*
    word      sword (^ sword)*
    sword     WORD | $sword [(words)] | $#sword | $"sword | `{ body } | (words)

`if` binds loosest, so `if(x) a | b && c` is the whole tail. `!` sits
between `&&` and `|`, so `! a | b` is `!(a | b)`, and `! a && b` is
`(!a) && b`. Both are rc's. A newline is a separator inside braces and
parentheses and ends a line outside them, except after `&&`, `||`, `|`
and a closing `)` of `if`, `for` and `while`, where the command continues.
*/
package rc

import "vsys:libfmt"

Parser :: struct {
	lx:  ^Lexer,
	err: bool,
}

// parse_line parses one line of input into a tree, or answers nil at the
// end of the input. A syntax error answers nil too, with `err` set and the
// rest of the line discarded.
parse_line :: proc(p: ^Parser) -> ^Node {
	p.err = false
	p.lx.err = false
	p.lx.in_.prompt = 1
	t := peek(p.lx)
	if t.kind == .EOF {
		if p.lx.err {
			// A lexical error, not the end: the line is lost, not the session.
			recover(p)
			p.err = true
			return new_node(.Nop, t.line)
		}
		return nil
	}
	n := parse_seq(p, .Newline)
	if p.err || p.lx.err {
		free_tree(n)
		recover(p)
		return new_node(.Nop, t.line)
	}
	if peek(p.lx).kind == .Newline {
		next(p.lx)
	}
	if n == nil {
		n = new_node(.Nop, t.line)
	}
	return n
}

// parse_seq is a sequence of commands separated by `;`, `&` or, inside a
// bracket, newlines, up to `closer`, which is left for the caller.
parse_seq :: proc(p: ^Parser, closer: Tok) -> ^Node {
	seq: ^Node
	for !p.err {
		t := peek(p.lx)
		if t.kind == closer || t.kind == .EOF {
			break
		}
		if t.kind == .Semi || (t.kind == .Newline && closer != .Newline) {
			next(p.lx)
			continue
		}
		c := parse_cmd(p)
		if p.err {
			free_tree(c)
			break
		}
		t = peek(p.lx)
		#partial switch t.kind {
		case .Amp:
			next(p.lx)
			a := new_node(.Async, t.line)
			a.a = c
			c = a
		case .Semi:
			next(p.lx)
		case .Newline:
			if closer != .Newline {
				next(p.lx)
			}
		case .EOF:
		case:
			if t.kind != closer {
				error(p, t, "unexpected token")
				free_tree(c)
				break
			}
		}
		if p.err {
			break
		}
		seq = seq == nil ? c : binary(.Seq, seq, c, t.line)
	}
	return seq
}

parse_cmd :: proc(p: ^Parser) -> ^Node {
	left := parse_bang(p)
	for !p.err {
		t := peek(p.lx)
		if t.kind != .And_And && t.kind != .Or_Or {
			break
		}
		next(p.lx)
		skip_newlines(p)
		right := parse_bang(p)
		left = binary(t.kind == .And_And ? .And_And : .Or_Or, left, right, t.line)
	}
	return left
}

parse_bang :: proc(p: ^Parser) -> ^Node {
	t := peek(p.lx)
	if t.kind == .Kw_Bang || t.kind == .Kw_Subshell {
		next(p.lx)
		delete(t.text)
		n := new_node(t.kind == .Kw_Bang ? .Bang : .Subshell, t.line)
		n.a = parse_bang(p)
		return n
	}
	return parse_pipeline(p)
}

parse_pipeline :: proc(p: ^Parser) -> ^Node {
	left := parse_unit(p)
	for !p.err {
		t := peek(p.lx)
		if t.kind != .Pipe {
			break
		}
		next(p.lx)
		skip_newlines(p)
		right := parse_unit(p)
		n := binary(.Pipe, left, right, t.line)
		n.pipe_left = t.left
		n.pipe_right = t.right
		left = n
	}
	return left
}

parse_unit :: proc(p: ^Parser) -> ^Node {
	// Redirections before the command belong to it: `> x echo hi`.
	before := make([dynamic]Redir)
	for !p.err && peek(p.lx).kind == .Redir {
		r, ok := parse_redir(p)
		if ok {
			append(&before, r)
		}
	}

	t := peek(p.lx)
	n: ^Node
	#partial switch t.kind {
	case .LBrace:
		next(p.lx)
		n = new_node(.Brace, t.line)
		n.a = parse_seq(p, .RBrace)
		expect(p, .RBrace, "expected }")
		for !p.err && peek(p.lx).kind == .Redir {
			r, ok := parse_redir(p)
			if ok {
				append(&n.redirs, r)
			}
		}

	case .Kw_If:
		next(p.lx)
		delete(t.text)
		if peek(p.lx).kind == .Kw_Not {
			nt := next(p.lx)
			delete(nt.text)
			skip_newlines(p)
			n = new_node(.If_Not, t.line)
			n.a = parse_cmd(p)
		} else {
			n = new_node(.If, t.line)
			n.a = parse_paren_body(p)
			skip_newlines(p)
			n.b = parse_cmd(p)
		}

	case .Kw_While:
		next(p.lx)
		delete(t.text)
		n = new_node(.While, t.line)
		n.a = parse_paren_body(p)
		skip_newlines(p)
		n.b = parse_cmd(p)

	case .Kw_For:
		next(p.lx)
		delete(t.text)
		n = new_node(.For, t.line)
		expect(p, .LParen, "expected ( after for")
		n.a = parse_word(p)
		if peek(p.lx).kind == .Kw_In {
			it := next(p.lx)
			delete(it.text)
			n.c = new_node(.Paren, t.line)
			parse_words(p, &n.c.list, .RParen)
		}
		expect(p, .RParen, "expected ) after for")
		skip_newlines(p)
		n.b = parse_cmd(p)

	case .Kw_Switch:
		next(p.lx)
		delete(t.text)
		n = new_node(.Switch, t.line)
		n.a = parse_word(p)
		skip_newlines(p)
		expect(p, .LBrace, "expected { after switch")
		parse_cases(p, n)
		expect(p, .RBrace, "expected } after switch")

	case .Kw_Fn:
		next(p.lx)
		delete(t.text)
		n = new_node(.Fn, t.line)
		for !p.err && is_word_start(peek(p.lx).kind) {
			append(&n.list, parse_word(p))
		}
		if peek(p.lx).kind == .LBrace {
			bt := next(p.lx)
			body := new_node(.Brace, bt.line)
			body.a = parse_seq(p, .RBrace)
			expect(p, .RBrace, "expected } after fn body")
			n.a = body
		}

	case .Kw_Twiddle:
		next(p.lx)
		delete(t.text)
		n = new_node(.Twiddle, t.line)
		n.a = parse_word(p)
		for !p.err && is_word_start(peek(p.lx).kind) {
			append(&n.list, parse_word(p))
		}

	case:
		if is_word_start(t.kind) {
			n = parse_simple(p)
		} else if len(before) > 0 {
			n = new_node(.Nop, t.line)
		} else {
			error(p, t, "expected a command")
			n = new_node(.Nop, t.line)
		}
	}

	if len(before) > 0 {
		// The command's own redirections come after the ones before it.
		merged := make([dynamic]Redir, 0, len(before) + len(n.redirs))
		append(&merged, ..before[:])
		append(&merged, ..n.redirs[:])
		delete(n.redirs)
		n.redirs = merged
	}
	delete(before)
	return n
}

// parse_paren_body is `( body )`, the condition of if and while.
@(private = "file")
parse_paren_body :: proc(p: ^Parser) -> ^Node {
	t := peek(p.lx)
	expect(p, .LParen, "expected (")
	body := parse_seq(p, .RParen)
	expect(p, .RParen, "expected )")
	if body == nil {
		body = new_node(.Nop, t.line)
	}
	return body
}

// parse_cases fills a switch with its cases: `case patterns` then a
// separator, then commands up to the next case or the closing brace.
@(private = "file")
parse_cases :: proc(p: ^Parser, sw: ^Node) {
	skip_newlines(p)
	for !p.err {
		t := peek(p.lx)
		if t.kind == .RBrace || t.kind == .EOF {
			return
		}
		if t.kind != .Kw_Case {
			error(p, t, "expected case")
			return
		}
		next(p.lx)
		delete(t.text)
		c := new_node(.Case, t.line)
		for !p.err && is_word_start(peek(p.lx).kind) {
			append(&c.list, parse_word(p))
		}
		sep := peek(p.lx)
		if sep.kind == .Semi || sep.kind == .Newline {
			next(p.lx)
		}
		// The body: commands until the next `case` or the brace.
		body: ^Node
		for !p.err {
			bt := peek(p.lx)
			if bt.kind == .Kw_Case || bt.kind == .RBrace || bt.kind == .EOF {
				break
			}
			if bt.kind == .Semi || bt.kind == .Newline {
				next(p.lx)
				continue
			}
			cmd := parse_cmd(p)
			at := peek(p.lx)
			if at.kind == .Amp {
				next(p.lx)
				a := new_node(.Async, at.line)
				a.a = cmd
				cmd = a
			}
			body = body == nil ? cmd : binary(.Seq, body, cmd, bt.line)
		}
		c.a = body
		append(&sw.list, c)
	}
}

/*
parse_simple is a command that is words and redirections, and the place an
assignment is recognised: the first word's leftmost piece is `name=...`,
unquoted, with a name in front of the `=`. `x=y cmd` scopes x to cmd;
`x=y` alone sets it.
*/
@(private = "file")
parse_simple :: proc(p: ^Parser) -> ^Node {
	t := peek(p.lx)
	first := parse_word(p)
	if p.err {
		return first
	}

	leaf := leftmost(first)
	if leaf != nil && leaf.kind == .Word && leaf.eq > 0 && valid_name(leaf.text[:leaf.eq]) {
		n := new_node(.Assign, t.line)
		n.a = word_node(clone(leaf.text[:leaf.eq]), true, -1, t.line)
		rest := leaf.text[leaf.eq + 1:]
		if len(rest) == 0 {
			if first == leaf {
				// `x=` then the value as its own word, or nothing.
				free_tree(first)
				if is_word_start(peek(p.lx).kind) {
					n.b = parse_word(p)
				} else {
					n.b = new_node(.Paren, t.line)
				}
			} else {
				// `x=^$y`: drop the empty leaf and keep what it joined.
				n.b = drop_leftmost(first)
			}
		} else {
			old := leaf.text
			leaf.text = clone(rest)
			delete(old)
			n.b = first
		}
		if !p.err && (is_word_start(peek(p.lx).kind) || peek(p.lx).kind == .Redir || peek(p.lx).kind == .LBrace) {
			n.c = parse_bang(p)
		}
		return n
	}

	n := new_node(.Simple, t.line)
	append(&n.list, first)
	for !p.err {
		k := peek(p.lx).kind
		if k == .Redir {
			r, ok := parse_redir(p)
			if ok {
				append(&n.redirs, r)
			}
		} else if is_word_start(k) {
			append(&n.list, parse_word(p))
		} else {
			break
		}
	}
	return n
}

// drop_leftmost removes the leftmost word from a concatenation and answers
// what remains. Concat(Word, x) becomes x.
@(private = "file")
drop_leftmost :: proc(n: ^Node) -> ^Node {
	if n.kind != .Concat {
		return n
	}
	if n.a.kind != .Concat {
		rest := n.b
		free_tree(n.a)
		n.b = nil
		n.a = nil
		free(n)
		return rest
	}
	n.a = drop_leftmost(n.a)
	return n
}

valid_name :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		ok := c == '_' || c == '*' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if !ok {
			return false
		}
	}
	return true
}

parse_redir :: proc(p: ^Parser) -> (r: Redir, ok: bool) {
	t := next(p.lx)
	r = t.redir
	switch r.kind {
	case .Read, .Write, .Append, .Read_Write:
		if !is_word_start(peek(p.lx).kind) {
			error(p, t, "expected a file after the redirection")
			return r, false
		}
		r.word = parse_word(p)
	case .Here:
		tag := peek(p.lx)
		if tag.kind != .Word && !is_keyword(tag.kind) {
			error(p, t, "expected a tag after <<")
			return r, false
		}
		next(p.lx)
		r.here_quoted = !tag.plain
		r.word = word_node(tag.text, tag.plain, tag.eq, tag.line)
		r.here = new(Here_Body)
		append(&p.lx.pending, Pending_Here{body = r.here, tag = clone(strip_marks(tag.text))})
	case .Dup, .Close:
	}
	return r, true
}

// parse_word is a concatenation of simple words.
parse_word :: proc(p: ^Parser) -> ^Node {
	w := parse_sword(p)
	for !p.err && peek(p.lx).kind == .Caret {
		t := next(p.lx)
		r := parse_sword(p)
		w = binary(.Concat, w, r, t.line)
	}
	return w
}

@(private = "file")
parse_sword :: proc(p: ^Parser) -> ^Node {
	t := next(p.lx)
	#partial switch t.kind {
	case .Word:
		return word_node(t.text, t.plain, t.eq, t.line)
	case .Dollar:
		n := new_node(.Var, t.line)
		n.a = parse_sword(p)
		if !p.err && peek(p.lx).kind == .Sub {
			next(p.lx)
			n.b = new_node(.Paren, t.line)
			parse_words(p, &n.b.list, .RParen)
			expect(p, .RParen, "expected ) after subscript")
		}
		return n
	case .Count:
		n := new_node(.Count, t.line)
		n.a = parse_sword(p)
		return n
	case .Join:
		n := new_node(.Join, t.line)
		n.a = parse_sword(p)
		return n
	case .Backquote:
		n := new_node(.Backquote, t.line)
		expect(p, .LBrace, "expected { after `")
		body := new_node(.Brace, t.line)
		body.a = parse_seq(p, .RBrace)
		expect(p, .RBrace, "expected } after `{")
		n.a = body
		return n
	case .LParen:
		n := new_node(.Paren, t.line)
		parse_words(p, &n.list, .RParen)
		expect(p, .RParen, "expected )")
		return n
	}
	if is_keyword(t.kind) {
		return word_node(t.text, true, -1, t.line)
	}
	error(p, t, "expected a word")
	return word_node(clone(""), true, -1, t.line)
}

// parse_words fills a list up to `closer`, across newlines.
@(private = "file")
parse_words :: proc(p: ^Parser, list: ^[dynamic]^Node, closer: Tok) {
	for !p.err {
		t := peek(p.lx)
		if t.kind == closer || t.kind == .EOF {
			return
		}
		if t.kind == .Newline {
			next(p.lx)
			continue
		}
		if !is_word_start(t.kind) {
			error(p, t, "expected a word")
			return
		}
		append(list, parse_word(p))
	}
}

@(private = "file")
skip_newlines :: proc(p: ^Parser) {
	for peek(p.lx).kind == .Newline {
		next(p.lx)
	}
}

@(private = "file")
expect :: proc(p: ^Parser, k: Tok, what: string) {
	t := peek(p.lx)
	if t.kind == k {
		next(p.lx)
		return
	}
	error(p, t, what)
}

@(private = "file")
error :: proc(p: ^Parser, t: Token, what: string) {
	if !p.err && !p.lx.err {
		libfmt.fprint(2, "rc: line %d: syntax error: %s\n", t.line, what)
	}
	p.err = true
}

// recover throws away the rest of the line a syntax error was on, so the
// next line starts clean. In a script the caller stops instead.
@(private = "file")
recover :: proc(p: ^Parser) {
	p.lx.has_peek = false
	p.lx.lastword = false
	p.lx.lastdol = false
	p.lx.afterdol = false
	clear(&p.lx.pending)
	discard_line(p.lx.in_)
}
