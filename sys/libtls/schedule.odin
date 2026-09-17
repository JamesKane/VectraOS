/*
The TLS 1.3 key schedule, RFC 8446 section 7.1.

`docs/WEB.md` step 0 builds a TLS 1.3 client, and the client is a handshake, a
key schedule and a record layer over `core:crypto`. This file is the middle
one: the ladder of secrets that every traffic key hangs from, and the two
functions -- `hkdf_expand_label` and `derive_secret` -- that the whole
protocol is written in.

The schedule sees no handshake message. It is handed a transcript hash the
caller kept with a running `hash.Context`, and it hands back secrets and keys.
That is the same division `sys/libauth`'s Noise state keeps between the mixing
and the messages, and it is what lets this half be proven on its own against
RFC 8448's published secrets before a single record is framed.

One cipher suite at a time, and every suite fixes its hash. This is written for
SHA-256, which is TLS_AES_128_GCM_SHA256's -- the mandatory suite, and the one
RFC 8448's trace runs. SHA-384 is the same ladder with a wider secret, a
constant away.
*/
package libtls

import "core:crypto/hash"
import "core:crypto/hkdf"

// The suite's hash, and its output length, which is also every secret's length.
HASH :: hash.Algorithm.SHA256
HASH_LEN :: 32

// HKDF-Expand-Label(Secret, Label, Context, Length), RFC 8446 section 7.1.
//
// The label the wire carries is "tls13 " + label, and it and the context are
// each length-prefixed by a byte, inside a struct whose first field is the
// output length. Nothing here allocates: the label is short by the protocol's
// own bound, and the assembled `HkdfLabel` is a local the caller never sees.
hkdf_expand_label :: proc(secret: []u8, label: string, ctx: []u8, out: []u8) #no_bounds_check {
	// HkdfLabel = uint16 length
	//          || uint8 len(prefix+label) || "tls13 " || label
	//          || uint8 len(ctx)          || ctx
	prefix :: "tls13 "
	buf: [2 + 1 + 255 + 1 + 255]u8
	n := 0
	buf[0] = u8(len(out) >> 8)
	buf[1] = u8(len(out))
	n = 2
	buf[n] = u8(len(prefix) + len(label))
	n += 1
	n += copy(buf[n:], prefix)
	n += copy(buf[n:], label)
	buf[n] = u8(len(ctx))
	n += 1
	n += copy(buf[n:], ctx)
	hkdf.expand(HASH, secret, buf[:n], out)
}

// Derive-Secret(Secret, Label, Messages), RFC 8446 section 7.1. The messages'
// transcript hash is the caller's to keep and to pass; this never sees them.
derive_secret :: proc(secret: []u8, label: string, transcript: []u8, out: []u8) {
	hkdf_expand_label(secret, label, transcript, out)
}

// HKDF-Extract, the ladder's every rung. TLS names its first salt and its null
// PSK "0", a string of `HASH_LEN` zero bytes; `ZEROS` is that string, and an
// empty salt would hash the same but the spec writes it out, so this does too.
ZEROS :: [HASH_LEN]u8{}

extract :: proc(salt, ikm, out: []u8) {
	hkdf.extract(HASH, salt, ikm, out)
}

/*
The three-rung ladder, RFC 8446 section 7.1, with the branches a full 1-RTT
handshake takes. Each secret is `HASH_LEN` bytes.

    early   = Extract(0, PSK|0)
    (derived from early)                 = Derive-Secret(early, "derived", "")
    handshake = Extract(derived, ECDHE)
    (derived from handshake)             = Derive-Secret(handshake, "derived", "")
    master  = Extract(derived, 0)

`empty_hash` is Transcript-Hash("") -- the context the two "derived" steps
take, and the one value the ladder needs that is a hash rather than a secret.
*/
Secrets :: struct {
	early:     [HASH_LEN]u8,
	handshake: [HASH_LEN]u8,
	master:    [HASH_LEN]u8,
}

// empty_transcript writes Transcript-Hash("") into `out`, the hash of no
// messages, which the "derived" steps and an empty-context Derive-Secret take.
empty_transcript :: proc(out: []u8) {
	hash.hash_bytes_to_buffer(HASH, {}, out)
}

// ladder walks the three extracts, given the (EC)DHE shared secret. The traffic
// secrets branch off `handshake` and `master` with a real transcript, so they
// are the handshake's to derive, not this function's.
ladder :: proc(s: ^Secrets, ecdhe: []u8) {
	empty: [HASH_LEN]u8
	empty_transcript(empty[:])

	zeros := ZEROS
	extract(zeros[:], zeros[:], s.early[:])

	derived: [HASH_LEN]u8
	derive_secret(s.early[:], "derived", empty[:], derived[:])
	extract(derived[:], ecdhe, s.handshake[:])

	derive_secret(s.handshake[:], "derived", empty[:], derived[:])
	extract(derived[:], zeros[:], s.master[:])
}

// The record layer's per-key material, RFC 8446 section 7.3: a write key and a
// write IV, each `HKDF-Expand-Label` of a traffic secret with an empty context.
Key_Iv :: struct {
	key: [16]u8, // AES-128-GCM; a suite with a wider key widens this.
	iv:  [12]u8,
}

traffic_key_iv :: proc(secret: []u8, out: ^Key_Iv) {
	hkdf_expand_label(secret, "key", {}, out.key[:])
	hkdf_expand_label(secret, "iv", {}, out.iv[:])
}
