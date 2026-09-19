/*
OCB, RFC 7253, over AES: the AEAD mode version 2 sealed data uses. Two
hundred lines over `core:crypto/aes`, since the core has no OCB of its
own. A nonce is fifteen octets and a tag sixteen, as OpenPGP fixes them.
*/
package libpgp

import "core:crypto/aes"

BLOCK :: 16
TAG :: 16
NONCE :: 15

Ocb :: struct {
	ecb:    aes.Context_ECB,
	lstar:  [BLOCK]u8,
	ldollar: [BLOCK]u8,
	l:      [64][BLOCK]u8, // L_i for i up to 63, more than any chunk needs
}

ocb_init :: proc(o: ^Ocb, key: []u8) {
	aes.init_ecb(&o.ecb, key)
	zero: [BLOCK]u8
	aes.encrypt_ecb(&o.ecb, o.lstar[:], zero[:])
	o.ldollar = double(o.lstar)
	o.l[0] = double(o.ldollar)
	for i in 1 ..< len(o.l) {
		o.l[i] = double(o.l[i - 1])
	}
}

// double is the doubling in GF(2^128) the mode is built on.
@(private = "file")
double :: proc "contextless" (s: [BLOCK]u8) -> (d: [BLOCK]u8) #no_bounds_check {
	carry := s[0] >> 7
	for i in 0 ..< BLOCK - 1 {
		d[i] = s[i] << 1 | s[i + 1] >> 7
	}
	d[BLOCK - 1] = s[BLOCK - 1] << 1
	if carry != 0 {
		d[BLOCK - 1] ~= 0x87
	}
	return d
}

@(private = "file")
ntz :: proc "contextless" (i: int) -> int {
	n := 0
	x := i
	for x & 1 == 0 {
		x >>= 1
		n += 1
	}
	return n
}

@(private = "file")
xor_block :: proc "contextless" (a, b: [BLOCK]u8) -> (c: [BLOCK]u8) {
	for i in 0 ..< BLOCK {
		c[i] = a[i] ~ b[i]
	}
	return c
}

// offset_0 is the initial offset from the nonce, the mode's stretch.
@(private = "file")
offset_0 :: proc(o: ^Ocb, nonce: []u8) -> (off: [BLOCK]u8) #no_bounds_check {
	n: [BLOCK]u8
	// TAGLEN mod 128 in the top seven bits is zero for a full tag; then a
	// one bit and the fifteen-octet nonce.
	n[0] = 0x01
	copy(n[1:], nonce[:NONCE])
	bottom := int(n[BLOCK - 1] & 0x3F)
	n[BLOCK - 1] &= 0xC0
	ktop: [BLOCK]u8
	aes.encrypt_ecb(&o.ecb, ktop[:], n[:])
	stretch: [24]u8
	copy(stretch[:], ktop[:])
	for i in 0 ..< 8 {
		stretch[16 + i] = ktop[i] ~ ktop[i + 1]
	}
	// Offset_0 = Stretch[bottom .. bottom+127], a bit offset.
	byte_off := bottom / 8
	bit_off := uint(bottom % 8)
	for i in 0 ..< BLOCK {
		if bit_off == 0 {
			off[i] = stretch[byte_off + i]
		} else {
			off[i] = stretch[byte_off + i] << bit_off | stretch[byte_off + i + 1] >> (8 - bit_off)
		}
	}
	return off
}

// hash_aad is HASH(K, A), the associated data's contribution to the tag.
@(private = "file")
hash_aad :: proc(o: ^Ocb, aad: []u8) -> (sum: [BLOCK]u8) #no_bounds_check {
	off: [BLOCK]u8
	i := 1
	at := 0
	for at + BLOCK <= len(aad) {
		off = xor_block(off, o.l[ntz(i)])
		x: [BLOCK]u8
		copy(x[:], aad[at:at + BLOCK])
		x = xor_block(x, off)
		e: [BLOCK]u8
		aes.encrypt_ecb(&o.ecb, e[:], x[:])
		sum = xor_block(sum, e)
		at += BLOCK
		i += 1
	}
	if at < len(aad) {
		off = xor_block(off, o.lstar)
		x: [BLOCK]u8
		n := copy(x[:], aad[at:])
		x[n] = 0x80
		x = xor_block(x, off)
		e: [BLOCK]u8
		aes.encrypt_ecb(&o.ecb, e[:], x[:])
		sum = xor_block(sum, e)
	}
	return sum
}

