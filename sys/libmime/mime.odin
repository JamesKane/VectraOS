/*
libmime -- RFC 5322 headers and RFC 2045 parts, for mail and for
everything that borrowed mail's shape.

`docs/WEB.md` section 4. A message is a header block, an empty line and
a body. A header is `Name: value`, folded over lines that begin with
white space, and this unfolds it. A body is one part, or a multipart
whose parts are cut at its boundary and are messages of their own, one
level down. A part's bytes are decoded from their transfer encoding,
quoted-printable or base64, and a Latin-1 part is brought to UTF-8. A
header word encoded RFC 2047's way, `=?utf-8?q?...?=`, decodes too.

`parse` gives the tree, `header` a value by name, `param` a parameter of
one, `address` the name and box of a sender, and `text_body` the part a
reader shows. Nothing here reaches ring 3, so a host harness builds it.

Not yet: RFC 2231's split parameters, `message/rfc822` parts opened as
messages, and charsets past Latin-1 and UTF-8, which are kept as bytes.
*/
package libmime

Header :: struct {
	name:  string,
	value: string,
}

// A header block, unfolded into `text`, its lines as `list`.
Headers :: struct {
	text: string,
	list: []Header,
}

Part :: struct {
	headers:  Headers,
	type:     string, // The media type, lower case: `text/plain`
	charset:  string, // Lower case, or empty
	filename: string, // From the disposition, or the type's name
	body:     string, // The part's bytes, decoded; empty for a multipart
	parts:    []Part, // A multipart's parts
}

// parse reads a message, or one part of one, into a tree.
parse :: proc(text: string, allocator := context.allocator) -> (p: Part, ok: bool) {
	context.allocator = allocator
	head, body := split_head(text)
	p.headers = parse_headers(head)
	ctype, has_type := header(&p.headers, "content-type")
	buf: [256]u8
	if has_type {
		p.type = lower_clone(media_type(ctype))
		if cs, found := param(ctype, "charset", buf[:]); found {
			p.charset = lower_clone(cs)
		}
	} else {
		p.type = clone("text/plain")
	}
	if disp, has_disp := header(&p.headers, "content-disposition"); has_disp {
		if fn, found := param(disp, "filename", buf[:]); found {
			p.filename = decode_words_clone(fn)
		}
	}
	if p.filename == "" && has_type {
		if fn, found := param(ctype, "name", buf[:]); found {
			p.filename = decode_words_clone(fn)
		}
	}
	if has_prefix(p.type, "multipart/") {
		if boundary, found := param(ctype, "boundary", buf[:]); found {
			p.parts = split_parts(body, boundary)
			return p, true
		}
	}
	enc := ""
	if e, has_enc := header(&p.headers, "content-transfer-encoding"); has_enc {
		enc = trim(e)
	}
	decoded: []u8
	switch {
	case equal_fold(enc, "quoted-printable"):
		decoded = decode_qp(body)
	case equal_fold(enc, "base64"):
		decoded = decode_base64(body)
	case:
		decoded = make([]u8, len(body))
		copy(decoded, body)
	}
	if p.charset == "iso-8859-1" || p.charset == "latin1" || p.charset == "windows-1252" {
		wide := latin1_to_utf8(string(decoded))
		delete(decoded)
		decoded = wide
	}
	p.body = string(decoded)
	return p, true
}

part_free :: proc(p: ^Part, allocator := context.allocator) {
	context.allocator = allocator
	delete(p.headers.text)
	delete(p.headers.list)
	delete(p.type)
	delete(p.charset)
	delete(p.filename)
	delete(p.body)
	for &sub in p.parts {
		part_free(&sub)
	}
	delete(p.parts)
	p^ = Part{}
}

// split_head parts a message at its first empty line.
split_head :: proc "contextless" (text: string) -> (head: string, body: string) #no_bounds_check {
	i := 0
	for i < len(text) {
		// The end of a line: where the next begins.
		e := i
		for e < len(text) && text[e] != '\n' {
			e += 1
		}
		line := text[i:e]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if len(line) == 0 {
			return text[:i], text[min(e + 1, len(text)):]
		}
		i = e + 1
	}
	return text, ""
}

