/*
libmark -- the markdown a reader needs, into a `libdoc.Doc`.

A few hundred lines for the subset people write. `#` headings, and paragraphs
that run until a blank line. `-`, `*`, `+` and `1.` list items, and `>`
quotes. Fenced code, a rule of dashes, inline links `[name](url)` and images
`![alt](src)`. Emphasis markers are dropped, since the reader draws one face.
An inline link becomes a link block after the paragraph it sat in, with its
name kept in the text. That is gemtext's way, and it lets a row be pressed.
Nothing here is the whole of CommonMark, and nothing needs to be.
*/
package libmark

import "vsys:libdoc"

// The links a paragraph held, to be added after it.
MAX_INLINE :: 32

Inline :: struct {
	name_off: int,
	name_len: int,
	href_off: int,
	href_len: int,
	end:      int, // Just past the closing parenthesis
	image:    bool,
}

parse :: proc(d: ^libdoc.Doc, src: string) {
	para: [dynamic]u8
	para = make([dynamic]u8, 0, 1024, context.allocator)
	defer delete(para)
	at := 0
	pre := false
	pre_start := 0
	for at < len(src) {
		end := at
		for end < len(src) && src[end] != '\n' {
			end += 1
		}
		line := src[at:end]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		if len(line) >= 3 && line[:3] == "```" {
			flush_para(d, &para)
			if pre {
				libdoc.doc_add(d, .Pre, src[pre_start:max(at - 1, pre_start)])
			} else {
				pre_start = end + 1
			}
			pre = !pre
		} else if !pre {
			trimmed := skip_space(line)
			switch {
			case len(trimmed) == 0:
				flush_para(d, &para)
			case trimmed[0] == '#':
				flush_para(d, &para)
				level := 0
				for level < len(trimmed) && level < 3 && trimmed[level] == '#' {
					level += 1
				}
				libdoc.doc_add(d, .Heading, strip_inline(d, skip_space(trimmed[level:]), true), "", level)
			case is_rule(trimmed):
				flush_para(d, &para)
				libdoc.doc_add(d, .Rule, "")
			case len(trimmed) >= 2 && (trimmed[:2] == "- " || trimmed[:2] == "* " || trimmed[:2] == "+ "):
				flush_para(d, &para)
				libdoc.doc_add(d, .Item, strip_inline(d, trimmed[2:], true))
			case ordered_item(trimmed) > 0:
				flush_para(d, &para)
				libdoc.doc_add(d, .Item, strip_inline(d, trimmed[ordered_item(trimmed):], true))
			case trimmed[0] == '>':
				flush_para(d, &para)
				libdoc.doc_add(d, .Quote, strip_inline(d, skip_space(trimmed[1:]), true))
			case:
				if len(para) > 0 {
					append(&para, ' ')
				}
				append(&para, ..transmute([]u8)trimmed)
			}
		}
		at = end + 1
	}
	flush_para(d, &para)
	if pre && pre_start < len(src) {
		libdoc.doc_add(d, .Pre, src[pre_start:])
	}
}

// flush_para adds the paragraph gathered so far as a text block, its inline
// links after it, and empties the gathering.
flush_para :: proc(d: ^libdoc.Doc, para: ^[dynamic]u8) {
	if len(para) == 0 {
		return
	}
	text := string(para[:])
	// A line that was only an image leaves no paragraph behind it.
	if stripped := strip_inline(d, text, false); len(stripped) > 0 {
		libdoc.doc_add(d, .Text, stripped)
	}
	add_inline(d, text)
	clear(para)
}

is_rule :: proc "contextless" (s: string) -> bool {
	if len(s) < 3 {
		return false
	}
	c := s[0]
	if c != '-' && c != '*' && c != '_' {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] != c && s[i] != ' ' {
			return false
		}
	}
	return true
}

// ordered_item answers where the text of `1. ` begins, or 0.
ordered_item :: proc "contextless" (s: string) -> int {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
	}
	if i == 0 || i + 1 >= len(s) || s[i] != '.' || s[i + 1] != ' ' {
		return 0
	}
	return i + 2
}

skip_space :: proc "contextless" (s: string) -> string {
	t := s
	for len(t) > 0 && (t[0] == ' ' || t[0] == '\t') {
		t = t[1:]
	}
	return t
}

/*
strip_inline answers `text` with the emphasis markers dropped and each
`[name](url)` reduced to its name, in the document's buffer. When `links`
is set the links found are added as blocks too. A heading or an item wants
that, since nothing follows them the way a paragraph is followed.
*/
strip_inline :: proc(d: ^libdoc.Doc, text: string, links: bool) -> string {
	out := make([dynamic]u8, 0, len(text), context.allocator)
	defer delete(out)
	i := 0
	for i < len(text) {
		c := text[i]
		switch {
		case c == '*' || c == '_' || c == '`':
			i += 1
		case c == '[' || (c == '!' && i + 1 < len(text) && text[i + 1] == '['):
			if link, ok := link_at(text, i); ok {
				if !link.image {
					append(&out, ..transmute([]u8)text[link.name_off:][:link.name_len])
				}
				i = link.end
			} else {
				append(&out, c)
				i += 1
			}
		case:
			append(&out, c)
			i += 1
		}
	}
	// Into the document's own buffer, where a block's text lives.
	off := len(d.buf)
	append(&d.buf, ..out[:])
	s := string(d.buf[off:][:len(out)])
	if links {
		add_inline(d, text)
	}
	return s
}

// add_inline adds a link or image block for each `[name](url)` in `text`.
add_inline :: proc(d: ^libdoc.Doc, text: string) {
	i := 0
	for i < len(text) {
		if text[i] == '[' || (text[i] == '!' && i + 1 < len(text) && text[i + 1] == '[') {
			if link, ok := link_at(text, i); ok {
				name := text[link.name_off:][:link.name_len]
				href := text[link.href_off:][:link.href_len]
				libdoc.doc_add(d, link.image ? .Image : .Link, len(name) > 0 ? name : href, href)
				i = link.end
				continue
			}
		}
		i += 1
	}
}

// link_at reads `[name](url)`, or `![alt](src)`, at `i`.
link_at :: proc "contextless" (text: string, i: int) -> (link: Inline, ok: bool) {
	at := i
	if text[at] == '!' {
		link.image = true
		at += 1
	}
	if at >= len(text) || text[at] != '[' {
		return link, false
	}
	close := -1
	for j := at + 1; j < len(text); j += 1 {
		if text[j] == ']' {
			close = j
			break
		}
		if text[j] == '[' {
			return link, false
		}
	}
	if close < 0 || close + 1 >= len(text) || text[close + 1] != '(' {
		return link, false
	}
	paren := -1
	for j := close + 2; j < len(text); j += 1 {
		if text[j] == ')' {
			paren = j
			break
		}
	}
	if paren < 0 {
		return link, false
	}
	link.name_off = at + 1
	link.name_len = close - at - 1
	link.href_off = close + 2
	link.href_len = paren - close - 2
	link.end = paren + 1
	// A title after the URL, `(url "title")`, is not the URL.
	for k in 0 ..< link.href_len {
		if text[link.href_off + k] == ' ' {
			link.href_len = k
			break
		}
	}
	return link, true
}
