/*
The tree `rc` runs.

The parser builds one of these per line, the interpreter walks it, and the
walk is the program's meaning. Plan 9's rc compiles the tree to a small
bytecode and runs a machine over it; this one walks the tree directly,
because a fork copies the interpreter whole and a child can carry on from
any node, which is the only thing the bytecode was there to make cheap.

One node type for every kind, and which fields a kind uses is written
beside it. A word is a node too, so an argument that is `$x^`{cmd}` is a
subtree and evaluates like everything else.
*/
package rc

Kind :: enum u8 {
	// Words
	Word, // text; plain says it was unquoted and has no pattern characters
	Var, // a = name word, b = subscript Paren or nil
	Count, // a = name word: $#name
	Join, // a = name word: $"name
	Concat, // a ^ b
	Backquote, // a = body: `{body}
	Paren, // list = words: (a b c)

	// Commands
	Nop, // nothing, or only redirections
	Simple, // list = words, redirs
	Brace, // a = body, redirs
	Seq, // a ; b
	Async, // a &
	And_And, // a && b
	Or_Or, // a || b
	Pipe, // a |[pipe_left=pipe_right] b
	Bang, // ! a
	Subshell, // @ a
	If, // a = condition, b = body
	If_Not, // a = body
	For, // a = variable word, c = Paren of the list or nil for $*, b = body
	While, // a = condition, b = body
	Switch, // a = word, list = Case nodes
	Case, // list = patterns, a = body
	Fn, // list = names, a = body or nil to delete
	Twiddle, // a = subject, list = patterns
	Assign, // a = name word, b = value word, c = command or nil
}

Redir_Kind :: enum u8 {
	Read, // < file
	Write, // > file
	Append, // >> file
	Read_Write, // <> file
	Here, // << tag, the body in `here`
	Dup, // >[fd=from]
	Close, // >[fd=]
}

Redir :: struct {
	kind:        Redir_Kind,
	fd:          int, // the descriptor the command sees
	from:        int, // Dup: the descriptor copied onto it
	word:        ^Node, // the file, or the tag of a here document
	here:        ^Here_Body, // the body of a here document, filled when the line ends
	here_quoted: bool, // the tag was quoted, so the body is literal
}

// Here_Body is where a here document's lines land. Behind a pointer, because
// the redirection that owns it sits in a dynamic array the parser may still
// be growing when the lexer reads the body.
Here_Body :: struct {
	text: string,
}

Node :: struct {
	kind:       Kind,
	text:       string, // Word: the text, with GLOB before each live pattern character
	plain:      bool, // Word: no quotes and no live pattern characters
	eq:         int, // Word: index of the first unquoted `=`, or -1
	list:       [dynamic]^Node,
	a, b, c:    ^Node,
	redirs:     [dynamic]Redir,
	pipe_left:  int, // Pipe: the left side's descriptor, 1 unless |[n]
	pipe_right: int, // Pipe: the right side's, 0 unless |[n=m]
	line:       int,
}

// GLOB marks the character after it as a live pattern character: an
// unquoted `*`, `?` or `[`. Plan 9's rc uses the same byte. A quoted one
// carries no mark and is literal everywhere.
GLOB :: u8(0x01)

new_node :: proc(kind: Kind, line: int) -> ^Node {
	n := new(Node)
	n.kind = kind
	n.line = line
	n.eq = -1
	return n
}

word_node :: proc(text: string, plain: bool, eq: int, line: int) -> ^Node {
	n := new_node(.Word, line)
	n.text = text
	n.plain = plain
	n.eq = eq
	return n
}

binary :: proc(kind: Kind, a, b: ^Node, line: int) -> ^Node {
	n := new_node(kind, line)
	n.a = a
	n.b = b
	return n
}

// free_tree gives a line's tree back after it ran. A function body the
// line defined was detached by the definition and is not here any more.
free_tree :: proc(n: ^Node) {
	if n == nil {
		return
	}
	free_tree(n.a)
	free_tree(n.b)
	free_tree(n.c)
	for child in n.list {
		free_tree(child)
	}
	delete(n.list)
	for r in n.redirs {
		free_tree(r.word)
		if r.here != nil {
			delete(r.here.text)
			free(r.here)
		}
	}
	delete(n.redirs)
	if n.kind == .Word && len(n.text) > 0 {
		delete(n.text)
	}
	free(n)
}

// leftmost is the first Word in a concatenation, where an assignment's
// name sits: `x=a^b` is Concat(Word "x=a", Word "b").
leftmost :: proc(n: ^Node) -> ^Node {
	cur := n
	for cur != nil && cur.kind == .Concat {
		cur = cur.a
	}
	return cur
}
