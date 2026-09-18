/*
libfeed -- an Atom or RSS feed's entries as messages.

`docs/WEB.md` section 4 makes the feed the first network, since it needs
no login and proves the shape before any network with a password does.
`parse` reads Atom (RFC 4287) and RSS 2.0, and RSS 1.0's items where they
stand, into `libmsg.Msg` records. An entry's title is the subject, its
author the sender or else the feed's title, its content or summary the
body with the media type the feed declares, its links and enclosures the
links, and the entry's own markup the raw text. `thr:in-reply-to` becomes
`replyto`, resolved to the other entry's id when it is in the same feed.

A date is RFC 3339 in Atom and RFC 822 in RSS, and `libmsg.parse_date`
reads both. An entry with no date is dated zero, and sorts first.
*/
package libfeed

import "vsys:libmsg"

Feed :: struct {
	title:   string,
	link:    string,
	entries: [dynamic]libmsg.Msg,
}

// What one entry gathered, as slices of the source, until its end tag
// makes a message of it.
@(private = "file")
Entry :: struct {
	start:      int,
	title:      string,
	id:         string,
	date:       string, // published, else updated, else pubDate
	updated:    string,
	summary:    string,
	content:    string,
	ctype:      string, // Atom's `type` attribute on content or summary
	author:     string,
	replyto:    string,
	links:      [8]string,
	nlinks:     int,
	in_author:  bool,
}

feed_free :: proc(f: ^Feed, allocator := context.allocator) {
	context.allocator = allocator
	delete(f.title)
	delete(f.link)
	for &m in f.entries {
		libmsg.msg_free(&m)
	}
	delete(f.entries)
	f^ = Feed{}
}

/*
parse reads `text` into a feed. False when it is not a feed: neither an
Atom `feed` nor an RSS `rss` or `RDF` root. The messages' strings are
their own, on `allocator`, so the text may go.
*/
parse :: proc(text: string, allocator := context.allocator) -> (f: Feed, ok: bool) {
	context.allocator = allocator
	s := Scanner{src = text}
	depth := 0
	e: Entry
	in_entry := false
	entry_depth := 0
	field_start := 0
	field_attrs: string
	f.entries = make([dynamic]libmsg.Msg, 0, 16)
	rooted := false
	for {
		t := next(&s)
		if t.kind == .Eof {
			break
		}
		switch t.kind {
		case .Start:
			name := local(t.name)
			if depth == 0 {
				switch name {
				case "feed", "rss", "RDF":
					rooted = true
				case:
					return f, false
				}
			}
			depth += 1
			if !in_entry && (name == "entry" || name == "item") && depth <= 3 {
				in_entry = true
				entry_depth = depth
				e = Entry{start = t.start}
				if t.closed {
					finish(&f, &e, text[t.start:t.end])
					in_entry = false
				}
				continue
			}
			if in_entry && depth == entry_depth + 1 {
				field_start = t.end
				field_attrs = t.attrs
				switch name {
				case "link":
					// Atom's is an attribute; RSS's is text, taken at the end.
					if href, has := attr(t.attrs, "href"); has {
						rel, _ := attr(t.attrs, "rel")
						if rel == "" || rel == "alternate" || rel == "enclosure" {
							add_link(&e, href)
						}
					}
				case "enclosure":
					if url, has := attr(t.attrs, "url"); has {
						add_link(&e, url)
					}
				case "in-reply-to":
					if ref, has := attr(t.attrs, "ref"); has {
						e.replyto = ref
					}
				case "author":
					e.in_author = true
				}
				if t.closed {
					depth -= 1
					e.in_author = false
				}
				continue
			}
			if in_entry && depth == entry_depth + 2 && e.in_author && name == "name" {
				field_start = t.end
			}
			if !in_entry && (depth == 2 || depth == 3) && (name == "title" || name == "link") {
				field_start = t.end
				field_attrs = t.attrs
				if name == "link" && t.closed && f.link == "" {
					if href, has := attr(t.attrs, "href"); has {
						f.link = clone_decoded(href)
					}
				}
			}
			if t.closed {
				depth -= 1
			}
		case .End:
			name := local(t.name)
			if in_entry && depth == entry_depth + 1 {
				inner := text[field_start:t.start]
				switch name {
				case "title":
					e.title = inner
				case "id", "guid":
					e.id = inner
				case "published", "pubDate", "date":
					e.date = inner
				case "updated":
					e.updated = inner
				case "summary", "description":
					e.summary = inner
					if e.content == "" {
						e.ctype, _ = attr(field_attrs, "type")
					}
				case "content", "encoded":
					e.content = inner
					e.ctype, _ = attr(field_attrs, "type")
				case "link":
					add_link(&e, trim(inner))
				case "creator":
					e.author = inner
				case "author":
					if e.author == "" {
						e.author = inner
					}
					e.in_author = false
				}
			} else if in_entry && depth == entry_depth + 2 && e.in_author && name == "name" {
				e.author = text[field_start:t.start]
			} else if !in_entry && depth <= 3 && depth >= 2 {
				inner := text[field_start:t.start]
				if name == "title" && f.title == "" {
					f.title = clone_decoded(trim(inner))
				}
				if name == "link" && f.link == "" {
					if href, has := attr(field_attrs, "href"); has {
						f.link = clone_decoded(href)
					} else if len(trim(inner)) > 0 {
						f.link = clone_decoded(trim(inner))
					}
				}
			}
			if in_entry && depth == entry_depth && (name == "entry" || name == "item") {
				finish(&f, &e, text[e.start:t.end])
				in_entry = false
			}
			if depth > 0 {
				depth -= 1
			}
		case .Text, .Cdata, .Eof:
		}
	}
	if !rooted {
		return f, false
	}
	resolve_replies(&f)
	return f, true
}

