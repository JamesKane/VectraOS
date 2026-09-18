/*
libhtml -- the readable web, into a `libdoc.Doc`.

`docs/WEB.md` section 5 asks for the WHATWG tokenizer and a tree builder
that keeps what a reader needs and drops the rest. The tokenizer here is
that specification's, cut to the states a page reaches. Data, tags and
their attributes, comments, the doctype, and character references. The raw
text of `<script>` and `<style>` is read past and never shown.

The builder is not a tree. It is a reader's builder. Text gathers into a
paragraph, and a block element flushes it. The element the text sits in says
which kind of block it is: a heading, an item, a quote, or a paragraph. A
link's name stays in the paragraph and the link follows it as a block,
`libmark`'s way, so a row can be pressed. An image is a block of its own.

A table row is a paragraph, its cells parted by a bar. Emphasis is dropped,
since the reader draws one face. No stylesheet is read and no script is run.
A form is its parts as blocks, each with the form it belongs to. A text
field, a password, a check box, a hidden value, a select reduced to its
chosen value, and a button. The reader draws the parts and sends the form.
*/
package libhtml

import "vsys:libdoc"

// -- The tokenizer -----------------------------------------------------------------

Token_Kind :: enum u8 {
	EOF,
	Text,
	Start,
	End,
}

MAX_ATTRS :: 16

Attr :: struct {
	name:  string,
	value: string,
}

// A token's strings live in the tokenizer's scratch until the next call.
Token :: struct {
	kind:         Token_Kind,
	name:         string,
	text:         string,
	attrs:        [MAX_ATTRS]Attr,
	nattrs:       int,
	self_closing: bool,
}

// A span in the scratch, resolved to a string once the scratch stops
// growing.
Span :: struct {
	off, len: int,
}

Tokenizer :: struct {
	src:      string,
	at:       int,
	scratch:  [dynamic]u8,
	raw_end:  string, // Inside a raw element: the name whose end tag ends it
	raw_refs: bool, // Its text decodes character references (title, textarea)
	raw_drop: bool, // Its text is dropped (script, style), or already emitted
}

tokenizer_init :: proc(t: ^Tokenizer, src: string) {
	t.src = src
	t.at = 0
	t.scratch = make([dynamic]u8, 0, 1024, context.allocator)
	t.raw_end = ""
}

tokenizer_free :: proc(t: ^Tokenizer) {
	delete(t.scratch)
	t^ = Tokenizer{}
}

// next answers the next token. Text runs until a tag or the end. A tag that
// is not one, a `<` before a space say, is text.
next :: proc(t: ^Tokenizer) -> (tok: Token) {
	clear(&t.scratch)
	if len(t.raw_end) > 0 {
		return raw_text(t)
	}
	for t.at < len(t.src) {
		c := t.src[t.at]
		if c == '<' {
			if len(t.scratch) > 0 {
				break
			}
			if tag, ok := read_tag(t); ok {
				return tag
			}
			continue
		}
		if c == '&' {
			t.at += 1
			char_ref(t)
			continue
		}
		append(&t.scratch, c)
		t.at += 1
	}
	if len(t.scratch) > 0 {
		tok.kind = .Text
		tok.text = string(t.scratch[:])
		return tok
	}
	tok.kind = .EOF
	return tok
}

// raw_text is the inside of a raw element, up to its end tag. The text
// comes first if it is kept, then the end tag on the call after.
raw_text :: proc(t: ^Tokenizer) -> (tok: Token) {
	idx, found := find_end_tag(t.src, t.at, t.raw_end)
	end := found ? idx : len(t.src)
	if end > t.at && !t.raw_drop {
		text := t.src[t.at:end]
		t.at = end
		if t.raw_refs {
			decode_into(t, text)
		} else {
			append(&t.scratch, ..transmute([]u8)text)
		}
		t.raw_drop = true
		tok.kind = .Text
		tok.text = string(t.scratch[:])
		return tok
	}
	t.at = end
	name := t.raw_end
	t.raw_end = ""
	if !found {
		tok.kind = .EOF
		return tok
	}
	t.at += 2 + len(name)
	skip_past(t, '>')
	append(&t.scratch, ..transmute([]u8)name)
	tok.kind = .End
	tok.name = string(t.scratch[:])
	return tok
}

