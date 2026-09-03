/*
Words and punctuation, out of characters.

Plan 9's lexer, rule for rule, because the rules are what a person's fingers
know: `''` inside quotes is one quote, `#` starts a comment, a caret is
inserted between two things that touch, `$x(1)` is a subscript because the
`(` follows a `$` word, and `<<tag` means the lines after this one are a
file. Keywords are whole plain words: `for` quoted or concatenated is a
word again.
*/
package rc

import "vsys:libfmt"

Tok :: enum u8 {
	EOF,
	Newline,
	Word,
	Semi,
	Amp,
	And_And,
	Or_Or,
	Pipe,
	Caret,
	Dollar,
	Count,
	Join,
	Backquote,
	LBrace,
	RBrace,
	LParen,
	RParen,
	Sub,
	Redir,
	Kw_If,
	Kw_Not,
	Kw_For,
	Kw_In,
	Kw_While,
	Kw_Switch,
	Kw_Case,
	Kw_Fn,
	Kw_Bang,
	Kw_Subshell,
	Kw_Twiddle,
}

Token :: struct {
	kind:  Tok,
	text:  string, // Word: the text with GLOB marks, on the heap
	plain: bool,
	eq:    int,
	redir: Redir, // Redir: kind, fd, from
	left:  int, // Pipe: |[left=right]
	right: int,
	line:  int,
}

Pending_Here :: struct {
	body: ^Here_Body,
	tag:  string,
}

Lexer :: struct {
	in_:      ^Input,
	peeked:   Token,
	has_peek: bool,
	lastword: bool, // a caret goes in if the next thing touches
	lastdol:  bool, // the last word followed a `$`, so `(` is a subscript
	afterdol: bool, // the next word follows a `$`
	pending:  [dynamic]Pending_Here,
	err:      bool,
}

lexer_init :: proc(lx: ^Lexer, in_: ^Input) {
	lx.in_ = in_
	lx.has_peek = false
	lx.lastword = false
	lx.lastdol = false
	lx.afterdol = false
	lx.err = false
	lx.pending = make([dynamic]Pending_Here)
}

lexer_free :: proc(lx: ^Lexer) {
	delete(lx.pending)
}

peek :: proc(lx: ^Lexer) -> Token {
	if !lx.has_peek {
		lx.peeked = lex(lx)
		lx.has_peek = true
	}
	return lx.peeked
}

next :: proc(lx: ^Lexer) -> Token {
	t := peek(lx)
	lx.has_peek = false
	return t
}

// wordchr says whether a character continues a word. Everything that is
// not whitespace or one of rc's own characters. `=` continues a word here
// and the parser splits an assignment off the front of the first word.
wordchr :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r', '#', ';', '&', '|', '^', '$', '`', '\'', '{', '}', '(', ')', '<', '>':
		return false
	}
	return true
}

// idchr says whether a character continues a variable name after `$`.
idchr :: proc(c: u8) -> bool {
	return c == '_' || c == '*' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80
}

starts_word :: proc(c: u8) -> bool {
	return wordchr(c) || c == '\'' || c == '$' || c == '`' || c == '('
}