@(private = "file")
add_link :: proc "contextless" (e: ^Entry, href: string) {
	if len(href) == 0 || e.nlinks >= len(e.links) {
		return
	}
	e.links[e.nlinks] = href
	e.nlinks += 1
}

// finish makes a message of an entry and keeps it.
@(private = "file")
finish :: proc(f: ^Feed, e: ^Entry, raw: string) {
	m: libmsg.Msg
	date_text := trim(e.date)
	if date_text == "" {
		date_text = trim(e.updated)
	}
	m.date, _ = libmsg.parse_date(date_text)
	m.date_text = clone_decoded(date_text)
	netid := trim(e.id)
	if netid == "" && e.nlinks > 0 {
		netid = e.links[0]
	}
	if netid == "" {
		netid = trim(e.title)
	}
	idbuf: [128]u8
	tmp: [256]u8
	m.id = clone(libmsg.make_id(m.date, decode(netid, tmp[:]), idbuf[:]))
	m.subject = clone_decoded(trim(e.title))
	if len(trim(e.author)) > 0 {
		m.from = clone_decoded(trim(e.author))
	} else {
		m.from = clone(f.title)
	}
	body := e.content
	if body == "" {
		body = e.summary
	}
	m.type = clone(body_type(e.ctype, body))
	if e.ctype == "xhtml" {
		// The markup is the body, as it stands in the feed.
		m.body = clone(trim(body))
	} else {
		m.body = clone_decoded(trim(body))
	}
	if e.replyto != "" {
		m.replyto = clone(decode(trim(e.replyto), tmp[:]))
	}
	// Links, one a line.
	total := 0
	for i in 0 ..< e.nlinks {
		total += len(e.links[i]) * 2 + 1
	}
	if total > 0 {
		lines := make([]u8, total)
		n := 0
		for i in 0 ..< e.nlinks {
			n += len(decode(e.links[i], lines[n:]))
			lines[n] = '\n'
			n += 1
		}
		m.links = string(lines[:n])
	}
	m.raw = clone(raw)
	append(&f.entries, m)
}

// body_type says what an Atom `type` or a bare RSS description is. RSS's
// description is HTML by convention, and an Atom body with no type is text.
@(private = "file")
body_type :: proc "contextless" (ctype: string, body: string) -> string {
	switch ctype {
	case "html", "xhtml":
		return "text/html"
	case "text":
		return "text/plain"
	case "":
		return looks_html(body) ? "text/html" : "text/plain"
	}
	return ctype
}

// looks_html is the RSS guess: an escaped or literal tag in the text.
@(private = "file")
looks_html :: proc "contextless" (s: string) -> bool #no_bounds_check {
	for i in 0 ..< len(s) {
		if s[i] == '<' && i + 1 < len(s) && (is_alpha(s[i + 1]) || s[i + 1] == '/' || s[i + 1] == '!') {
			return true
		}
		if s[i] == '&' && has_at(s, i, "&lt;") {
			return true
		}
	}
	return false
}

// resolve_replies turns a `replyto` that names another entry's network id
// into that entry's full id. One that names no entry here is dated zero.
@(private = "file")
resolve_replies :: proc(f: ^Feed) {
	for &m in f.entries {
		if m.replyto == "" {
			continue
		}
		found := ""
		for other in f.entries {
			if len(other.id) > 17 && other.id[17:] == tail_of(m.replyto) {
				found = other.id
				break
			}
		}
		idbuf: [128]u8
		if found == "" {
			found = libmsg.make_id(0, m.replyto, idbuf[:])
		}
		delete(m.replyto)
		m.replyto = clone(found)
	}
}

// tail_of answers what an id's network part would be for `netid`: itself
// when it is a name, else its hash, the way `make_id` spells it.
@(private = "file")
tail_of :: proc(netid: string) -> string {
	@(static) buf: [128]u8
	id := libmsg.make_id(0, netid, buf[:])
	return id[17:]
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

@(private = "file")
clone_decoded :: proc(s: string) -> string {
	if len(s) == 0 {
		return ""
	}
	own := make([]u8, len(s))
	d := decode(s, own)
	return d
}

is_alpha :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