// find_end_tag looks for `</name` from `from`, any case, followed by a space,
// a slash or `>`.
find_end_tag :: proc "contextless" (src: string, from: int, name: string) -> (int, bool) {
	i := from
	for i + 2 + len(name) <= len(src) {
		if src[i] == '<' && src[i + 1] == '/' && same_fold(src[i + 2:][:len(name)], name) {
			after := i + 2 + len(name)
			if after >= len(src) || is_space(src[after]) || src[after] == '/' || src[after] == '>' {
				return i, true
			}
		}
		i += 1
	}
	return 0, false
}

// read_tag reads what follows a `<`. A comment, a doctype and a bogus
// comment are skipped and nothing is answered. A `<` that begins nothing
// is text.
read_tag :: proc(t: ^Tokenizer) -> (tok: Token, ok: bool) {
	src := t.src
	if t.at + 1 >= len(src) {
		append(&t.scratch, '<')
		t.at += 1
		return tok, false
	}
	c := src[t.at + 1]
	switch {
	case c == '!':
		t.at += 2
		if t.at + 1 < len(src) && src[t.at] == '-' && src[t.at + 1] == '-' {
			t.at += 2
			skip_comment(t)
		} else {
			skip_past(t, '>')
		}
		return tok, false
	case c == '?':
		t.at += 2
		skip_past(t, '>')
		return tok, false
	case c == '/':
		t.at += 2
		if t.at >= len(src) || !is_alpha(src[t.at]) {
			skip_past(t, '>')
			return tok, false
		}
		name := read_name(t)
		skip_past(t, '>')
		tok.kind = .End
		tok.name = string(t.scratch[name.off:][:name.len])
		return tok, true
	case is_alpha(c):
		t.at += 1
		name := read_name(t)
		spans: [MAX_ATTRS][2]Span
		n := 0
		tok.self_closing = read_attrs(t, spans[:], &n)
		tok.kind = .Start
		tok.name = string(t.scratch[name.off:][:name.len])
		for i in 0 ..< n {
			tok.attrs[i].name = string(t.scratch[spans[i][0].off:][:spans[i][0].len])
			tok.attrs[i].value = string(t.scratch[spans[i][1].off:][:spans[i][1].len])
		}
		tok.nattrs = n
		enter_raw(t, tok.name)
		return tok, true
	case:
		append(&t.scratch, '<')
		t.at += 1
		return tok, false
	}
}

// enter_raw arms the raw state for an element whose content is not markup.
// The name must outlive the scratch, so a literal of ours is kept.
enter_raw :: proc(t: ^Tokenizer, name: string) {
	t.raw_refs = false
	t.raw_drop = true
	switch name {
	case "script":
		t.raw_end = "script"
	case "style":
		t.raw_end = "style"
	case "xmp":
		t.raw_end = "xmp"
	case "iframe":
		t.raw_end = "iframe"
	case "noembed":
		t.raw_end = "noembed"
	case "noframes":
		t.raw_end = "noframes"
	case "title":
		t.raw_end = "title"
		t.raw_refs = true
		t.raw_drop = false
	case "textarea":
		t.raw_end = "textarea"
		t.raw_refs = true
		t.raw_drop = false
	}
}

// read_name appends the tag name, lowered, and answers its span.
read_name :: proc(t: ^Tokenizer) -> Span {
	s := Span{off = len(t.scratch)}
	for t.at < len(t.src) {
		c := t.src[t.at]
		if is_space(c) || c == '/' || c == '>' {
			break
		}
		append(&t.scratch, to_lower(c))
		t.at += 1
	}
	s.len = len(t.scratch) - s.off
	return s
}

