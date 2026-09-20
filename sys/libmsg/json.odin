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
