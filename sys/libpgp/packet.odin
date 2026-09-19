/*
libpgp -- OpenPGP, RFC 9580, and no more of it than Autocrypt needs.

`docs/WEB.md` section 6. Keys of version 4 and 6 on Ed25519 and X25519, a
signature, a sealed session key, and sealed data in version 2, which is
AES in OCB mode. This file is the packets: the framing every packet
shares, and the fields of the ones the seal reads. `seal.odin` verifies
and opens, `ocb.odin` is the AEAD mode over `core:crypto/aes`. Nothing
here reaches ring 3, so a host harness builds it against the RFC's own
test vectors, and the boot line runs the same through `tests/pgp`.

A packet is a tag and a body. The OpenPGP format's lengths are one, two
or five octets, or partial, and the legacy format's are counted in the
tag's low bits. `next` walks a stream of them.

Not yet: RSA and ECDSA keys, version 1 sealed data, compressed data,
and the passphrase-locked secret key.
*/
package libpgp

import "core:crypto/hash"

// Packet type IDs.
PKESK :: 1
SIGNATURE :: 2
SKESK :: 3
ONE_PASS :: 4
SECRET_KEY :: 5
PUBLIC_KEY :: 6
SECRET_SUBKEY :: 7
COMPRESSED :: 8
LITERAL :: 11
USER_ID :: 13
PUBLIC_SUBKEY :: 14
SEIPD :: 18
PADDING :: 21

// Public key algorithms.
ALGO_RSA :: 1
ALGO_X25519 :: 25
ALGO_ED25519 :: 27

// Hash algorithms.
HASH_SHA256 :: 8
HASH_SHA512 :: 10

// Symmetric ciphers and AEAD modes.
CIPHER_AES128 :: 7
CIPHER_AES256 :: 9
AEAD_OCB :: 2

Packet :: struct {
	tag:     int,
	body:    []u8,
	partial: bool, // The body was given in partial lengths, joined here
}

/*
next reads the packet at `at` and answers it and where the next begins.
False at the end or on a header that does not parse. A body given in
partial lengths is answered as its first part only when `join` is nil;
with a buffer, the parts are joined into it.
*/
next :: proc(data: []u8, at: int, join: []u8 = nil) -> (p: Packet, after: int, ok: bool) #no_bounds_check {
	if at >= len(data) {
		return p, at, false
	}
	first := data[at]
	if first & 0x80 == 0 {
		return p, at, false
	}
	i := at + 1
	if first & 0x40 != 0 {
		p.tag = int(first & 0x3F)
		n, used, partial, lok := body_length(data, i)
		if !lok {
			return p, at, false
		}
		i += used
		if !partial {
			if i + n > len(data) {
				return p, at, false
			}
			p.body = data[i:i + n]
			return p, i + n, true
		}
		// Partial lengths: parts until one that is not partial.
		total := 0
		for {
			if i + n > len(data) {
				return p, at, false
			}
			if join != nil {
				if total + n > len(join) {
					return p, at, false
				}
				copy(join[total:], data[i:i + n])
			}
			total += n
			i += n
			if !partial {
				break
			}
			n, used, partial, lok = body_length(data, i)
			if !lok {
				return p, at, false
			}
			i += used
		}
		p.partial = true
		if join != nil {
			p.body = join[:total]
		}
		return p, i, true
	}
	// The legacy format: the tag in bits 5-2, the length's size in bits 1-0.
	p.tag = int(first >> 2 & 0x0F)
	n := 0
	switch first & 3 {
	case 0:
		if i >= len(data) {
			return p, at, false
		}
		n = int(data[i])
		i += 1
	case 1:
		if i + 2 > len(data) {
			return p, at, false
		}
		n = int(data[i]) << 8 | int(data[i + 1])
		i += 2
	case 2:
		if i + 4 > len(data) {
			return p, at, false
		}
		n = int(data[i]) << 24 | int(data[i + 1]) << 16 | int(data[i + 2]) << 8 | int(data[i + 3])
		i += 4
	case 3:
		n = len(data) - i
	}
	if i + n > len(data) {
		return p, at, false
	}
	p.body = data[i:i + n]
	return p, i + n, true
}

// body_length reads an OpenPGP format length at `at`: how many octets the
// body has, how many the length took, and whether it is a partial one.
body_length :: proc(data: []u8, at: int) -> (n: int, used: int, partial: bool, ok: bool) #no_bounds_check {
	if at >= len(data) {
		return 0, 0, false, false
	}
	b := int(data[at])
	switch {
	case b < 192:
		return b, 1, false, true
	case b < 224:
		if at + 1 >= len(data) {
			return 0, 0, false, false
		}
		return (b - 192) << 8 + int(data[at + 1]) + 192, 2, false, true
	case b < 255:
		return 1 << uint(b & 0x1F), 1, true, true
	}
	if at + 4 >= len(data) {
		return 0, 0, false, false
	}
	return int(data[at + 1]) << 24 | int(data[at + 2]) << 16 | int(data[at + 3]) << 8 | int(data[at + 4]), 5, false, true
}