// lex is one token. The free caret and the subscript are decided here,
// before the character is looked at, from what the last token was.
lex :: proc(lx: ^Lexer) -> Token {
	in_ := lx.in_
	c, ok := peekc(in_)
	for ok && (c == ' ' || c == '\t' || c == '\r') {
		getc(in_)
		lx.lastword = false
		lx.lastdol = false
		c, ok = peekc(in_)
	}
	if ok && c == '#' {
		for ok && c != '\n' {
			getc(in_)
			c, ok = peekc(in_)
		}
	}
	line := in_.line
	if !ok {
		return Token{kind = .EOF, line = line}
	}

	if lx.lastword {
		if c == '(' && lx.lastdol {
			getc(in_)
			lx.lastword = false
			lx.lastdol = false
			return Token{kind = .Sub, line = line}
		}
		if starts_word(c) {
			lx.lastword = false
			lx.lastdol = false
			return Token{kind = .Caret, line = line}
		}
	}
	lx.lastword = false
	lx.lastdol = false

	switch c {
	case '\n':
		getc(in_)
		read_here_bodies(lx)
		return Token{kind = .Newline, line = line}
	case ';':
		getc(in_)
		return Token{kind = .Semi, line = line}
	case '&':
		getc(in_)
		if d, dok := peekc(in_); dok && d == '&' {
			getc(in_)
			return Token{kind = .And_And, line = line}
		}
		return Token{kind = .Amp, line = line}
	case '|':
		getc(in_)
		if d, dok := peekc(in_); dok && d == '|' {
			getc(in_)
			return Token{kind = .Or_Or, line = line}
		}
		t := Token{kind = .Pipe, left = 1, right = 0, line = line}
		if d, dok := peekc(in_); dok && d == '[' {
			getc(in_)
			a, b, has_b, bok := lex_brackets(lx)
			if !bok {
				return syntax(lx, "bad descriptor after |[", line)
			}
			t.left = a
			if has_b {
				t.right = b
			}
		}
		return t
	case '^':
		getc(in_)
		return Token{kind = .Caret, line = line}
	case '$':
		getc(in_)
		lx.afterdol = true
		if d, dok := peekc(in_); dok {
			if d == '#' {
				getc(in_)
				return Token{kind = .Count, line = line}
			}
			if d == '"' {
				getc(in_)
				return Token{kind = .Join, line = line}
			}
		}
		return Token{kind = .Dollar, line = line}
	case '`':
		getc(in_)
		return Token{kind = .Backquote, line = line}
	case '{':
		getc(in_)
		return Token{kind = .LBrace, line = line}
	case '}':
		getc(in_)
		lx.lastword = true
		return Token{kind = .RBrace, line = line}
	case '(':
		getc(in_)
		return Token{kind = .LParen, line = line}
	case ')':
		getc(in_)
		lx.lastword = true
		return Token{kind = .RParen, line = line}
	case '<', '>':
		return lex_redir(lx, line)
	}
	return lex_word(lx, line)
}

// lex_brackets reads `n]`, `n=m]` or `n=]` after a `[`, answering the
// numbers and whether the second was there. `n=]` answers has_b with b = -1.
@(private = "file")
lex_brackets :: proc(lx: ^Lexer) -> (a, b: int, has_b: bool, ok: bool) {
	in_ := lx.in_
	a, ok = lex_number(in_)
	if !ok {
		return
	}
	c, cok := getc(in_)
	if !cok {
		return 0, 0, false, false
	}
	if c == ']' {
		return a, 0, false, true
	}
	if c != '=' {
		return 0, 0, false, false
	}
	if d, dok := peekc(in_); dok && d == ']' {
		getc(in_)
		return a, -1, true, true
	}
	b, ok = lex_number(in_)
	if !ok {
		return
	}
	c, cok = getc(in_)
	return a, b, true, cok && c == ']'
}

@(private = "file")
lex_number :: proc(in_: ^Input) -> (n: int, ok: bool) {
	digits := 0
	for {
		c, cok := peekc(in_)
		if !cok || c < '0' || c > '9' {
			break
		}
		getc(in_)
		n = n * 10 + int(c - '0')
		digits += 1
	}
	return n, digits > 0
}

@(private = "file")
lex_redir :: proc(lx: ^Lexer, line: int) -> Token {
	in_ := lx.in_
	c, _ := getc(in_)
	t := Token{kind = .Redir, line = line}
	if c == '<' {
		t.redir = Redir{kind = .Read, fd = 0}
		if d, dok := peekc(in_); dok {
			if d == '<' {
				getc(in_)
				t.redir.kind = .Here
			} else if d == '>' {
				getc(in_)
				t.redir.kind = .Read_Write
			}
		}
	} else {
		t.redir = Redir{kind = .Write, fd = 1}
		if d, dok := peekc(in_); dok && d == '>' {
			getc(in_)
			t.redir.kind = .Append
		}
	}
	if d, dok := peekc(in_); dok && d == '[' {
		getc(in_)
		a, b, has_b, bok := lex_brackets(lx)
		if !bok {
			return syntax(lx, "bad descriptor after [", line)
		}
		t.redir.fd = a
		if has_b {
			if b < 0 {
				t.redir.kind = .Close
			} else {
				t.redir.kind = .Dup
				t.redir.from = b
			}
		}
	}
	return t
}

