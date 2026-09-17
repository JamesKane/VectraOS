/*
libgemtext -- text/gemini into a `libdoc.Doc`.

Gemtext is a line a type. `#` is a heading up to three deep. `=>` is a link
with its URL and an optional name. `*` is a list item, `>` a quote, and three
backticks open and close a preformatted block. Anything else is a paragraph.
The format is small enough that this is the whole of it. `libdoc`'s blocks
are its line types, so the reader shows a capsule as its author laid it out.
*/
package libgemtext

import "vsys:libdoc"

parse :: proc(d: ^libdoc.Doc, src: string) {
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
			if pre {
				libdoc.doc_add(d, .Pre, src[pre_start:max(at - 1, pre_start)])
			} else {
				pre_start = end + 1
			}
			pre = !pre
		} else if !pre {
			add_line(d, line)
		}
		at = end + 1
	}
	if pre && pre_start < len(src) {
		libdoc.doc_add(d, .Pre, src[pre_start:])
	}
}

// add_line adds one line outside a preformatted block by its type.
add_line :: proc(d: ^libdoc.Doc, line: string) {
	switch {
	case len(line) >= 2 && line[:2] == "=>":
		rest := skip_space(line[2:])
		url := rest
		name := ""
		for i in 0 ..< len(rest) {
			if rest[i] == ' ' || rest[i] == '\t' {
				url = rest[:i]
				name = skip_space(rest[i:])
				break
			}
		}
		libdoc.doc_add(d, .Link, len(name) > 0 ? name : url, url)
	case len(line) >= 1 && line[0] == '#':
		level := 0
		for level < len(line) && level < 3 && line[level] == '#' {
			level += 1
		}
		libdoc.doc_add(d, .Heading, skip_space(line[level:]), "", level)
	case len(line) >= 2 && line[:2] == "* ":
		libdoc.doc_add(d, .Item, line[2:])
	case len(line) >= 1 && line[0] == '>':
		libdoc.doc_add(d, .Quote, skip_space(line[1:]))
	case:
		libdoc.doc_add(d, .Text, line)
	}
}

skip_space :: proc "contextless" (s: string) -> string {
	t := s
	for len(t) > 0 && (t[0] == ' ' || t[0] == '\t') {
		t = t[1:]
	}
	return t
}