/*
parse_headers unfolds a header block and lists its lines. A line that
begins with a space or a tab continues the one before, and the fold
becomes one space. A line with no colon is dropped.
*/
parse_headers :: proc(head: string) -> (h: Headers) {
	text := make([]u8, len(head))
	n := 0
	i := 0
	for i < len(head) {
		e := i
		for e < len(head) && head[e] != '\n' {
			e += 1
		}
		line := head[i:e]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		i = e + 1
		if len(line) == 0 {
			continue
		}
		if (line[0] == ' ' || line[0] == '\t') && n > 0 {
			text[n] = ' '
			n += 1
			n += copy(text[n:], trim(line))
			continue
		}
		if n > 0 {
			text[n] = '\n'
			n += 1
		}
		n += copy(text[n:], line)
	}
	h.text = string(text[:n])
	count := 0
	for k in 0 ..< n {
		if text[k] == '\n' {
			count += 1
		}
	}
	if n > 0 {
		count += 1
	}
	list := make([dynamic]Header, 0, count)
	at := 0
	for at < n {
		e := at
		for e < n && text[e] != '\n' {
			e += 1
		}
		line := string(text[at:e])
		at = e + 1
		colon := -1
		for k in 0 ..< len(line) {
			if line[k] == ':' {
				colon = k
				break
			}
		}
		if colon <= 0 {
			continue
		}
		append(&list, Header{name = trim(line[:colon]), value = trim(line[colon + 1:])})
	}
	h.list = list[:]
	return h
}

// header answers the first header called `name`, case not counting.
header :: proc "contextless" (h: ^Headers, name: string) -> (string, bool) {
	for e in h.list {
		if equal_fold(e.name, name) {
			return e.value, true
		}
	}
	return "", false
}

// media_type answers a Content-Type's type, before any parameter, as
// written.
media_type :: proc "contextless" (value: string) -> string {
	for i in 0 ..< len(value) {
		if value[i] == ';' {
			return trim(value[:i])
		}
	}
	return trim(value)
}

/*
param answers a parameter of a header value: `charset=utf-8` or
`name="a file.txt"`, quotes off, case of the name not counting. A quoted
value's `\"` is unescaped into `into`.
*/
param :: proc "contextless" (value: string, name: string, into: []u8) -> (string, bool) #no_bounds_check {
	i := 0
	for i < len(value) && value[i] != ';' {
		i += 1
	}
	for i < len(value) {
		i += 1 // Past the semicolon
		for i < len(value) && is_space(value[i]) {
			i += 1
		}
		ns := i
		for i < len(value) && value[i] != '=' && value[i] != ';' {
			i += 1
		}
		key := trim(value[ns:i])
		if i >= len(value) || value[i] != '=' {
			continue
		}
		i += 1
		for i < len(value) && is_space(value[i]) {
			i += 1
		}
		n := 0
		if i < len(value) && value[i] == '"' {
			i += 1
			for i < len(value) && value[i] != '"' {
				if value[i] == '\\' && i + 1 < len(value) {
					i += 1
				}
				if n < len(into) {
					into[n] = value[i]
					n += 1
				}
				i += 1
			}
			i += 1
		} else {
			for i < len(value) && value[i] != ';' && !is_space(value[i]) {
				if n < len(into) {
					into[n] = value[i]
					n += 1
				}
				i += 1
			}
		}
		if equal_fold(key, name) {
			return string(into[:n]), true
		}
		for i < len(value) && value[i] != ';' {
			i += 1
		}
	}
	return "", false
}

/*
address answers the first mailbox of a header: `Name <box@host>` gives
both, `box@host (Name)` too, and a bare `box@host` a name that is empty.
The name's encoded words are decoded into `into`, and its quotes taken off.
*/
address :: proc "contextless" (value: string, into: []u8) -> (name: string, box: string) #no_bounds_check {
	v := trim(value)
	for i in 0 ..< len(v) {
		if v[i] == ',' && !inside_quotes(v, i) {
			v = v[:i]
			break
		}
	}
	lt := -1
	gt := -1
	for i in 0 ..< len(v) {
		if v[i] == '<' && lt < 0 {
			lt = i
		}
		if v[i] == '>' {
			gt = i
		}
	}
	if lt >= 0 && gt > lt {
		box = trim(v[lt + 1:gt])
		raw := trim(v[:lt])
		if len(raw) >= 2 && raw[0] == '"' && raw[len(raw) - 1] == '"' {
			raw = raw[1:len(raw) - 1]
		}
		name = decode_words(raw, into)
		return name, box
	}
	lp := -1
	rp := -1
	for i in 0 ..< len(v) {
		if v[i] == '(' && lp < 0 {
			lp = i
		}
		if v[i] == ')' {
			rp = i
		}
	}
	if lp >= 0 && rp > lp {
		return decode_words(trim(v[lp + 1:rp]), into), trim(v[:lp])
	}
	return "", v
}

