/*
libjws -- a signed token in JWS compact form on ES256, and the JWK a
P-256 key is carried as: what DPoP, RFC 9449, asks of a client. A proof
is a JWT whose header names the key and whose payload names the request:
its method, its URL, a fresh id, the time, the server's nonce when it
gave one, and the hash of the access token the request carries.
`docs/WEB.md` section 7.

The signature is the raw `r || s` of ECDSA over SHA-256, sixty-four
bytes, as JWS has it and not ASN.1. Base64url has no padding.
*/
package libjws

import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:encoding/json"

// -- Base64url, RFC 4648 section 5, no padding -----------------------------------

ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

// base64url_encode writes `data` into `into` and answers how many
// characters, or zero when `into` is too small.
base64url_encode :: proc(data: []u8, into: []u8) -> int {
	need := (len(data) * 8 + 5) / 6
	if len(into) < need {
		return 0
	}
	n := 0
	i := 0
	for i + 3 <= len(data) {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
		into[n] = ALPHABET[v >> 18 & 63]
		into[n + 1] = ALPHABET[v >> 12 & 63]
		into[n + 2] = ALPHABET[v >> 6 & 63]
		into[n + 3] = ALPHABET[v & 63]
		n += 4
		i += 3
	}
	switch len(data) - i {
	case 1:
		v := u32(data[i]) << 16
		into[n] = ALPHABET[v >> 18 & 63]
		into[n + 1] = ALPHABET[v >> 12 & 63]
		n += 2
	case 2:
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8
		into[n] = ALPHABET[v >> 18 & 63]
		into[n + 1] = ALPHABET[v >> 12 & 63]
		into[n + 2] = ALPHABET[v >> 6 & 63]
		n += 3
	}
	return n
}

