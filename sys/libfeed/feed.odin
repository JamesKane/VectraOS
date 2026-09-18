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

A date is RFC 3339 in Atom and RFC 822 in RSS, and `parse_date` reads
both. An entry with no date is dated zero, and sorts first.
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
	m.date, _ = parse_date(date_text)
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

// -- Dates -----------------------------------------------------------------------

/*
parse_date reads RFC 3339 (`2026-09-18T10:20:30Z`, `+02:00`, a fraction)
and RFC 822 (`Thu, 18 Sep 2026 10:20:30 GMT`, `+0200`, the North
American zone names) to seconds since the epoch. False for anything else.
*/
parse_date :: proc "contextless" (text: string) -> (secs: i64, ok: bool) #no_bounds_check {
	s := trim(text)
	if len(s) >= 10 && s[4] == '-' && s[7] == '-' {
		return parse_3339(s)
	}
	return parse_822(s)
}

@(private = "file")
parse_3339 :: proc "contextless" (s: string) -> (secs: i64, ok: bool) #no_bounds_check {
	y, i1 := digits(s, 0, 4)
	mo, i2 := digits(s, i1 + 1, 2)
	d, i3 := digits(s, i2 + 1, 2)
	if i1 < 0 || i2 < 0 || i3 < 0 {
		return 0, false
	}
	h, mi, sec := 0, 0, 0
	i := i3
	if i < len(s) && (s[i] == 'T' || s[i] == 't' || s[i] == ' ') {
		i4 := 0
		h, i4 = digits(s, i + 1, 2)
		if i4 < 0 {
			return 0, false
		}
		mi, i4 = digits(s, i4 + 1, 2)
		if i4 < 0 {
			return 0, false
		}
		i = i4
		if i < len(s) && s[i] == ':' {
			sec, i = digits(s, i + 1, 2)
			if i < 0 {
				return 0, false
			}
		}
		if i < len(s) && s[i] == '.' {
			i += 1
			for i < len(s) && s[i] >= '0' && s[i] <= '9' {
				i += 1
			}
		}
	}
	offset := 0
	if i < len(s) {
		switch s[i] {
		case 'Z', 'z':
		case '+', '-':
			oh, j := digits(s, i + 1, 2)
			om := 0
			if j > 0 && j < len(s) && s[j] == ':' {
				om, j = digits(s, j + 1, 2)
			} else if j > 0 {
				om, j = digits(s, j, 2)
			}
			if j < 0 {
				return 0, false
			}
			offset = oh * 3600 + om * 60
			if s[i] == '-' {
				offset = -offset
			}
		}
	}
	return civil(y, mo, d, h, mi, sec) - i64(offset), true
}

@(private = "file")
parse_822 :: proc "contextless" (s: string) -> (secs: i64, ok: bool) #no_bounds_check {
	i := 0
	// An optional day name and its comma.
	for i < len(s) && s[i] != ',' && !(s[i] >= '0' && s[i] <= '9') {
		i += 1
	}
	if i < len(s) && s[i] == ',' {
		i += 1
	}
	i = skip_space(s, i)
	d, j := number(s, i)
	if j < 0 {
		return 0, false
	}
	i = skip_space(s, j)
	mo := 0
	if i + 3 <= len(s) {
		mo = month_of(s[i:i + 3])
	}
	if mo == 0 {
		return 0, false
	}
	i = skip_space(s, i + 3)
	y := 0
	y, j = number(s, i)
	if j < 0 {
		return 0, false
	}
	if y < 100 {
		y += y < 50 ? 2000 : 1900
	}
	i = skip_space(s, j)
	h, mi, sec := 0, 0, 0
	h, j = number(s, i)
	if j < 0 || j >= len(s) || s[j] != ':' {
		return 0, false
	}
	mi, j = number(s, j + 1)
	if j < 0 {
		return 0, false
	}
	if j < len(s) && s[j] == ':' {
		sec, j = number(s, j + 1)
		if j < 0 {
			return 0, false
		}
	}
	i = skip_space(s, j)
	offset := 0
	if i < len(s) {
		switch s[i] {
		case '+', '-':
			v, k := number(s, i + 1)
			if k < 0 {
				return 0, false
			}
			offset = (v / 100) * 3600 + (v % 100) * 60
			if s[i] == '-' {
				offset = -offset
			}
		case:
			e := i
			for e < len(s) && is_alpha(s[e]) {
				e += 1
			}
			switch s[i:e] {
			case "GMT", "UT", "UTC", "Z":
			case "EST":
				offset = -5 * 3600
			case "EDT":
				offset = -4 * 3600
			case "CST":
				offset = -6 * 3600
			case "CDT":
				offset = -5 * 3600
			case "MST":
				offset = -7 * 3600
			case "MDT":
				offset = -6 * 3600
			case "PST":
				offset = -8 * 3600
			case "PDT":
				offset = -7 * 3600
			}
		}
	}
	return civil(y, mo, d, h, mi, sec) - i64(offset), true
}

// civil is the seconds since the epoch of a proleptic Gregorian date,
// Howard Hinnant's days-from-civil.
civil :: proc "contextless" (y, m, d, h, mi, s: int) -> i64 {
	y := y
	if m <= 2 {
		y -= 1
	}
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	mp := (m + 9) % 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	days := i64(era) * 146097 + i64(doe) - 719468
	return days * 86400 + i64(h) * 3600 + i64(mi) * 60 + i64(s)
}

@(private = "file")
month_of :: proc "contextless" (s: string) -> int {
	switch s {
	case "Jan":
		return 1
	case "Feb":
		return 2
	case "Mar":
		return 3
	case "Apr":
		return 4
	case "May":
		return 5
	case "Jun":
		return 6
	case "Jul":
		return 7
	case "Aug":
		return 8
	case "Sep":
		return 9
	case "Oct":
		return 10
	case "Nov":
		return 11
	case "Dec":
		return 12
	}
	return 0
}

// digits reads exactly `n` digits at `at`, answering the value and where
// they end, or -1 for an end when they are not there.
@(private = "file")
digits :: proc "contextless" (s: string, at: int, n: int) -> (v: int, end: int) #no_bounds_check {
	if at < 0 || at + n > len(s) {
		return 0, -1
	}
	for i in at ..< at + n {
		if s[i] < '0' || s[i] > '9' {
			return 0, -1
		}
		v = v * 10 + int(s[i] - '0')
	}
	return v, at + n
}

@(private = "file")
number :: proc "contextless" (s: string, at: int) -> (v: int, end: int) #no_bounds_check {
	i := at
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + int(s[i] - '0')
		i += 1
	}
	if i == at {
		return 0, -1
	}
	return v, i
}

@(private = "file")
skip_space :: proc "contextless" (s: string, at: int) -> int #no_bounds_check {
	i := at
	for i < len(s) && is_space(s[i]) {
		i += 1
	}
	return i
}