// read_attrs reads the attributes up to and past the `>`, and answers
// whether the tag closed itself.
read_attrs :: proc(t: ^Tokenizer, spans: [][2]Span, n: ^int) -> bool {
	src := t.src
	for {
		skip_space(t)
		if t.at >= len(src) {
			return false
		}
		c := src[t.at]
		if c == '>' {
			t.at += 1
			return false
		}
		if c == '/' {
			t.at += 1
			if t.at < len(src) && src[t.at] == '>' {
				t.at += 1
				return true
			}
			continue
		}
		name := Span{off = len(t.scratch)}
		for t.at < len(src) {
			c = src[t.at]
			if is_space(c) || c == '/' || c == '>' || c == '=' {
				break
			}
			append(&t.scratch, to_lower(c))
			t.at += 1
		}
		name.len = len(t.scratch) - name.off
		skip_space(t)
		value := Span{off = len(t.scratch)}
		if t.at < len(src) && src[t.at] == '=' {
			t.at += 1
			skip_space(t)
			if t.at < len(src) && (src[t.at] == '"' || src[t.at] == '\'') {
				q := src[t.at]
				t.at += 1
				for t.at < len(src) && src[t.at] != q {
					if src[t.at] == '&' {
						t.at += 1
						char_ref(t)
					} else {
						append(&t.scratch, src[t.at])
						t.at += 1
					}
				}
				if t.at < len(src) {
					t.at += 1
				}
			} else {
				for t.at < len(src) && !is_space(src[t.at]) && src[t.at] != '>' {
					if src[t.at] == '&' {
						t.at += 1
						char_ref(t)
					} else {
						append(&t.scratch, src[t.at])
						t.at += 1
					}
				}
			}
			value.len = len(t.scratch) - value.off
		}
		if name.len > 0 && n^ < len(spans) {
			spans[n^] = {name, value}
			n^ += 1
		}
	}
}

skip_comment :: proc(t: ^Tokenizer) {
	for t.at + 2 < len(t.src) {
		if t.src[t.at] == '-' && t.src[t.at + 1] == '-' && t.src[t.at + 2] == '>' {
			t.at += 3
			return
		}
		t.at += 1
	}
	t.at = len(t.src)
}

// skip_past moves to just after the next `c`, or to the end.
skip_past :: proc(t: ^Tokenizer, c: u8) {
	for t.at < len(t.src) {
		if t.src[t.at] == c {
			t.at += 1
			return
		}
		t.at += 1
	}
}

skip_space :: proc(t: ^Tokenizer) {
	for t.at < len(t.src) && is_space(t.src[t.at]) {
		t.at += 1
	}
}

// decode_into appends `text` to the scratch with its character references
// decoded, for the raw text of a title.
decode_into :: proc(t: ^Tokenizer, text: string) {
	saved_src, saved_at := t.src, t.at
	t.src = text
	t.at = 0
	for t.at < len(text) {
		if text[t.at] == '&' {
			t.at += 1
			char_ref(t)
		} else {
			append(&t.scratch, text[t.at])
			t.at += 1
		}
	}
	t.src, t.at = saved_src, saved_at
}

/*
char_ref reads a character reference just past its `&` and appends what it
means. A number, `&#169;` or `&#xA9;`, is a code point. A name is one of the
few a page uses. One that is neither, or has no `;`, is the `&` itself and
the text goes on from there.
*/
char_ref :: proc(t: ^Tokenizer) {
	src := t.src
	at := t.at
	if at < len(src) && src[at] == '#' {
		at += 1
		hex := at < len(src) && (src[at] == 'x' || src[at] == 'X')
		if hex {
			at += 1
		}
		code := 0
		digits := 0
		for at < len(src) {
			c := src[at]
			v := -1
			switch {
			case c >= '0' && c <= '9':
				v = int(c - '0')
			case hex && c >= 'a' && c <= 'f':
				v = int(c - 'a') + 10
			case hex && c >= 'A' && c <= 'F':
				v = int(c - 'A') + 10
			}
			if v < 0 {
				break
			}
			code = min(code * (hex ? 16 : 10) + v, 0x110000)
			digits += 1
			at += 1
		}
		if digits > 0 && at < len(src) && src[at] == ';' {
			if code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) {
				code = 0xFFFD
			}
			append_rune(&t.scratch, code)
			t.at = at + 1
			return
		}
		append(&t.scratch, '&')
		return
	}
	end := at
	for end < len(src) && end - at < 32 && is_alnum(src[end]) {
		end += 1
	}
	if end > at && end < len(src) && src[end] == ';' {
		if s, ok := named(src[at:end]); ok {
			append(&t.scratch, ..transmute([]u8)s)
			t.at = end + 1
			return
		}
	}
	append(&t.scratch, '&')
}