@(private = "file")
inside_quotes :: proc "contextless" (s: string, at: int) -> bool #no_bounds_check {
	q := false
	for i in 0 ..< at {
		if s[i] == '"' {
			q = !q
		}
	}
	return q
}

// text_body answers the part a reader shows: the first `text/plain`, else
// the first `text/html`, searched through the parts in order.
text_body :: proc(p: ^Part) -> (body: string, type: string) {
	if b, t, found := find_text(p, "text/plain"); found {
		return b, t
	}
	if b, t, found := find_text(p, "text/html"); found {
		return b, t
	}
	if len(p.parts) == 0 && has_prefix(p.type, "text/") {
		return p.body, p.type
	}
	return "", ""
}

@(private = "file")
find_text :: proc(p: ^Part, want: string) -> (body: string, type: string, found: bool) {
	if len(p.parts) == 0 {
		if p.type == want && p.filename == "" {
			return p.body, p.type, true
		}
		return "", "", false
	}
	for &sub in p.parts {
		if b, t, f := find_text(&sub, want); f {
			return b, t, true
		}
	}
	return "", "", false
}

// -- Multipart -------------------------------------------------------------------

// split_parts cuts a multipart body at `--boundary` lines. The preamble
// before the first and the epilogue after `--boundary--` are dropped.
@(private = "file")
split_parts :: proc(body: string, boundary: string) -> []Part {
	list := make([dynamic]Part, 0, 4)
	start := -1
	i := 0
	for i <= len(body) {
		e := i
		for e < len(body) && body[e] != '\n' {
			e += 1
		}
		line := body[i:e]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		is_delim := len(line) >= len(boundary) + 2 && line[0] == '-' && line[1] == '-' && line[2:2 + len(boundary)] == boundary
		is_end := is_delim && len(line) >= len(boundary) + 4 && line[2 + len(boundary):2 + len(boundary) + 2] == "--"
		if is_delim {
			if start >= 0 {
				// The part ends before this line's CRLF, which is the delimiter's.
				stop := i
				if stop > start && body[stop - 1] == '\n' {
					stop -= 1
				}
				if stop > start && body[stop - 1] == '\r' {
					stop -= 1
				}
				if sub, ok := parse(body[start:stop]); ok {
					append(&list, sub)
				}
			}
			if is_end {
				break
			}
			start = e + 1
		}
		if e >= len(body) {
			break
		}
		i = e + 1
	}
	return list[:]
}

// -- Encodings -------------------------------------------------------------------

// decode_qp decodes quoted-printable: `=XX` a byte, `=` at a line's end a
// soft break, and trailing white space on a line dropped.
decode_qp :: proc(text: string) -> []u8 {
	out := make([]u8, len(text))
	n := 0
	i := 0
	for i < len(text) {
		c := text[i]
		if c == '=' {
			if i + 2 < len(text) && is_hex(text[i + 1]) && is_hex(text[i + 2]) {
				out[n] = hex_val(text[i + 1]) << 4 | hex_val(text[i + 2])
				n += 1
				i += 3
				continue
			}
			// A soft break: `=` then optional white space then the newline.
			j := i + 1
			for j < len(text) && (text[j] == ' ' || text[j] == '\t') {
				j += 1
			}
			if j < len(text) && text[j] == '\r' {
				j += 1
			}
			if j < len(text) && text[j] == '\n' {
				i = j + 1
				continue
			}
			if j >= len(text) {
				break
			}
		}
		if c == ' ' || c == '\t' {
			// White space before a line's end is dropped.
			j := i
			for j < len(text) && (text[j] == ' ' || text[j] == '\t') {
				j += 1
			}
			if j >= len(text) || text[j] == '\n' || text[j] == '\r' {
				i = j
				continue
			}
		}
		out[n] = c
		n += 1
		i += 1
	}
	return out[:n]
}