// -- Keys ------------------------------------------------------------------------

Key :: struct {
	version:     int,
	created:     u32,
	algo:        int,
	public:      []u8, // The key material: 32 octets for Ed25519 and X25519
	secret:      []u8, // The secret material when the packet has it and it is not locked
	locked:      bool, // A secret packet with an S2K on it
	fingerprint: [32]u8, // 20 octets for version 4, 32 for version 6
	fpr_len:     int,
	body:        []u8, // The public fields, what a fingerprint and a signature hash
	subkey:      bool,
}

/*
parse_key reads a key packet of any of the four kinds. The fingerprint is
computed here: SHA-1 of `0x99`, a two-octet length and the public fields
for version 4, SHA-256 of `0x9B`, a four-octet length and the same for
version 6.
*/
parse_key :: proc(p: Packet) -> (k: Key, ok: bool) #no_bounds_check {
	b := p.body
	if len(b) < 6 {
		return k, false
	}
	k.subkey = p.tag == PUBLIC_SUBKEY || p.tag == SECRET_SUBKEY
	k.version = int(b[0])
	k.created = u32(b[1]) << 24 | u32(b[2]) << 16 | u32(b[3]) << 8 | u32(b[4])
	k.algo = int(b[5])
	at := 6
	count := 0
	switch k.version {
	case 4:
		count = material_length(k.algo, b[at:])
	case 6:
		if len(b) < 10 {
			return k, false
		}
		count = int(b[6]) << 24 | int(b[7]) << 16 | int(b[8]) << 8 | int(b[9])
		at = 10
	case:
		return k, false
	}
	if count < 0 || at + count > len(b) {
		return k, false
	}
	k.public = b[at:at + count]
	k.body = b[:at + count]
	at += count
	if p.tag == SECRET_KEY || p.tag == SECRET_SUBKEY {
		if at >= len(b) {
			return k, false
		}
		usage := b[at]
		at += 1
		if usage != 0 {
			k.locked = true
		} else {
			n := material_length(k.algo, b[at:])
			if n < 0 || at + n > len(b) {
				return k, false
			}
			k.secret = b[at:at + n]
		}
	}
	// The fingerprint.
	head: [5]u8
	ctx: hash.Context
	if k.version == 6 {
		head[0] = 0x9B
		n := len(k.body)
		head[1], head[2], head[3], head[4] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
		hash.init(&ctx, .SHA256)
		hash.update(&ctx, head[:5])
		hash.update(&ctx, k.body)
		hash.final(&ctx, k.fingerprint[:32])
		k.fpr_len = 32
	} else {
		head[0] = 0x99
		n := len(k.body)
		head[1], head[2] = u8(n >> 8), u8(n)
		hash.init(&ctx, .Insecure_SHA1)
		hash.update(&ctx, head[:3])
		hash.update(&ctx, k.body)
		hash.final(&ctx, k.fingerprint[:20])
		k.fpr_len = 20
	}
	return k, true
}

// material_length answers how many octets an algorithm's key material takes
// in a version 4 key, or the secret part of any key: the fixed-size
// curves, or an MPI's length for RSA. Negative for an algorithm not read.
material_length :: proc(algo: int, rest: []u8) -> int #no_bounds_check {
	switch algo {
	case ALGO_ED25519, ALGO_X25519:
		return 32
	case ALGO_RSA:
		// MPIs: a two-octet bit count and the bytes, twice for a public key.
		at := 0
		for _ in 0 ..< 2 {
			if at + 2 > len(rest) {
				return -1
			}
			bits := int(rest[at]) << 8 | int(rest[at + 1])
			at += 2 + (bits + 7) / 8
		}
		return at
	}
	return -1
}

// -- Signatures ------------------------------------------------------------------

Signature :: struct {
	version:  int,
	type:     int,
	algo:     int,
	hash:     int,
	hashed:   []u8, // The hashed subpackets, as they stand
	unhashed: []u8,
	left:     [2]u8, // The hash's first two octets
	salt:     []u8, // Version 6
	material: []u8, // 64 octets for Ed25519
	trailer:  []u8, // The body from the version through the hashed subpackets
}