// named answers the text of a named reference a page is likely to use.
named :: proc "contextless" (name: string) -> (string, bool) {
	switch name {
	case "amp":
		return "&", true
	case "lt":
		return "<", true
	case "gt":
		return ">", true
	case "quot":
		return "\"", true
	case "apos":
		return "'", true
	case "nbsp":
		return " ", true
	case "shy":
		return "", true
	case "copy":
		return "©", true
	case "reg":
		return "®", true
	case "trade":
		return "™", true
	case "deg":
		return "°", true
	case "middot":
		return "·", true
	case "bull":
		return "•", true
	case "hellip":
		return "…", true
	case "ndash":
		return "–", true
	case "mdash":
		return "—", true
	case "lsquo":
		return "‘", true
	case "rsquo":
		return "’", true
	case "ldquo":
		return "“", true
	case "rdquo":
		return "”", true
	case "laquo":
		return "«", true
	case "raquo":
		return "»", true
	case "times":
		return "×", true
	case "euro":
		return "€", true
	case "pound":
		return "£", true
	case "yen":
		return "¥", true
	case "cent":
		return "¢", true
	case "sect":
		return "§", true
	case "para":
		return "¶", true
	case "larr":
		return "←", true
	case "rarr":
		return "→", true
	case "uarr":
		return "↑", true
	case "darr":
		return "↓", true
	case "hearts":
		return "♥", true
	case "check":
		return "✓", true
	}
	return "", false
}

append_rune :: proc(buf: ^[dynamic]u8, code: int) {
	switch {
	case code < 0x80:
		append(buf, u8(code))
	case code < 0x800:
		append(buf, u8(0xC0 | code >> 6), u8(0x80 | code & 0x3F))
	case code < 0x10000:
		append(buf, u8(0xE0 | code >> 12), u8(0x80 | (code >> 6) & 0x3F), u8(0x80 | code & 0x3F))
	case:
		append(buf, u8(0xF0 | code >> 18), u8(0x80 | (code >> 12) & 0x3F), u8(0x80 | (code >> 6) & 0x3F), u8(0x80 | code & 0x3F))
	}
}

is_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

is_alpha :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_alnum :: proc "contextless" (c: u8) -> bool {
	return is_alpha(c) || (c >= '0' && c <= '9')
}

to_lower :: proc "contextless" (c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

same_fold :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if to_lower(a[i]) != to_lower(b[i]) {
			return false
		}
	}
	return true
}

// -- The builder -------------------------------------------------------------------

// A link or an image the paragraph holds, added after it. A link's name is
// in the paragraph. An image's alt and every source are in `aux`.
Pending :: struct {
	image:    bool,
	name_off: int,
	name_len: int,
	href_off: int,
	href_len: int,
}

Builder :: struct {
	d:       ^libdoc.Doc,
	para:    [dynamic]u8,
	aux:     [dynamic]u8,
	pending: [dynamic]Pending,
	heading: int, // The level of the heading being gathered, or 0
	item:    bool, // Inside `<li>`, `<dt>` or `<dd>`
	quote:   int, // `<blockquote>` depth
	pre:     int, // `<pre>` depth
	drop:    int, // Depth inside an element whose text is not shown
	title:   bool, // Inside `<title>`, which sits in the dropped `<head>`
	row:     bool, // Inside `<tr>`
	a_open:  bool,
	a_start: int, // Where the open link's name began in `para`
	a_href:  Span, // Its target in `aux`
	a_images: int, // Images noted since it opened
	// The form being built, and the part of it whose text is gathering.
	form:      int,
	in_select: bool,
	sel_name:  Span,
	sel_value: Span,
	sel_set:   bool, // A selected option was seen
	in_area:   bool, // `<textarea>`: its text is the value
	area_name: Span,
	in_button: bool, // `<button>`: its text is the label
	btn_name:  Span,
	btn_value: Span,
}

// parse turns `src` into the blocks of `d`.
parse :: proc(d: ^libdoc.Doc, src: string) {
	t: Tokenizer
	tokenizer_init(&t, src)
	defer tokenizer_free(&t)
	b: Builder
	b.d = d
	b.form = -1
	b.para = make([dynamic]u8, 0, 1024, context.allocator)
	b.aux = make([dynamic]u8, 0, 256, context.allocator)
	b.pending = make([dynamic]Pending, 0, 16, context.allocator)
	defer delete(b.para)
	defer delete(b.aux)
	defer delete(b.pending)

	for {
		tok := next(&t)
		switch tok.kind {
		case .EOF:
			flush(&b)
			return
		case .Text:
			text(&b, tok.text)
		case .Start:
			start(&b, &tok)
		case .End:
			end(&b, tok.name)
		}
	}
}

