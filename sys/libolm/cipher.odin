/*
libolm -- Olm and Megolm, the seal every Matrix client speaks:
`docs/WEB.md` section 8. This file is what both share: the keys a
message key or a ratchet derives, AES-256 in CBC mode with PKCS#7
padding, a page over `core:crypto/aes`, and the truncated HMAC that
authenticates a message.
*/
package libolm

import "core:crypto/aes"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/hmac"

// The keys one message is sealed with: derived by HKDF-SHA-256, with a
// zero salt, from a message key or a ratchet, under the protocol's name.
Keys :: struct {
	aes: [32]u8,
	mac: [32]u8,
	iv:  [16]u8,
}

derive_keys :: proc(ikm: []u8, info: string, k: ^Keys) {
	zero: [32]u8
	out: [80]u8
	hkdf.extract_and_expand(.SHA256, zero[:], ikm, transmute([]u8)info, out[:])
	copy(k.aes[:], out[:32])
	copy(k.mac[:], out[32:64])
	copy(k.iv[:], out[64:80])
}

// cbc_encrypt seals `src` into `dst`, padded to the block, and answers
// the length, or -1 when `dst` is too small: it needs the length of `src`
// rounded up to the next block.
cbc_encrypt :: proc(key: []u8, iv: []u8, src: []u8, dst: []u8) -> int {
	pad := 16 - len(src) % 16
	n := len(src) + pad
	if len(dst) < n {
		return -1
	}
	ctx: aes.Context_ECB
	aes.init_ecb(&ctx, key)
	defer aes.reset_ecb(&ctx)
	prev: [16]u8
	copy(prev[:], iv)
	block: [16]u8
	for i := 0; i < n; i += 16 {
		for b in 0 ..< 16 {
			v := i + b < len(src) ? src[i + b] : u8(pad)
			block[b] = v ~ prev[b]
		}
		aes.encrypt_ecb(&ctx, dst[i:i + 16], block[:])
		copy(prev[:], dst[i:i + 16])
	}
	return n
}

// cbc_decrypt opens `src` into `dst` and answers the length without the
// padding, or false for a length that is not blocks or padding that is
// not padding.
cbc_decrypt :: proc(key: []u8, iv: []u8, src: []u8, dst: []u8) -> (int, bool) {
	if len(src) == 0 || len(src) % 16 != 0 || len(dst) < len(src) {
		return 0, false
	}
	ctx: aes.Context_ECB
	aes.init_ecb(&ctx, key)
	defer aes.reset_ecb(&ctx)
	prev: [16]u8
	copy(prev[:], iv)
	for i := 0; i < len(src); i += 16 {
		aes.decrypt_ecb(&ctx, dst[i:i + 16], src[i:i + 16])
		for b in 0 ..< 16 {
			dst[i + b] ~= prev[b]
		}
		copy(prev[:], src[i:i + 16])
	}
	pad := int(dst[len(src) - 1])
	if pad < 1 || pad > 16 || pad > len(src) {
		return 0, false
	}
	for b in 0 ..< pad {
		if dst[len(src) - 1 - b] != u8(pad) {
			return 0, false
		}
	}
	return len(src) - pad, true
}

// mac8 writes the first eight bytes of HMAC-SHA-256 of `msg` under `key`.
mac8 :: proc(key: []u8, msg: []u8, out: []u8) {
	full: [32]u8
	hmac.sum(.SHA256, full[:], msg, key)
	copy(out, full[:8])
}

// hmac_byte writes HMAC-SHA-256 of one byte under `key` into `out`, which
// may be the key itself.
hmac_byte :: proc(key: []u8, b: u8, out: []u8) {
	full: [32]u8
	msg := [1]u8{b}
	hmac.sum(.SHA256, full[:], msg[:], key)
	copy(out, full[:])
}

_ :: hash

// -- The payload's numbers ----------------------------------------------------------

// put_varint writes `v` as the payloads have it: seven bits a byte, the
// low bits first, the high bit set on every byte but the last.
put_varint :: proc "contextless" (dst: []u8, v: u64) -> int {
	x := v
	n := 0
	for {
		b := u8(x & 0x7f)
		x >>= 7
		if x != 0 {
			b |= 0x80
		}
		if n >= len(dst) {
			return -1
		}
		dst[n] = b
		n += 1
		if x == 0 {
			break
		}
	}
	return n
}

// get_varint reads one, answering the value and how many bytes.
get_varint :: proc "contextless" (src: []u8) -> (v: u64, n: int, ok: bool) {
	shift: u64 = 0
	for i in 0 ..< len(src) {
		if i >= 10 {
			return 0, 0, false
		}
		v |= u64(src[i] & 0x7f) << shift
		if src[i] & 0x80 == 0 {
			return v, i + 1, true
		}
		shift += 7
	}
	return 0, 0, false
}
