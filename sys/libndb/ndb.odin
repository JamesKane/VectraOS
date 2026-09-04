/*
libndb -- the network database, as 9front keeps it.

`/lib/ndb/local` is a text file of attribute lists, and this reads one. A record
is a run of `attr=value` pairs ending at a blank line, and a line that begins
with whitespace continues the record above it:

    sys=fs ip=10.0.0.2 ether=525400123456
        fs=fs auth=fs
        cputype=amd64

    tcp=9fs port=564

A query is "find the record where this attribute has this value, and answer that
record's other attribute". `sys=fs` answering `ip` is a name resolved, and
`tcp=9fs` answering `port` is a service resolved. Both are the same walk, which
is the whole reason the file has one shape.

Nothing here opens a file. A caller reads the text and hands it over, so
`tests/net` proves the walk against records written in the test itself.
`servers/netfs` reads `/lib/ndb/local` once at start, and `dns` will be the
second caller when it exists.
*/
package libndb

// space reports the bytes that separate tokens, which are also what continues a
// record onto the next line.
space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\r'
}

/*
record_at answers the record beginning at `from`, and where the next one begins.
A record ends at a blank line, which is a newline with nothing but space before
the next one. `ok` is false when there is nothing left.
*/
record_at :: proc "contextless" (text: string, from: int) -> (rec: string, next: int, ok: bool) #no_bounds_check {
	i := from
	// Skip blank lines and the space in front of a record.
	for i < len(text) && (text[i] == '\n' || space(text[i])) {
		i += 1
	}
	if i >= len(text) {
		return "", i, false
	}
	start := i
	// The record runs until a newline that begins a line which is neither
	// blank nor indented.
	for i < len(text) {
		if text[i] != '\n' {
			i += 1
			continue
		}
		j := i + 1
		if j >= len(text) {
			break
		}
		// An indented line continues this record. A blank line ends it.
		if space(text[j]) {
			i = j
			continue
		}
		break
	}
	return text[start:i], i, true
}

/*
pair_at answers the `attr=value` beginning at `from` within one record, and
where the next begins. A token with no `=` is skipped rather than refused,
because a comment or a stray word should not lose the record around it.
*/
pair_at :: proc "contextless" (rec: string, from: int) -> (attr: string, value: string, next: int, ok: bool) #no_bounds_check {
	i := from
	for i < len(rec) && (space(rec[i]) || rec[i] == '\n') {
		i += 1
	}
	if i >= len(rec) {
		return "", "", i, false
	}
	start := i
	for i < len(rec) && !space(rec[i]) && rec[i] != '\n' {
		i += 1
	}
	token := rec[start:i]
	// A `#` begins a comment, which runs to the end of the line.
	if len(token) > 0 && token[0] == '#' {
		for i < len(rec) && rec[i] != '\n' {
			i += 1
		}
		return "", "", i, true
	}
	for k in 0 ..< len(token) {
		if token[k] == '=' {
			return token[:k], token[k + 1:], i, true
		}
	}
	return "", "", i, true
}

// attr_of answers one attribute's value within a record.
attr_of :: proc "contextless" (rec: string, attr: string) -> (string, bool) {
	at := 0
	for {
		a, v, next, ok := pair_at(rec, at)
		if !ok {
			return "", false
		}
		if a == attr {
			return v, true
		}
		at = next
	}
}

/*
find is the query the whole file exists for: the record where `attr` is `value`,
answering its `want`. A record that matches but has no `want` is passed over,
because a later record may have both.
*/
find :: proc "contextless" (text: string, attr: string, value: string, want: string) -> (string, bool) {
	at := 0
	for {
		rec, next, ok := record_at(text, at)
		if !ok {
			return "", false
		}
		if got, has := attr_of(rec, attr); has && got == value {
			if answer, found := attr_of(rec, want); found {
				return answer, true
			}
		}
		at = next
	}
}