// text gathers a run into the paragraph. Outside `<pre>`, white space
// collapses to one space and none leads.
text :: proc(b: ^Builder, s: string) {
	if b.drop > 0 && !b.title {
		return
	}
	if b.in_select {
		return
	}
	if b.pre > 0 || b.in_area {
		append(&b.para, ..transmute([]u8)s)
		return
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if is_space(c) {
			if len(b.para) > 0 && b.para[len(b.para) - 1] != ' ' {
				append(&b.para, ' ')
			}
		} else {
			append(&b.para, c)
		}
	}
}

// start is a start tag. A block element flushes what came before it and
// says what the text after it is.
start :: proc(b: ^Builder, tok: ^Token) {
	if tok.name == "title" {
		b.title = true
		return
	}
	if b.drop > 0 {
		// `</head>` may be left out, and the body is never dropped.
		if tok.name == "body" {
			b.drop = 0
		} else if drops(tok.name) && !tok.self_closing {
			b.drop += 1
		}
		return
	}
	switch tok.name {
	case "h1", "h2", "h3", "h4", "h5", "h6":
		flush(b)
		b.heading = min(int(tok.name[1] - '0'), 3)
	case "li", "dt", "dd":
		flush(b)
		b.item = true
	case "blockquote":
		flush(b)
		b.quote += 1
	case "pre":
		flush(b)
		b.pre += 1
	case "hr":
		flush(b)
		libdoc.doc_add(b.d, .Rule, "")
	case "br":
		flush(b)
	case "tr":
		flush(b)
		b.row = true
	case "td", "th":
		if b.row && len(b.para) > 0 {
			if b.para[len(b.para) - 1] != ' ' {
				append(&b.para, ' ')
			}
			append(&b.para, '|', ' ')
		}
	case "img":
		image(b, tok)
	case "form":
		flush(b)
		action, _ := attr(tok, "action")
		method, _ := attr(tok, "method")
		b.form = libdoc.doc_form(b.d, action, same_fold(method, "post"))
	case "input":
		input(b, tok)
	case "select":
		flush(b)
		name, _ := attr(tok, "name")
		b.in_select = true
		b.sel_name = put_aux(b, name)
		b.sel_value = Span{}
		b.sel_set = false
	case "option":
		if b.in_select {
			_, selected := attr(tok, "selected")
			value, has := attr(tok, "value")
			if has && (!b.sel_set || selected) {
				b.sel_value = put_aux(b, value)
				b.sel_set = b.sel_set || selected
			}
		}
	case "textarea":
		flush(b)
		name, _ := attr(tok, "name")
		b.in_area = true
		b.area_name = put_aux(b, name)
	case "button":
		flush(b)
		kind, has := attr(tok, "type")
		if has && !same_fold(kind, "submit") {
			return
		}
		name, _ := attr(tok, "name")
		value, _ := attr(tok, "value")
		b.in_button = true
		b.btn_name = put_aux(b, name)
		b.btn_value = put_aux(b, value)
	case "a":
		if b.a_open {
			close_link(b)
		}
		if href, ok := attr(tok, "href"); ok && len(href) > 0 && href != "#" {
			b.a_open = true
			b.a_start = len(b.para)
			b.a_href = put_aux(b, href)
			b.a_images = 0
		}
	case:
		if drops(tok.name) {
			flush(b)
			if !tok.self_closing {
				b.drop += 1
			}
		} else if is_block(tok.name) {
			flush(b)
		}
	}
}