/*
ocb_open decrypts `ct`, whose last sixteen octets are its tag, into `pt`,
which needs `len(ct) - 16` octets, and answers whether the tag held. A
tag that does not hold leaves nothing usable in `pt`.
*/
ocb_open :: proc(o: ^Ocb, nonce: []u8, aad: []u8, ct: []u8, pt: []u8) -> bool #no_bounds_check {
	if len(ct) < TAG || len(pt) < len(ct) - TAG {
		return false
	}
	body := ct[:len(ct) - TAG]
	off := offset_0(o, nonce)
	sum: [BLOCK]u8
	i := 1
	at := 0
	for at + BLOCK <= len(body) {
		off = xor_block(off, o.l[ntz(i)])
		x: [BLOCK]u8
		copy(x[:], body[at:at + BLOCK])
		x = xor_block(x, off)
		d: [BLOCK]u8
		aes.decrypt_ecb(&o.ecb, d[:], x[:])
		d = xor_block(d, off)
		copy(pt[at:], d[:])
		sum = xor_block(sum, d)
		at += BLOCK
		i += 1
	}
	if at < len(body) {
		off = xor_block(off, o.lstar)
		pad: [BLOCK]u8
		aes.encrypt_ecb(&o.ecb, pad[:], off[:])
		n := len(body) - at
		p: [BLOCK]u8
		for k in 0 ..< n {
			p[k] = body[at + k] ~ pad[k]
			pt[at + k] = p[k]
		}
		p[n] = 0x80
		sum = xor_block(sum, p)
	}
	t := xor_block(xor_block(sum, off), o.ldollar)
	tag: [BLOCK]u8
	aes.encrypt_ecb(&o.ecb, tag[:], t[:])
	tag = xor_block(tag, hash_aad(o, aad))
	diff := u8(0)
	for k in 0 ..< TAG {
		diff |= tag[k] ~ ct[len(body) + k]
	}
	if diff != 0 {
		for k in 0 ..< len(body) {
			pt[k] = 0
		}
		return false
	}
	return true
}

// ocb_seal encrypts `pt` into `ct`, which needs sixteen octets more, the
// tag at its end.
ocb_seal :: proc(o: ^Ocb, nonce: []u8, aad: []u8, pt: []u8, ct: []u8) -> bool #no_bounds_check {
	if len(ct) < len(pt) + TAG {
		return false
	}
	off := offset_0(o, nonce)
	sum: [BLOCK]u8
	i := 1
	at := 0
	for at + BLOCK <= len(pt) {
		off = xor_block(off, o.l[ntz(i)])
		x: [BLOCK]u8
		copy(x[:], pt[at:at + BLOCK])
		sum = xor_block(sum, x)
		x = xor_block(x, off)
		e: [BLOCK]u8
		aes.encrypt_ecb(&o.ecb, e[:], x[:])
		e = xor_block(e, off)
		copy(ct[at:], e[:])
		at += BLOCK
		i += 1
	}
	if at < len(pt) {
		off = xor_block(off, o.lstar)
		pad: [BLOCK]u8
		aes.encrypt_ecb(&o.ecb, pad[:], off[:])
		n := len(pt) - at
		p: [BLOCK]u8
		for k in 0 ..< n {
			p[k] = pt[at + k]
			ct[at + k] = p[k] ~ pad[k]
		}
		p[n] = 0x80
		sum = xor_block(sum, p)
	}
	t := xor_block(xor_block(sum, off), o.ldollar)
	tag: [BLOCK]u8
	aes.encrypt_ecb(&o.ecb, tag[:], t[:])
	tag = xor_block(tag, hash_aad(o, aad))
	copy(ct[len(pt):], tag[:])
	return true
}

// -- AES key wrap, RFC 3394 -------------------------------------------------------------

// unwrap opens an AES key wrap of `wrapped`, whose length is a multiple of
// eight plus eight, into `out`, and answers whether the integrity check
// held.
unwrap :: proc(key: []u8, wrapped: []u8, out: []u8) -> bool #no_bounds_check {
	if len(wrapped) < 24 || len(wrapped) % 8 != 0 || len(out) < len(wrapped) - 8 {
		return false
	}
	n := len(wrapped) / 8 - 1
	ecb: aes.Context_ECB
	aes.init_ecb(&ecb, key)
	a: [8]u8
	copy(a[:], wrapped[:8])
	copy(out[:n * 8], wrapped[8:])
	for j := 5; j >= 0; j -= 1 {
		for i := n; i >= 1; i -= 1 {
			t := u64(n * j + i)
			b: [16]u8
			for k in 0 ..< 8 {
				b[k] = a[k] ~ u8(t >> uint(8 * (7 - k)))
			}
			copy(b[8:], out[(i - 1) * 8:i * 8])
			d: [16]u8
			aes.decrypt_ecb(&ecb, d[:], b[:])
			copy(a[:], d[:8])
			copy(out[(i - 1) * 8:], d[8:])
		}
	}
	diff := u8(0)
	for k in 0 ..< 8 {
		diff |= a[k] ~ 0xA6
	}
	return diff == 0
}

// wrap is the other direction: `key_data` of a multiple of eight octets
// into `out`, eight octets longer.
wrap :: proc(key: []u8, key_data: []u8, out: []u8) -> bool #no_bounds_check {
	if len(key_data) < 16 || len(key_data) % 8 != 0 || len(out) < len(key_data) + 8 {
		return false
	}
	n := len(key_data) / 8
	ecb: aes.Context_ECB
	aes.init_ecb(&ecb, key)
	a: [8]u8
	for k in 0 ..< 8 {
		a[k] = 0xA6
	}
	copy(out[8:], key_data)
	for j in 0 ..< 6 {
		for i in 1 ..= n {
			b: [16]u8
			copy(b[:8], a[:])
			copy(b[8:], out[i * 8:i * 8 + 8])
			e: [16]u8
			aes.encrypt_ecb(&ecb, e[:], b[:])
			t := u64(n * j + i)
			for k in 0 ..< 8 {
				a[k] = e[k] ~ u8(t >> uint(8 * (7 - k)))
			}
			copy(out[i * 8:], e[8:])
		}
	}
	copy(out[:8], a[:])
	return true
}
