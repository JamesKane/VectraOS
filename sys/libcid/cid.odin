/*
libcid -- a record checks against its hash: `docs/WEB.md` section 7.

A record on the AT network is named by its CID, the hash of its
DAG-CBOR bytes, and a server answers the record as JSON with the CID
beside it. This turns the JSON back into DAG-CBOR and hashes it, so
`hash` on a record is the network's own name for it, and a quote's
strong reference checks against what arrived.

DAG-CBOR is CBOR, RFC 8949, with the choices IPLD made: every integer
in its shortest form, a float always eight bytes, a map's keys sorted
by length and then by their bytes, no indefinite lengths, and a link a
tag 42 over the CID's bytes behind a zero. In JSON a link is
`{"$link": "b..."}` and bytes are `{"$bytes": "..."}`, base64; both are
turned back.

A CID here is version 1, the dag-cbor codec, sha2-256, base32 lower
case behind its `b`. `core:encoding/json` parses, with integers kept
as integers so a size is not a float.
*/
package libcid

import "core:crypto/hash"
import "core:encoding/json"

CID_LEN :: 59 // `b` and fifty-eight characters of thirty-six bytes

// checks answers whether a record's JSON hashes to `cid`.
checks :: proc(text: string, cid: string) -> bool {
	into: [CID_LEN + 1]u8
	got, ok := record_cid(text, into[:])
	return ok && got == cid
}

// record_cid parses a record's JSON and answers its CID, into `into`.
// The integers are kept as integers, or a size would hash as a float.
record_cid :: proc(text: string, into: []u8) -> (cid: string, ok: bool) {
	v, err := json.parse_string(text, .JSON, true)
	defer json.destroy_value(v)
	if err != .None {
		return "", false
	}
	return value_cid(v, into)
}

// value_cid answers the CID of a record already parsed, one whose
// integers were kept as integers.
value_cid :: proc(v: json.Value, into: []u8) -> (cid: string, ok: bool) {
	out := make([dynamic]u8, 0, 1024)
	defer delete(out)
	if !dag_cbor(v, &out) {
		return "", false
	}
	return cid_of(out[:], into), true
}

// cid_of answers the CID of DAG-CBOR bytes: version 1, codec 0x71,
// multihash sha2-256, as base32 behind `b`. `into` needs CID_LEN bytes.
cid_of :: proc(data: []u8, into: []u8) -> string {
	raw: [36]u8
	raw[0] = 0x01 // CIDv1
	raw[1] = 0x71 // dag-cbor
	raw[2] = 0x12 // sha2-256
	raw[3] = 0x20 // thirty-two bytes
	hash.hash_bytes_to_buffer(.SHA256, data, raw[4:])
	if len(into) < CID_LEN {
		return ""
	}
	into[0] = 'b'
	n := base32_encode(raw[:], into[1:])
	return string(into[:1 + n])
}

// -- DAG-CBOR ----------------------------------------------------------------------

// dag_cbor writes the DAG-CBOR of a JSON value into `out`. False for a
// value the codec has no form for here.
dag_cbor :: proc(v: json.Value, out: ^[dynamic]u8) -> bool {
	switch x in v {
	case json.Null:
		append(out, 0xf6)
	case json.Boolean:
		append(out, x ? 0xf5 : 0xf4)
	case json.Integer:
		if x >= 0 {
			put_head(out, 0, u64(x))
		} else {
			put_head(out, 1, u64(-1 - x))
		}
	case json.Float:
		bits := transmute(u64)x
		append(out, 0xfb)
		for i := 7; i >= 0; i -= 1 {
			append(out, u8(bits >> (u64(i) * 8)))
		}
	case json.String:
		put_head(out, 3, u64(len(x)))
		append(out, ..transmute([]u8)string(x))
	case json.Array:
		put_head(out, 4, u64(len(x)))
		for item in x {
			if !dag_cbor(item, out) {
				return false
			}
		}
	case json.Object:
		m := (map[string]json.Value)(x)
		if len(m) == 1 {
			if link, is_link := m["$link"]; is_link {
				return put_link(link, out)
			}
			if bytes, is_bytes := m["$bytes"]; is_bytes {
				return put_bytes(bytes, out)
			}
		}
		// The keys in the codec's order: by length, then by their bytes.
		keys := make([dynamic]string, 0, len(m))
		defer delete(keys)
		for k in m {
			at := len(keys)
			for i in 0 ..< len(keys) {
				if key_before(k, keys[i]) {
					at = i
					break
				}
			}
			append(&keys, "")
			for i := len(keys) - 1; i > at; i -= 1 {
				keys[i] = keys[i - 1]
			}
			keys[at] = k
		}
		put_head(out, 5, u64(len(keys)))
		for k in keys {
			put_head(out, 3, u64(len(k)))
			append(out, ..transmute([]u8)k)
			if !dag_cbor(m[k], out) {
				return false
			}
		}
	case:
		return false
	}
	return true
}