// end is an end tag. The block it closes flushes, and the kind it set is
// unset.
end :: proc(b: ^Builder, name: string) {
	if name == "title" {
		if b.title {
			trim_para(b)
			libdoc.doc_title(b.d, string(b.para[:]))
			clear(&b.para)
			b.title = false
		}
		return
	}
	if b.drop > 0 {
		if drops(name) {
			b.drop -= 1
		}
		return
	}
	switch name {
	case "h1", "h2", "h3", "h4", "h5", "h6":
		flush(b)
		b.heading = 0
	case "li", "dt", "dd":
		flush(b)
		b.item = false
	case "ul", "ol", "dl":
		// `</li>` may be left out, so the list's end ends its last item.
		flush(b)
		b.item = false
	case "blockquote":
		flush(b)
		b.quote = max(b.quote - 1, 0)
	case "pre":
		flush(b)
		b.pre = max(b.pre - 1, 0)
	case "tr":
		flush(b)
		b.row = false
	case "a":
		if b.a_open {
			close_link(b)
		}
	case "form":
		flush(b)
		b.form = -1
	case "select":
		if b.in_select {
			b.in_select = false
			sel := aux_text(b, b.sel_name)
			libdoc.doc_field(b.d, .Field, sel, sel, aux_text(b, b.sel_value), b.form)
		}
	case "textarea":
		if b.in_area {
			b.in_area = false
			area := aux_text(b, b.area_name)
			libdoc.doc_field(b.d, .Field, area, area, string(b.para[:]), b.form)
			clear(&b.para)
		}
	case "button":
		if b.in_button {
			b.in_button = false
			trim_para(b)
			label := string(b.para[:])
			if len(label) == 0 {
				label = "Submit"
			}
			libdoc.doc_field(b.d, .Submit, label, aux_text(b, b.btn_name), aux_text(b, b.btn_value), b.form)
			clear(&b.para)
		}
	case:
		if is_block(name) {
			flush(b)
		}
	}
}

// input is an `<input>`: a part by its type, labelled by its placeholder
// or its name. A kind this reader does not draw, a file or a colour say,
// is left out.
input :: proc(b: ^Builder, tok: ^Token) {
	kind, _ := attr(tok, "type")
	name, _ := attr(tok, "name")
	value, _ := attr(tok, "value")
	placeholder, _ := attr(tok, "placeholder")
	label := len(placeholder) > 0 ? placeholder : name
	part := libdoc.Kind.Field
	switch {
	case len(kind) == 0, same_fold(kind, "text"), same_fold(kind, "email"), same_fold(kind, "search"), same_fold(kind, "url"), same_fold(kind, "tel"), same_fold(kind, "number"):
		part = .Field
	case same_fold(kind, "password"):
		part = .Secret
	case same_fold(kind, "checkbox"), same_fold(kind, "radio"):
		part = .Check
		_, checked := attr(tok, "checked")
		if len(value) == 0 {
			value = "on"
		}
		if !checked {
			value = ""
		}
	case same_fold(kind, "hidden"):
		part = .Hidden
	case same_fold(kind, "submit"):
		part = .Submit
		label = len(value) > 0 ? value : "Submit"
	case:
		return
	}
	flush(b)
	libdoc.doc_field(b.d, part, label, name, value, b.form)
}

aux_text :: proc "contextless" (b: ^Builder, s: Span) -> string {
	return string(b.aux[s.off:][:s.len])
}

// image notes an `<img>` for after the paragraph. One with no alt shows
// its source, as a gemtext link with no name does.
image :: proc(b: ^Builder, tok: ^Token) {
	src, ok := attr(tok, "src")
	if !ok || len(src) == 0 {
		return
	}
	alt, _ := attr(tok, "alt")
	p := Pending{image = true}
	s := put_aux(b, alt)
	p.name_off, p.name_len = s.off, s.len
	h := put_aux(b, src)
	p.href_off, p.href_len = h.off, h.len
	append(&b.pending, p)
	if b.a_open {
		b.a_images += 1
	}
}

// close_link ends the open link. Its name is the paragraph's text since it
// opened. One that showed nothing, no text and no image, was never a link
// to press and is dropped.
close_link :: proc(b: ^Builder) {
	b.a_open = false
	p := Pending{}
	p.name_off = min(b.a_start, len(b.para))
	p.name_len = len(b.para) - p.name_off
	name := trim(string(b.para[p.name_off:][:p.name_len]))
	if len(name) == 0 && b.a_images == 0 {
		return
	}
	// A heading's own anchor, `<a href="#id">#</a>`, is the page pointing at
	// itself. It goes, and its mark goes from the text.
	if b.aux[b.a_href.off] == '#' && (name == "#" || name == "\u00b6" || name == "\u00a7") {
		resize(&b.para, p.name_off)
		return
	}
	p.href_off, p.href_len = b.a_href.off, b.a_href.len
	append(&b.pending, p)
}

