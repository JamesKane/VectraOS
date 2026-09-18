/*
The XML a feed is: tags, attributes, text, CDATA, and the five entities.
Odin's `core:encoding/xml` reaches for `core:os` and cannot build for ring
3, and a feed needs none of what it would give past this. The scanner
answers one token at a time with its offsets in the source, so a caller
that wants an element's inner text, markup and all, slices the source
between the tags.
*/
package libfeed

Tok_Kind :: enum u8 {
	Eof,
	Start, // `<name attrs>` or `<name attrs/>`, which sets `closed`
	End, // `</name>`
	Text, // What lies between tags, entities as written
	Cdata, // A `<![CDATA[...]]>` section's content, as written
}

Tok :: struct {
	kind:   Tok_Kind,
	name:   string, // The element's name, prefix and all
	attrs:  string, // The attribute text between the name and the `>`
	text:   string, // Text or CDATA content
	closed: bool, // A start tag that ends itself
	start:  int, // Where the token begins in the source
	end:    int, // Where the next one begins
}

Scanner :: struct {
	src: string,
	at:  int,
}

// next answers the next token. Comments, processing instructions and the
// doctype are skipped.
next :: proc "contextless" (s: ^Scanner) -> (t: Tok) #no_bounds_check {
	src := s.src
	for {
		if s.at >= len(src) {
			t.kind = .Eof
			t.start, t.end = len(src), len(src)
			return t
		}
		t.start = s.at
		if src[s.at] != '<' {
			i := s.at
			for i < len(src) && src[i] != '<' {
				i += 1
			}
			t.kind = .Text
			t.text = src[s.at:i]
			s.at = i
			t.end = i
			return t
		}
		if has_at(src, s.at, "<![CDATA[") {
			i := s.at + 9
			j := i
			for j + 3 <= len(src) && src[j:j + 3] != "]]>" {
				j += 1
			}
			t.kind = .Cdata
			t.text = src[i:min(j, len(src))]
			s.at = min(j + 3, len(src))
			t.end = s.at
			return t
		}
		if has_at(src, s.at, "<!--") {
			j := s.at + 4
			for j + 3 <= len(src) && src[j:j + 3] != "-->" {
				j += 1
			}
			s.at = min(j + 3, len(src))
			continue
		}
		if has_at(src, s.at, "<?") || has_at(src, s.at, "<!") {
			j := s.at + 2
			for j < len(src) && src[j] != '>' {
				j += 1
			}
			s.at = min(j + 1, len(src))
			continue
		}
		// A tag.
		i := s.at + 1
		is_end := i < len(src) && src[i] == '/'
		if is_end {
			i += 1
		}
		name_start := i
		for i < len(src) && !is_space(src[i]) && src[i] != '>' && src[i] != '/' {
			i += 1
		}
		t.name = src[name_start:i]
		attrs_start := i
		// To the `>` outside any quoted value.
		quote: u8
		for i < len(src) {
			c := src[i]
			if quote != 0 {
				if c == quote {
					quote = 0
				}
			} else if c == '"' || c == '\'' {
				quote = c
			} else if c == '>' {
				break
			}
			i += 1
		}
		attrs_end := i
		if attrs_end > attrs_start && src[attrs_end - 1] == '/' {
			t.closed = true
			attrs_end -= 1
		}
		t.attrs = src[attrs_start:attrs_end]
		t.kind = is_end ? Tok_Kind.End : Tok_Kind.Start
		s.at = min(i + 1, len(src))
		t.end = s.at
		return t
	}
}

// attr answers an attribute's value as written, quotes off.
attr :: proc "contextless" (attrs: string, name: string) -> (string, bool) #no_bounds_check {
	i := 0
	for i < len(attrs) {
		for i < len(attrs) && is_space(attrs[i]) {
			i += 1
		}
		ns := i
		for i < len(attrs) && attrs[i] != '=' && !is_space(attrs[i]) {
			i += 1
		}
		key := attrs[ns:i]
		for i < len(attrs) && is_space(attrs[i]) {
			i += 1
		}
		if i >= len(attrs) || attrs[i] != '=' {
			if len(key) == 0 {
				break
			}
			continue
		}
		i += 1
		for i < len(attrs) && is_space(attrs[i]) {
			i += 1
		}
		value: string
		if i < len(attrs) && (attrs[i] == '"' || attrs[i] == '\'') {
			q := attrs[i]
			i += 1
			vs := i
			for i < len(attrs) && attrs[i] != q {
				i += 1
			}
			value = attrs[vs:i]
			i += 1
		} else {
			vs := i
			for i < len(attrs) && !is_space(attrs[i]) {
				i += 1
			}
			value = attrs[vs:i]
		}
		if key == name {
			return value, true
		}
	}
	return "", false
}