// decode_base64 decodes base64, white space anywhere in it skipped.
decode_base64 :: proc(text: string) -> []u8 {
	out := make([]u8, len(text) * 3 / 4 + 3)
	n := 0
	acc := u32(0)
	bits := 0
	for i in 0 ..< len(text) {
		c := text[i]
		v := 0
		switch {
		case c >= 'A' && c <= 'Z':
			v = int(c - 'A')
		case c >= 'a' && c <= 'z':
			v = int(c - 'a') + 26
		case c >= '0' && c <= '9':
			v = int(c - '0') + 52
		case c == '+' || c == '-':
			v = 62
		case c == '/' || c == '_':
			v = 63
		case c == '=':
			bits = 0
			acc = 0
			continue
		case:
			continue
		}
		acc = acc << 6 | u32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			out[n] = u8(acc >> uint(bits))
			n += 1
			acc &= (1 << uint(bits)) - 1
		}
	}
	return out[:n]
}

/*
decode_words decodes RFC 2047's encoded words in a header value into
`into`: `=?charset?Q?text?=` with `_` a space and `=XX` a byte, or `?B?`
base64. Two encoded words with only white space between join. A Latin-1
word is brought to UTF-8, any other charset's bytes are kept.
*/
decode_words :: proc "contextless" (value: string, into: []u8) -> string #no_bounds_check {
	n := 0
	i := 0
	after_word := false
	for i < len(value) && n < len(into) {
		if value[i] == '=' && i + 1 < len(value) && value[i + 1] == '?' {
			if word_len, text_n := decode_word(value[i:], into[n:]); word_len > 0 {
				n += text_n
				i += word_len
				after_word = true
				continue
			}
		}
		if after_word && is_space(value[i]) {
			// White space between two encoded words is not text.
			j := i
			for j < len(value) && is_space(value[j]) {
				j += 1
			}
			if j + 1 < len(value) && value[j] == '=' && value[j + 1] == '?' {
				i = j
				continue
			}
		}
		after_word = false
		into[n] = value[i]
		n += 1
		i += 1
	}
	return string(into[:n])
}

@(private = "file")
decode_word :: proc "contextless" (s: string, into: []u8) -> (word_len: int, text_n: int) #no_bounds_check {
	// =?charset?E?text?=
	q1 := 1
	q2 := -1
	q3 := -1
	for i in 2 ..< len(s) {
		if s[i] == '?' {
			if q2 < 0 {
				q2 = i
			} else if q3 < 0 {
				q3 = i
				break
			}
		}
	}
	if q2 < 0 || q3 < 0 || q3 != q2 + 2 {
		return 0, 0
	}
	end := -1
	for i in q3 + 1 ..< len(s) - 1 {
		if s[i] == '?' && s[i + 1] == '=' {
			end = i
			break
		}
	}
	if end < 0 {
		return 0, 0
	}
	charset := s[q1 + 1:q2]
	enc := s[q2 + 1]
	text := s[q3 + 1:end]
	tmp: [512]u8
	n := 0
	switch enc {
	case 'Q', 'q':
		i := 0
		for i < len(text) && n < len(tmp) {
			c := text[i]
			if c == '_' {
				tmp[n] = ' '
				n += 1
				i += 1
			} else if c == '=' && i + 2 < len(text) && is_hex(text[i + 1]) && is_hex(text[i + 2]) {
				tmp[n] = hex_val(text[i + 1]) << 4 | hex_val(text[i + 2])
				n += 1
				i += 3
			} else {
				tmp[n] = c
				n += 1
				i += 1
			}
		}
	case 'B', 'b':
		n = base64_into(text, tmp[:])
	case:
		return 0, 0
	}
	latin := equal_fold(charset, "iso-8859-1") || equal_fold(charset, "latin1") || equal_fold(charset, "windows-1252")
	k := 0
	for i in 0 ..< n {
		c := tmp[i]
		if latin && c >= 0x80 {
			if k + 2 > len(into) {
				break
			}
			into[k] = 0xC0 | c >> 6
			into[k + 1] = 0x80 | c & 0x3F
			k += 2
			continue
		}
		if k >= len(into) {
			break
		}
		into[k] = c
		k += 1
	}
	return end + 2, k
}