trim :: proc "contextless" (s: string) -> string {
	t := s
	for len(t) > 0 && is_space(t[len(t) - 1]) {
		t = t[:len(t) - 1]
	}
	for len(t) > 0 && is_space(t[0]) {
		t = t[1:]
	}
	return t
}

put_aux :: proc(b: ^Builder, s: string) -> Span {
	sp := Span{off = len(b.aux), len = len(s)}
	append(&b.aux, ..transmute([]u8)s)
	return sp
}

attr :: proc "contextless" (tok: ^Token, name: string) -> (string, bool) {
	for i in 0 ..< tok.nattrs {
		if tok.attrs[i].name == name {
			return tok.attrs[i].value, true
		}
	}
	return "", false
}

trim_para :: proc(b: ^Builder) {
	for len(b.para) > 0 && is_space(b.para[len(b.para) - 1]) {
		pop(&b.para)
	}
	// Leading space never gathers outside `<pre>`, so only the end needs it.
}

/*
flush adds the paragraph gathered so far as the block the context says,
then the links and images it held, and empties the gathering. A link that is
still open when a block ends closes here, so its name is what was shown. A
paragraph or an item that is nothing but one link is that link. A gemtext
author would have written it so, and a menu of links is not each twice.
*/
flush :: proc(b: ^Builder) {
	if b.a_open {
		close_link(b)
		// Reopen it for the text that follows, at the new paragraph's start.
		b.a_open = true
		b.a_start = 0
		b.a_images = 0
	}
	if b.pre > 0 {
		// The first newline after `<pre>` is the tag's own, not the text's.
		s := string(b.para[:])
		if len(s) > 0 && s[0] == '\n' {
			s = s[1:]
		}
		if len(s) > 0 {
			libdoc.doc_add(b.d, .Pre, s)
		}
	} else {
		trim_para(b)
		s := string(b.para[:])
		if len(s) > 0 {
			kind := libdoc.Kind.Text
			switch {
			case b.heading > 0:
				kind = .Heading
			case b.item:
				kind = .Item
			case b.quote > 0:
				kind = .Quote
			}
			if only, ok := only_link(b, s); ok && kind != .Heading {
				b.pending[only].name_len = -1 // Taken by the block itself
				libdoc.doc_add(b.d, .Link, s, string(b.aux[b.pending[only].href_off:][:b.pending[only].href_len]))
			} else {
				libdoc.doc_add(b.d, kind, s, "", b.heading)
			}
		}
	}
	for &p in b.pending {
		if p.name_len < 0 {
			continue
		}
		href := string(b.aux[p.href_off:][:p.href_len])
		name: string
		if p.image {
			name = string(b.aux[p.name_off:][:p.name_len])
		} else {
			end := min(p.name_off + p.name_len, len(b.para))
			name = trim(string(b.para[p.name_off:end]))
		}
		libdoc.doc_add(b.d, p.image ? .Image : .Link, len(name) > 0 ? name : href, href)
	}
	clear(&b.pending)
	clear(&b.para)
	// `aux` is kept: an open link's target lives there, and a page's
	// targets are small beside the page.
}

// only_link answers the one pending link whose name is the whole paragraph,
// if the paragraph holds one link and nothing else.
only_link :: proc(b: ^Builder, s: string) -> (int, bool) {
	found := -1
	for &p, i in b.pending {
		if p.image {
			continue
		}
		if found >= 0 {
			return -1, false
		}
		found = i
	}
	if found < 0 {
		return -1, false
	}
	p := &b.pending[found]
	end := min(p.name_off + p.name_len, len(b.para))
	return found, trim(string(b.para[p.name_off:end])) == s
}

// drops names an element whose text is not part of the page.
drops :: proc "contextless" (name: string) -> bool {
	switch name {
	case "head", "script", "style", "template", "datalist", "svg", "math", "object", "noscript", "iframe", "canvas", "video", "audio", "map":
		return true
	}
	return false
}

// is_block names an element that ends the paragraph before it and after.
is_block :: proc "contextless" (name: string) -> bool {
	switch name {
	case "p", "div", "ul", "ol", "dl", "table", "thead", "tbody", "tfoot", "caption", "section", "article", "header", "footer", "nav", "aside", "main", "figure", "figcaption", "fieldset", "legend", "details", "summary", "address", "center", "body", "html", "menu", "hgroup":
		return true
	}
	return false
}
