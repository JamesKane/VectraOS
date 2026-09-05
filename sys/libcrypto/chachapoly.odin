/*
libcrypto -- the freestanding half of the cryptography a fleet needs.

`docs/FLEET.md` step 2 authenticates a connection with a Noise handshake, which
wants X25519, a hash, and ChaCha20-Poly1305. Odin's `core:crypto` has all of
them, but three packages -- `chacha20`, `sha2`, `hmac`/`hkdf` -- pull in
`core:sys/info` for the SIMD dispatch, and `core:sys/info` has no freestanding
backend, so they will not compile for a ring 3 program. `argon2id`, `x25519`,
`blake2s` and `poly1305` do compile, and the reference (non-SIMD) ChaCha20 in
`core:crypto/_chacha20/ref` does too.

So this vendors the one thing that is missing: the ChaCha20-Poly1305 AEAD of
RFC 8439, built over the reference ChaCha20 and `core:crypto/poly1305`. The
Noise suite the fleet speaks is `Noise_IK_25519_ChaChaPoly_BLAKE2s`, and every
primitive under it is here or re-exported from a package that already builds.

This is the same construction `core:crypto/chacha20poly1305` is, minus the SIMD
that costs the freestanding build. `tests/crypto` proves it against the RFC's
own test vector before anything trusts it.
*/
package libcrypto

import ref "core:crypto/_chacha20/ref"
import cc "core:crypto/_chacha20"
import "core:crypto/poly1305"

KEY_SIZE :: 32
NONCE_SIZE :: 12
TAG_SIZE :: 16

// xor runs the ChaCha20 keystream over `src` into `dst` for any length, whole
// blocks at a time and the tail by hand. The context's counter advances by
// what it consumes, so a caller sets the counter once and streams.
@(private)
xor :: proc(ctx: ^cc.Context, dst, src: []u8) #no_bounds_check {
	n := len(src)
	full := n / cc.BLOCK_SIZE
	if full > 0 {
		ref.stream_blocks(ctx, dst[:full * cc.BLOCK_SIZE], src[:full * cc.BLOCK_SIZE], full)
	}
	rem := n - full * cc.BLOCK_SIZE
	if rem > 0 {
		ks: [cc.BLOCK_SIZE]u8
		ref.stream_blocks(ctx, ks[:], nil, 1)
		off := full * cc.BLOCK_SIZE
		for i in 0 ..< rem {
			dst[off + i] = src[off + i] ~ ks[i]
		}
	}
}

// pad16 feeds a poly1305 context the zeros that round `n` up to a multiple of
// sixteen, which is what the AEAD's MAC covers between its parts.
@(private)
pad16 :: proc(ctx: ^poly1305.Context, n: int) {
	r := n % 16
	if r != 0 {
		zeros: [16]u8
		poly1305.update(ctx, zeros[:16 - r])
	}
}

// le64 feeds a little-endian length to the MAC.
@(private)
le64 :: proc(ctx: ^poly1305.Context, v: u64) {
	b: [8]u8
	x := v
	for i in 0 ..< 8 {
		b[i] = u8(x)
		x >>= 8
	}
	poly1305.update(ctx, b[:])
}

/*
mac computes the AEAD tag over the associated data and the ciphertext, keyed by
the one-time Poly1305 key. It is `aad | pad | ciphertext | pad | len(aad) |
len(ciphertext)`, each length a little-endian u64. Streamed through the
context so nothing is copied into one buffer.
*/
@(private)
mac :: proc(otk: []u8, aad, ciphertext: []u8, tag: []u8) {
	ctx: poly1305.Context
	poly1305.init(&ctx, otk)
	poly1305.update(&ctx, aad)
	pad16(&ctx, len(aad))
	poly1305.update(&ctx, ciphertext)
	pad16(&ctx, len(ciphertext))
	le64(&ctx, u64(len(aad)))
	le64(&ctx, u64(len(ciphertext)))
	poly1305.final(&ctx, tag)
}

/*
seal encrypts `plaintext` into `dst` and writes the sixteen-byte tag into
`tag`, under `key` and `nonce`, with `aad` authenticated but not encrypted.
`dst` is the length of `plaintext`. This is RFC 8439's AEAD: a Poly1305 key
from the first keystream block, the plaintext from the rest, and the tag over
both.
*/
seal :: proc(dst, tag, key, nonce, aad, plaintext: []u8) #no_bounds_check {
	ctx: cc.Context
	cc.init(&ctx, key, nonce, false)
	// Block zero is the one-time Poly1305 key; encryption starts at block one.
	otk: [cc.BLOCK_SIZE]u8
	ref.stream_blocks(&ctx, otk[:], nil, 1)
	xor(&ctx, dst, plaintext)
	mac(otk[:32], aad, dst, tag)
	cc.reset(&ctx)
}

/*
open verifies the tag and decrypts `ciphertext` into `dst`, and answers whether
the tag held. On a false answer `dst` is not to be trusted. The tag is checked
before the plaintext is looked at, in constant time, which is Poly1305's own
`verify`.
*/
open :: proc(dst, key, nonce, aad, ciphertext, tag: []u8) -> bool #no_bounds_check {
	ctx: cc.Context
	cc.init(&ctx, key, nonce, false)
	otk: [cc.BLOCK_SIZE]u8
	ref.stream_blocks(&ctx, otk[:], nil, 1)
	want: [TAG_SIZE]u8
	mac(otk[:32], aad, ciphertext, want[:])
	if !ct_equal(want[:], tag) {
		cc.reset(&ctx)
		return false
	}
	xor(&ctx, dst, ciphertext)
	cc.reset(&ctx)
	return true
}

// ct_equal compares two byte slices without a data-dependent branch.
ct_equal :: proc(a, b: []u8) -> bool #no_bounds_check {
	if len(a) != len(b) {
		return false
	}
	diff: u8 = 0
	for i in 0 ..< len(a) {
		diff |= a[i] ~ b[i]
	}
	return diff == 0
}