// put_link writes a `{"$link": cid}` as tag 42 over the CID's bytes
// behind a zero, the multibase prefix for binary.
put_link :: proc(link: json.Value, out: ^[dynamic]u8) -> bool {
	s, is_str := link.(json.String)
	if !is_str || len(s) < 2 || s[0] != 'b' {
		return false
	}
	raw: [128]u8
	n := base32_decode(string(s[1:]), raw[:])
	if n <= 0 {
		return false
	}
	put_head(out, 6, 42)
	put_head(out, 2, u64(n + 1))
	append(out, 0)
	append(out, ..raw[:n])
	return true
}

// put_bytes writes a `{"$bytes": base64}` as a byte string.
put_bytes :: proc(bytes: json.Value, out: ^[dynamic]u8) -> bool {
	s, is_str := bytes.(json.String)
	if !is_str {
		return false
	}
	raw := make([]u8, len(s))
	defer delete(raw)
	n := base64_decode(string(s), raw)
	if n < 0 {
		return false
	}
	put_head(out, 2, u64(n))
	append(out, ..raw[:n])
	return true
}

// base64_decode reads standard base64, padding or not, into `into`, and
// answers how many bytes, or -1 for a character outside the alphabet.
base64_decode :: proc(text: string, into: []u8) -> int {
	n := 0
	bits: u32 = 0
	have: u32 = 0
	for c in transmute([]u8)text {
		v: u32
		switch {
		case c >= 'A' && c <= 'Z':
			v = u32(c - 'A')
		case c >= 'a' && c <= 'z':
			v = u32(c - 'a') + 26
		case c >= '0' && c <= '9':
			v = u32(c - '0') + 52
		case c == '+' || c == '-':
			v = 62
		case c == '/' || c == '_':
			v = 63
		case c == '=' || c == '\n' || c == '\r':
			continue
		case:
			return -1
		}
		bits = bits << 6 | v
		have += 6
		if have >= 8 {
			have -= 8
			if n >= len(into) {
				return -1
			}
			into[n] = u8(bits >> have)
			n += 1
		}
	}
	return n
}

// put_head writes a major type and its argument in the shortest form.
put_head :: proc(out: ^[dynamic]u8, major: u8, n: u64) {
	m := major << 5
	switch {
	case n < 24:
		append(out, m | u8(n))
	case n < 0x100:
		append(out, m | 24, u8(n))
	case n < 0x10000:
		append(out, m | 25, u8(n >> 8), u8(n))
	case n < 0x1_0000_0000:
		append(out, m | 26, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	case:
		append(out, m | 27)
		for i := 7; i >= 0; i -= 1 {
			append(out, u8(n >> (u64(i) * 8)))
		}
	}
}

key_before :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return len(a) < len(b)
	}
	return a < b
}

// -- Base32, RFC 4648 lower case, no padding ---------------------------------------

ALPHABET := "abcdefghijklmnopqrstuvwxyz234567"

// base32_encode writes `data` as base32 into `into` and answers how many
// characters, or zero when `into` is too small.
base32_encode :: proc(data: []u8, into: []u8) -> int {
	need := (len(data) * 8 + 4) / 5
	if len(into) < need {
		return 0
	}
	n := 0
	bits: u32 = 0
	have: u32 = 0
	for b in data {
		bits = bits << 8 | u32(b)
		have += 8
		for have >= 5 {
			have -= 5
			into[n] = ALPHABET[(bits >> have) & 31]
			n += 1
		}
	}
	if have > 0 {
		into[n] = ALPHABET[(bits << (5 - have)) & 31]
		n += 1
	}
	return n
}

// base32_decode reads base32 into `into` and answers how many bytes, or
// zero for a character outside the alphabet or too small a buffer.
base32_decode :: proc(text: string, into: []u8) -> int {
	n := 0
	bits: u32 = 0
	have: u32 = 0
	for c in transmute([]u8)text {
		v: u32
		switch {
		case c >= 'a' && c <= 'z':
			v = u32(c - 'a')
		case c >= 'A' && c <= 'Z':
			v = u32(c - 'A')
		case c >= '2' && c <= '7':
			v = u32(c - '2') + 26
		case c == '=':
			continue
		case:
			return 0
		}
		bits = bits << 5 | v
		have += 5
		if have >= 8 {
			have -= 8
			if n >= len(into) {
				return 0
			}
			into[n] = u8(bits >> have)
			n += 1
		}
	}
	return n
}
