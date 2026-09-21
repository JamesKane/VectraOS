/*
JSON, as far as a network's answer needs: a field of an object by name,
and the byte range of each element of an array, so a message keeps its
own bytes as `raw` while its fields are parsed apart. The parsing is
`core:encoding/json`'s; this is the reach into what it parsed.
*/
package libmsg

import "core:encoding/json"

// str_of answers the string field `key` of `o`, or "".
str_of :: proc(o: json.Object, key: string) -> string {
	if v, has := (map[string]json.Value)(o)[key]; has {
		if s, is := v.(json.String); is {
			return string(s)
		}
	}
	return ""
}

// int_of answers the number field `key` of `o` as an integer, and
// whether it was there as a number.
int_of :: proc(o: json.Object, key: string) -> (i64, bool) {
	if v, has := (map[string]json.Value)(o)[key]; has {
		#partial switch t in v {
		case json.Integer:
			return i64(t), true
		case json.Float:
			return i64(t), true
		}
	}
	return 0, false
}

// obj_of answers the object field `key` of `o`.
obj_of :: proc(o: json.Object, key: string) -> (json.Object, bool) {
	if v, has := (map[string]json.Value)(o)[key]; has {
		if sub, is := v.(json.Object); is {
			return sub, true
		}
	}
	return nil, false
}

// arr_of answers the array field `key` of `o`.
arr_of :: proc(o: json.Object, key: string) -> (json.Array, bool) {
	if v, has := (map[string]json.Value)(o)[key]; has {
		if a, is := v.(json.Array); is {
			return a, true
		}
	}
	return nil, false
}

/*
elements answers the byte range of each element of the JSON array that
begins at `text[at]`, or false when no array begins there. Strings are
walked with their escapes, and brackets counted outside them. The
ranges index `text`.
*/
elements :: proc(text: string, at := 0) -> (ranges: [dynamic][2]int, is_array: bool) {
	i := skip_json_space(text, at)
	if i >= len(text) || text[i] != '[' {
		return nil, false
	}
	ranges = make([dynamic][2]int, 0, 32)
	i += 1
	for {
		i = skip_json_space(text, i)
		if i >= len(text) || text[i] == ']' {
			break
		}
		if text[i] == ',' {
			i += 1
			continue
		}
		start := i
		depth := 0
		in_string := false
		for i < len(text) {
			c := text[i]
			if in_string {
				if c == '\\' {
					i += 1
				} else if c == '"' {
					in_string = false
				}
			} else {
				// A comma or the array's end at depth zero ends the element.
				if depth == 0 && (c == ',' || c == ']') {
					break
				}
				switch c {
				case '"':
					in_string = true
				case '[', '{':
					depth += 1
				case ']', '}':
					depth -= 1
				}
			}
			i += 1
		}
		end := i
		for end > start && is_json_space(text[end - 1]) {
			end -= 1
		}
		append(&ranges, [2]int{start, end})
	}
	return ranges, true
}

// array_at answers where the array under the top-level key `key` begins
// in `text`, its `[`, or -1. The key is found by its quoted name at
// depth one, so a same-named key deeper in does not mislead.
array_at :: proc(text: string, key: string) -> int {
	depth := 0
	in_string := false
	i := 0
	for i < len(text) {
		c := text[i]
		if in_string {
			if c == '\\' {
				i += 1
			} else if c == '"' {
				in_string = false
			}
			i += 1
			continue
		}
		switch c {
		case '"':
			if depth == 1 && i + len(key) + 1 < len(text) && text[i + 1:i + 1 + len(key)] == key && text[i + 1 + len(key)] == '"' {
				j := skip_json_space(text, i + len(key) + 2)
				if j < len(text) && text[j] == ':' {
					j = skip_json_space(text, j + 1)
					if j < len(text) && text[j] == '[' {
						return j
					}
				}
			}
			in_string = true
		case '[', '{':
			depth += 1
		case ']', '}':
			depth -= 1
		}
		i += 1
	}
	return -1
}

skip_json_space :: proc "contextless" (s: string, at: int) -> int {
	i := at
	for i < len(s) && is_json_space(s[i]) {
		i += 1
	}
	return i
}

is_json_space :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// object_end answers where the object or array beginning at `at` ends,
// one past its closing bracket, strings walked with their escapes.
object_end :: proc "contextless" (text: string, at: int) -> int {
	depth := 0
	in_string := false
	for i := at; i < len(text); i += 1 {
		c := text[i]
		if in_string {
			if c == '\\' {
				i += 1
			} else if c == '"' {
				in_string = false
			}
			continue
		}
		switch c {
		case '"':
			in_string = true
		case '{', '[':
			depth += 1
		case '}', ']':
			depth -= 1
			if depth == 0 {
				return i + 1
			}
		}
	}
	return len(text)
}

// -- JSON out ------------------------------------------------------------------------

put :: proc(out: ^[dynamic]u8, s: string) {
	append(out, ..transmute([]u8)s)
}

// put_html_text appends `s` as HTML text, its `<`, `>` and `&` made safe.
// The unescaped runs go in one append, not a byte at a time.
put_html_text :: proc(out: ^[dynamic]u8, s: string) {
	put_html(out, s, false)
}

// put_html_attr appends `s` inside a double-quoted attribute: `"`, `<`
// and `&` made safe.
put_html_attr :: proc(out: ^[dynamic]u8, s: string) {
	put_html(out, s, true)
}

@(private = "file")
put_html :: proc(out: ^[dynamic]u8, s: string, attr: bool) {
	run := 0
	i := 0
	for i < len(s) {
		c := s[i]
		esc := ""
		switch c {
		case '&':
			esc = "&amp;"
		case '<':
			esc = "&lt;"
		case '>':
			if !attr {
				esc = "&gt;"
			}
		case '"':
			if attr {
				esc = "&quot;"
			}
		}
		if esc != "" {
			if i > run {
				append(out, ..transmute([]u8)s[run:i])
			}
			append(out, ..transmute([]u8)esc)
			run = i + 1
		}
		i += 1
	}
	if len(s) > run {
		append(out, ..transmute([]u8)s[run:])
	}
}

// put_json_string appends `s` as a JSON string, quoted and escaped.
put_json_string :: proc(out: ^[dynamic]u8, s: string) {
	hex := "0123456789abcdef"
	append(out, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':
			append(out, '\\', '"')
		case '\\':
			append(out, '\\', '\\')
		case '\n':
			append(out, '\\', 'n')
		case '\r':
			append(out, '\\', 'r')
		case '\t':
			append(out, '\\', 't')
		case:
			if c < 0x20 {
				append(out, '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15])
			} else {
				append(out, c)
			}
		}
	}
	append(out, '"')
}