// local answers an element's name with its prefix off: `thr:in-reply-to`
// is `in-reply-to`.
local :: proc "contextless" (name: string) -> string {
	for i in 0 ..< len(name) {
		if name[i] == ':' {
			return name[i + 1:]
		}
	}
	return name
}

/*
decode writes `raw` into `into` with its entities and CDATA sections
resolved: the five named entities, numbered ones, and a CDATA section's
content as it is. The result is a prefix of `into`.
*/
decode :: proc "contextless" (raw: string, into: []u8) -> string #no_bounds_check {
	n := 0
	i := 0
	for i < len(raw) && n < len(into) {
		c := raw[i]
		if c == '<' && has_at(raw, i, "<![CDATA[") {
			i += 9
			for i < len(raw) && n < len(into) && !has_at(raw, i, "]]>") {
				into[n] = raw[i]
				n += 1
				i += 1
			}
			i += 3
			continue
		}
		if c == '&' {
			j := i + 1
			for j < len(raw) && j - i < 12 && raw[j] != ';' {
				j += 1
			}
			if j < len(raw) && raw[j] == ';' {
				ent := raw[i + 1:j]
				code := -1
				switch ent {
				case "amp":
					code = '&'
				case "lt":
					code = '<'
				case "gt":
					code = '>'
				case "quot":
					code = '"'
				case "apos":
					code = '\''
				case:
					if len(ent) > 1 && ent[0] == '#' {
						code = number_of(ent[1:])
					}
				}
				if code >= 0 {
					n += put_rune(into[n:], code)
					i = j + 1
					continue
				}
			}
		}
		into[n] = c
		n += 1
		i += 1
	}
	return string(into[:n])
}

@(private = "file")
number_of :: proc "contextless" (s: string) -> int #no_bounds_check {
	if len(s) == 0 {
		return -1
	}
	v := 0
	if s[0] == 'x' || s[0] == 'X' {
		for i in 1 ..< len(s) {
			c := s[i]
			d := 0
			switch {
			case c >= '0' && c <= '9':
				d = int(c - '0')
			case c >= 'a' && c <= 'f':
				d = int(c - 'a') + 10
			case c >= 'A' && c <= 'F':
				d = int(c - 'A') + 10
			case:
				return -1
			}
			v = v * 16 + d
			if v > 0x10FFFF {
				return -1
			}
		}
		return len(s) > 1 ? v : -1
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if c < '0' || c > '9' {
			return -1
		}
		v = v * 10 + int(c - '0')
		if v > 0x10FFFF {
			return -1
		}
	}
	return v
}

@(private = "file")
put_rune :: proc "contextless" (into: []u8, code: int) -> int #no_bounds_check {
	switch {
	case code < 0x80:
		if len(into) < 1 {
			return 0
		}
		into[0] = u8(code)
		return 1
	case code < 0x800:
		if len(into) < 2 {
			return 0
		}
		into[0] = u8(0xC0 | code >> 6)
		into[1] = u8(0x80 | code & 0x3F)
		return 2
	case code < 0x10000:
		if len(into) < 3 {
			return 0
		}
		into[0] = u8(0xE0 | code >> 12)
		into[1] = u8(0x80 | (code >> 6) & 0x3F)
		into[2] = u8(0x80 | code & 0x3F)
		return 3
	case:
		if len(into) < 4 {
			return 0
		}
		into[0] = u8(0xF0 | code >> 18)
		into[1] = u8(0x80 | (code >> 12) & 0x3F)
		into[2] = u8(0x80 | (code >> 6) & 0x3F)
		into[3] = u8(0x80 | code & 0x3F)
		return 4
	}
}

has_at :: proc "contextless" (s: string, at: int, what: string) -> bool #no_bounds_check {
	return at + len(what) <= len(s) && s[at:at + len(what)] == what
}

is_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
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