/*
lex_word reads a word: runs of word characters and quoted strings, in any
order, as one token. Quotes are removed, `''` inside them is one quote, and
an unquoted `*`, `?` or `[` gets its GLOB mark. A word that is exactly a
keyword, unquoted and unmarked, is that keyword.
*/
@(private = "file")
lex_word :: proc(lx: ^Lexer, line: int) -> Token {
	in_ := lx.in_
	buf := make([dynamic]u8, 0, 32)
	plain := true
	eq := -1
	for {
		c, ok := peekc(in_)
		if !ok {
			break
		}
		if c == '\'' {
			if len(buf) > 0 {
				// A quoted string is a token of its own; the free caret joins
				// it to what came before. `$x'y'` is then `$x^'y'` and not a
				// variable named `xy`.
				break
			}
			getc(in_)
			plain = false
			for {
				d, dok := getc(in_)
				if !dok {
					delete(buf)
					return syntax(lx, "unterminated quote", line)
				}
				if d == '\'' {
					if e, eok := peekc(in_); eok && e == '\'' {
						getc(in_)
						append(&buf, '\'')
						continue
					}
					break
				}
				append(&buf, d)
			}
			break
		}
		if !wordchr(c) {
			break
		}
		if lx.afterdol && len(buf) > 0 && !idchr(c) {
			// A name after `$` is letters, digits, `_` and `*`: `$pid/status`
			// is the variable and then a word, which the free caret joins.
			break
		}
		getc(in_)
		switch c {
		case '*', '?', '[':
			append(&buf, GLOB)
			plain = false
		case '=':
			if eq < 0 {
				eq = len(buf)
			}
		}
		append(&buf, c)
	}
	if len(buf) == 0 {
		// A character no rule wanted: `}` where nothing is open, or `)`.
		// The caller's grammar reports it; consume so the line moves on.
		getc(in_)
		delete(buf)
		return syntax(lx, "unexpected character", line)
	}

	text := string(buf[:])
	lx.lastword = true
	if lx.afterdol {
		lx.lastdol = true
		lx.afterdol = false
	} else if eq >= 0 && eq == len(text) - 1 {
		// `x=` before `(a b)` or `$y`: the value follows, not a caret.
		lx.lastword = false
	}

	if plain && eq < 0 {
		kind := Tok.Word
		switch text {
		case "if":
			kind = .Kw_If
		case "not":
			kind = .Kw_Not
		case "for":
			kind = .Kw_For
		case "in":
			kind = .Kw_In
		case "while":
			kind = .Kw_While
		case "switch":
			kind = .Kw_Switch
		case "case":
			kind = .Kw_Case
		case "fn":
			kind = .Kw_Fn
		case "!":
			kind = .Kw_Bang
		case "@":
			kind = .Kw_Subshell
		case "~":
			kind = .Kw_Twiddle
		}
		if kind != .Word {
			// `if(` and `for(` are a keyword and a paren, not a concatenation.
			lx.lastword = false
			return Token{kind = kind, text = text, plain = true, eq = -1, line = line}
		}
	}
	return Token{kind = .Word, text = text, plain = plain, eq = eq, line = line}
}

is_word_start :: proc(k: Tok) -> bool {
	#partial switch k {
	case .Word, .Dollar, .Count, .Join, .Backquote, .LParen:
		return true
	}
	return is_keyword(k)
}

is_keyword :: proc(k: Tok) -> bool {
	#partial switch k {
	case .Kw_If, .Kw_Not, .Kw_For, .Kw_In, .Kw_While, .Kw_Switch, .Kw_Case, .Kw_Fn, .Kw_Bang, .Kw_Subshell, .Kw_Twiddle:
		return true
	}
	return false
}

// read_here_bodies collects the lines after a newline for every `<<` on
// the line just ended, each up to a line that is exactly its tag.
@(private = "file")
read_here_bodies :: proc(lx: ^Lexer) {
	in_ := lx.in_
	for p in lx.pending {
		body := make([dynamic]u8, 0, 256)
		line := make([dynamic]u8, 0, 128)
		found := false
		for !found {
			clear(&line)
			for {
				c, ok := getc(in_)
				if !ok {
					break
				}
				if c == '\n' {
					break
				}
				append(&line, c)
			}
			if string(line[:]) == p.tag {
				found = true
				break
			}
			if in_.eof {
				break
			}
			append(&body, ..line[:])
			append(&body, '\n')
		}
		delete(line)
		if !found {
			libfmt.fprint(2, "rc: here document for %s never ended\n", p.tag)
		}
		p.body.text = string(body[:])
		delete(p.tag)
	}
	clear(&lx.pending)
}

@(private = "file")
syntax :: proc(lx: ^Lexer, what: string, line: int) -> Token {
	if !lx.err {
		libfmt.fprint(2, "rc: line %d: %s\n", line, what)
		lx.err = true
	}
	return Token{kind = .EOF, line = line}
}