// base64url_decode reads `text` into `into` and answers how many bytes,
// or -1 for a character outside the alphabet or too small a buffer.
base64url_decode :: proc(text: string, into: []u8) -> int {
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
		case c == '-':
			v = 62
		case c == '_':
			v = 63
		case c == '=':
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

// -- The key as JSON ---------------------------------------------------------------

// jwk_p256 writes a P-256 public key as a JWK into `into`: its curve and
// its two coordinates, base64url. Needs about a hundred and twenty bytes.
jwk_p256 :: proc(pub: ^ecdsa.Public_Key, into: []u8) -> string {
	point: [65]u8
	ecdsa.public_key_bytes(pub, point[:])
	x: [48]u8
	y: [48]u8
	xn := base64url_encode(point[1:33], x[:])
	yn := base64url_encode(point[33:65], y[:])
	return cat(into, `{"kty":"EC","crv":"P-256","x":"`, string(x[:xn]), `","y":"`, string(y[:yn]), `"}`)
}

// jwk_to_p256 reads a JWK's two coordinates into a public key.
jwk_to_p256 :: proc(jwk: string, pub: ^ecdsa.Public_Key) -> bool {
	v, err := json.parse_string(jwk, .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return false
	}
	x := str_of(o, "x")
	y := str_of(o, "y")
	if str_of(o, "crv") != "P-256" || x == "" || y == "" {
		return false
	}
	point: [65]u8
	point[0] = 4
	if base64url_decode(x, point[1:33]) != 32 || base64url_decode(y, point[33:65]) != 32 {
		return false
	}
	return ecdsa.public_key_set_bytes(pub, .SECP256R1, point[:])
}

// -- Signing and verifying ------------------------------------------------------------

// sign_es256 writes the compact JWS of `header` and `payload` signed by
// `priv` into `into`: the two as base64url, a dot between, and the
// signature, raw r and s, base64url after a third dot.
sign_es256 :: proc(priv: ^ecdsa.Private_Key, header: string, payload: string, into: []u8) -> string {
	n := base64url_encode(transmute([]u8)header, into)
	if n == 0 || n + 1 >= len(into) {
		return ""
	}
	into[n] = '.'
	n += 1
	pn := base64url_encode(transmute([]u8)payload, into[n:])
	if pn == 0 {
		return ""
	}
	n += pn
	sig: [64]u8
	if !ecdsa.sign_raw(priv, .SHA256, into[:n], sig[:]) {
		return ""
	}
	if n + 1 >= len(into) {
		return ""
	}
	into[n] = '.'
	n += 1
	sn := base64url_encode(sig[:], into[n:])
	if sn == 0 {
		return ""
	}
	return string(into[:n + sn])
}

// verify_es256 checks a compact JWS against `pub` and answers its header
// and payload, decoded into `hbuf` and `pbuf`.
verify_es256 :: proc(jws: string, pub: ^ecdsa.Public_Key, hbuf: []u8, pbuf: []u8) -> (header: string, payload: string, ok: bool) {
	d1 := -1
	d2 := -1
	for i in 0 ..< len(jws) {
		if jws[i] == '.' {
			if d1 < 0 {
				d1 = i
			} else if d2 < 0 {
				d2 = i
			} else {
				return "", "", false
			}
		}
	}
	if d1 < 0 || d2 < 0 {
		return "", "", false
	}
	sig: [64]u8
	if base64url_decode(jws[d2 + 1:], sig[:]) != 64 {
		return "", "", false
	}
	if !ecdsa.verify_raw(pub, .SHA256, transmute([]u8)jws[:d2], sig[:]) {
		return "", "", false
	}
	hn := base64url_decode(jws[:d1], hbuf)
	pn := base64url_decode(jws[d1 + 1:d2], pbuf)
	if hn < 0 || pn < 0 {
		return "", "", false
	}
	return string(hbuf[:hn]), string(pbuf[:pn]), true
}

// -- A DPoP proof ---------------------------------------------------------------------

// dpop_header writes the header of a proof: the type, the algorithm, and
// the key as a JWK.
dpop_header :: proc(pub: ^ecdsa.Public_Key, into: []u8) -> string {
	jwk: [160]u8
	return cat(into, `{"typ":"dpop+jwt","alg":"ES256","jwk":`, jwk_p256(pub, jwk[:]), `}`)
}

/*
dpop_payload writes the payload of a proof: a fresh id, the method and
the URL of the request, the time, the server's nonce when it gave one,
and the access token's hash when the request carries one, `ath`,
base64url of its SHA-256.
*/
dpop_payload :: proc(jti: string, method: string, url: string, iat: i64, nonce: string, token: string, into: []u8) -> string {
	num: [24]u8
	s := cat(into, `{"jti":"`, jti, `","htm":"`, method, `","htu":"`, url, `","iat":`, itoa(num[:], iat))
	n := len(s)
	if nonce != "" {
		n = len(cat(into[:], s, `,"nonce":"`, nonce, `"`))
		s = string(into[:n])
	}
	if token != "" {
		digest: [32]u8
		hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)token, digest[:])
		ath: [48]u8
		an := base64url_encode(digest[:], ath[:])
		n = len(cat(into[:], s, `,"ath":"`, string(ath[:an]), `"`))
		s = string(into[:n])
	}
	n = len(cat(into[:], s, `}`))
	return string(into[:n])
}

// -- Small things -------------------------------------------------------------------

str_of :: proc(o: json.Object, key: string) -> string {
	if v, has := (map[string]json.Value)(o)[key]; has {
		if s, is := v.(json.String); is {
			return string(s)
		}
	}
	return ""
}

// cat joins strings into `into`. A part may lie inside `into` already,
// at its start, since a payload grows in place.
cat :: proc(into: []u8, parts: ..string) -> string {
	n := 0
	for part in parts {
		if len(part) > 0 && raw_data(part) == raw_data(into[n:]) {
			// Already there.
			n += len(part)
			continue
		}
		if n + len(part) > len(into) {
			break
		}
		copy(into[n:], part)
		n += len(part)
	}
	return string(into[:n])
}

itoa :: proc(buf: []u8, v: i64) -> string {
	if v == 0 {
		buf[0] = '0'
		return string(buf[:1])
	}
	n := 0
	x := v
	neg := x < 0
	if neg {
		x = -x
	}
	tmp: [24]u8
	t := 0
	for x > 0 {
		tmp[t] = u8('0' + x % 10)
		t += 1
		x /= 10
	}
	if neg {
		buf[n] = '-'
		n += 1
	}
	for t > 0 {
		t -= 1
		buf[n] = tmp[t]
		n += 1
	}
	return string(buf[:n])
}