parse_signature :: proc(p: Packet) -> (s: Signature, ok: bool) #no_bounds_check {
	b := p.body
	if len(b) < 6 {
		return s, false
	}
	s.version = int(b[0])
	if s.version != 4 && s.version != 6 {
		return s, false
	}
	s.type = int(b[1])
	s.algo = int(b[2])
	s.hash = int(b[3])
	at := 4
	hn := 0
	if s.version == 6 {
		if at + 4 > len(b) {
			return s, false
		}
		hn = int(b[at]) << 24 | int(b[at + 1]) << 16 | int(b[at + 2]) << 8 | int(b[at + 3])
		at += 4
	} else {
		hn = int(b[at]) << 8 | int(b[at + 1])
		at += 2
	}
	if at + hn > len(b) {
		return s, false
	}
	s.hashed = b[at:at + hn]
	at += hn
	s.trailer = b[:at]
	un := 0
	if s.version == 6 {
		if at + 4 > len(b) {
			return s, false
		}
		un = int(b[at]) << 24 | int(b[at + 1]) << 16 | int(b[at + 2]) << 8 | int(b[at + 3])
		at += 4
	} else {
		if at + 2 > len(b) {
			return s, false
		}
		un = int(b[at]) << 8 | int(b[at + 1])
		at += 2
	}
	if at + un + 2 > len(b) {
		return s, false
	}
	s.unhashed = b[at:at + un]
	at += un
	s.left[0], s.left[1] = b[at], b[at + 1]
	at += 2
	if s.version == 6 {
		if at >= len(b) {
			return s, false
		}
		sn := int(b[at])
		at += 1
		if at + sn > len(b) {
			return s, false
		}
		s.salt = b[at:at + sn]
		at += sn
	}
	s.material = b[at:]
	return s, true
}

// Subpacket types the seal reads.
SUB_CREATED :: 2
SUB_KEY_FLAGS :: 27
SUB_ISSUER_FPR :: 33

// subpacket answers the first subpacket of `type` in a hashed area, or
// false. The critical bit on the type is not counted.
subpacket :: proc(area: []u8, type: int) -> ([]u8, bool) #no_bounds_check {
	at := 0
	for at < len(area) {
		n, used, partial, ok := body_length(area, at)
		if !ok || partial || n < 1 {
			return nil, false
		}
		at += used
		if at + n > len(area) {
			return nil, false
		}
		if int(area[at] & 0x7F) == type {
			return area[at + 1:at + n], true
		}
		at += n
	}
	return nil, false
}

// -- The sealed packets --------------------------------------------------------------

// A version 6 Public Key Encrypted Session Key packet, X25519.
Pkesk :: struct {
	version:     int,
	fingerprint: []u8, // Empty for an anonymous recipient
	algo:        int,
	ephemeral:   []u8, // 32 octets
	wrapped:     []u8, // The session key, AES key wrapped
}

parse_pkesk :: proc(p: Packet) -> (e: Pkesk, ok: bool) #no_bounds_check {
	b := p.body
	if len(b) < 3 || b[0] != 6 {
		return e, false
	}
	e.version = 6
	fn := int(b[1])
	at := 2
	if fn > 0 {
		// A key version octet, then the fingerprint.
		if at + fn > len(b) {
			return e, false
		}
		e.fingerprint = b[at + 1:at + fn]
		at += fn
	}
	if at >= len(b) {
		return e, false
	}
	e.algo = int(b[at])
	at += 1
	if e.algo != ALGO_X25519 || at + 33 > len(b) {
		return e, false
	}
	e.ephemeral = b[at:at + 32]
	at += 32
	n := int(b[at])
	at += 1
	if at + n > len(b) {
		return e, false
	}
	e.wrapped = b[at:at + n]
	return e, true
}

// A version 2 Symmetrically Encrypted and Integrity Protected Data packet.
Seipd :: struct {
	cipher: int,
	aead:   int,
	chunk:  int, // The chunk size octet
	salt:   []u8, // 32 octets
	data:   []u8, // The chunks with their tags, then the final tag
	info:   [5]u8, // What the key derivation and each chunk's AEAD are given
}

parse_seipd :: proc(p: Packet) -> (s: Seipd, ok: bool) #no_bounds_check {
	b := p.body
	if len(b) < 4 + 32 + 16 || b[0] != 2 {
		return s, false
	}
	s.cipher = int(b[1])
	s.aead = int(b[2])
	s.chunk = int(b[3])
	s.salt = b[4:36]
	s.data = b[36:]
	s.info = [5]u8{0xC0 | SEIPD, 2, u8(s.cipher), u8(s.aead), u8(s.chunk)}
	return s, true
}

// A Literal Data packet: a format, a name, a date, the data.
Literal :: struct {
	format: u8, // 'b', 't' or 'u'
	name:   []u8,
	date:   u32,
	data:   []u8,
}

parse_literal :: proc(p: Packet) -> (l: Literal, ok: bool) #no_bounds_check {
	b := p.body
	if len(b) < 6 {
		return l, false
	}
	l.format = b[0]
	n := int(b[1])
	if 2 + n + 4 > len(b) {
		return l, false
	}
	l.name = b[2:2 + n]
	at := 2 + n
	l.date = u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
	l.data = b[at + 4:]
	return l, true
}