// base64_into is decode_base64 without the heap, for a header word.
@(private = "file")
base64_into :: proc "contextless" (text: string, out: []u8) -> int #no_bounds_check {
	n := 0
	acc := u32(0)
	bits := 0
	for i in 0 ..< len(text) {
		c := text[i]
		v := 0
		switch {
		case c >= 'A' && c <= 'Z':
			v = int(c - 'A')
		case c >= 'a' && c <= 'z':
			v = int(c - 'a') + 26
		case c >= '0' && c <= '9':
			v = int(c - '0') + 52
		case c == '+':
			v = 62
		case c == '/':
			v = 63
		case:
			continue
		}
		acc = acc << 6 | u32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			if n >= len(out) {
				return n
			}
			out[n] = u8(acc >> uint(bits))
			n += 1
			acc &= (1 << uint(bits)) - 1
		}
	}
	return n
}

// latin1_to_utf8 brings ISO 8859-1 bytes to UTF-8.
latin1_to_utf8 :: proc(text: string) -> []u8 {
	wide := 0
	for i in 0 ..< len(text) {
		if text[i] >= 0x80 {
			wide += 1
		}
	}
	out := make([]u8, len(text) + wide)
	n := 0
	for i in 0 ..< len(text) {
		c := text[i]
		if c >= 0x80 {
			out[n] = 0xC0 | c >> 6
			out[n + 1] = 0x80 | c & 0x3F
			n += 2
		} else {
			out[n] = c
			n += 1
		}
	}
	return out
}

// -- Small things ------------------------------------------------------------------

@(private = "file")
decode_words_clone :: proc(s: string) -> string {
	buf: [512]u8
	return clone(decode_words(s, buf[:]))
}

@(private = "file")
lower_clone :: proc(s: string) -> string {
	own := make([]u8, len(s))
	for i in 0 ..< len(s) {
		c := s[i]
		own[i] = c >= 'A' && c <= 'Z' ? c + 32 : c
	}
	return string(own)
}

@(private = "file")
clone :: proc(s: string) -> string {
	if len(s) == 0 {
		return ""
	}
	own := make([]u8, len(s))
	copy(own, s)
	return string(own)
}

// equal_fold compares two strings with ASCII case not counting.
equal_fold :: proc "contextless" (a, b: string) -> bool #no_bounds_check {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x >= 'A' && x <= 'Z' {
			x += 32
		}
		if y >= 'A' && y <= 'Z' {
			y += 32
		}
		if x != y {
			return false
		}
	}
	return true
}

has_prefix :: proc "contextless" (s, prefix: string) -> bool #no_bounds_check {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

is_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

is_hex :: proc "contextless" (c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

hex_val :: proc "contextless" (c: u8) -> u8 {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case:
		return c - 'A' + 10
	}
}

trim :: proc "contextless" (s: string) -> string #no_bounds_check {
	a, b := 0, len(s)
	for a < b && is_space(s[a]) {
		a += 1
	}
	for b > a && is_space(s[b - 1]) {
		b -= 1
	}
	return s[a:b]
}

// encode_base64 writes `data` as base64 into `into`, seventy-six columns a
// line with CRLF, the way a mail part is written. Answers the length.
encode_base64 :: proc "contextless" (data: []u8, into: []u8) -> int #no_bounds_check {
	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	n := 0
	col := 0
	i := 0
	for i < len(data) {
		if n + 6 > len(into) {
			return n
		}
		b0 := u32(data[i])
		b1 := i + 1 < len(data) ? u32(data[i + 1]) : 0
		b2 := i + 2 < len(data) ? u32(data[i + 2]) : 0
		v := b0 << 16 | b1 << 8 | b2
		into[n] = alphabet[v >> 18 & 63]
		into[n + 1] = alphabet[v >> 12 & 63]
		into[n + 2] = i + 1 < len(data) ? alphabet[v >> 6 & 63] : '='
		into[n + 3] = i + 2 < len(data) ? alphabet[v & 63] : '='
		n += 4
		col += 4
		i += 3
		if col >= 76 && i < len(data) {
			into[n], into[n + 1] = '\r', '\n'
			n += 2
			col = 0
		}
	}
	return n
}
