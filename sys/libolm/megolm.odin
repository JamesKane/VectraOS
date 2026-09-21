/*
Megolm: the group ratchet, `docs/WEB.md` section 8. A ratchet is four
parts of thirty-two bytes and a counter. Advancing it rehashes a part
from the one above it every so many steps: the last part every step,
the third every 2^8, the second every 2^16, and the first every 2^24,
so it winds forward but never back, and can jump forward in at most a
thousand hashes. The keys for one message come off the whole ratchet
by HKDF under "MEGOLM_KEYS". A session is a ratchet and an Ed25519 key
that signs every message.
*/
package libolm

import "core:crypto/ed25519"

Ratchet :: struct {
	data:    [RATCHET_BYTES]u8, // Four parts of thirty-two bytes
	counter: u32,
}

RATCHET_BYTES :: 128
SHARE_BYTES :: 229 // Version, counter, ratchet, key, signature
EXPORT_BYTES :: 165 // The same without the signature

ratchet_init :: proc(m: ^Ratchet, seed: []u8, counter: u32) -> bool {
	if len(seed) < RATCHET_BYTES {
		return false
	}
	copy(m.data[:], seed[:RATCHET_BYTES])
	m.counter = counter
	return true
}

// rehash sets part `to` from part `from`: HMAC-SHA-256 of the byte `to`
// under the part `from`.
@(private = "file")
rehash :: proc(m: ^Ratchet, from: int, to: int) {
	hmac_byte(part(m, from), u8(to), part(m, to))
}

@(private = "file")
part :: proc "contextless" (m: ^Ratchet, j: int) -> []u8 {
	return m.data[j * 32:(j + 1) * 32]
}

// ratchet_advance winds the ratchet one step.
ratchet_advance :: proc(m: ^Ratchet) {
	mask: u32 = 0x00FF_FFFF
	h := 0
	m.counter += 1
	for h < 4 {
		if m.counter & mask == 0 {
			break
		}
		h += 1
		mask >>= 8
	}
	for i := 3; i >= h; i -= 1 {
		rehash(m, h, i)
	}
}

// ratchet_advance_to winds the ratchet forward to `target`, part by
// part, the way the reference does, wrapping at 2^32.
ratchet_advance_to :: proc(m: ^Ratchet, target: u32) {
	for j in 0 ..< 4 {
		shift := u32((3 - j) * 8)
		mask: u32 = (~u32(0)) << shift
		steps := int(((target >> shift) - (m.counter >> shift)) & 0xff)
		if steps == 0 {
			if target < m.counter {
				steps = 0x100
			} else {
				continue
			}
		}
		for steps > 1 {
			rehash(m, j, j)
			steps -= 1
		}
		for k := 3; k >= j; k -= 1 {
			rehash(m, j, k)
		}
		m.counter = target & mask
	}
}

// ratchet_keys derives the keys the ratchet's current value seals with.
ratchet_keys :: proc(m: ^Ratchet, k: ^Keys) {
	derive_keys(m.data[:], "MEGOLM_KEYS", k)
}

// -- Sessions ---------------------------------------------------------------------

// An outbound session: this side's ratchet, and the key that signs.
Outbound :: struct {
	ratchet: Ratchet,
	sign:    ed25519.Private_Key,
	pub:     [32]u8,
}

// An inbound session: the earliest ratchet known, so history from there
// opens, the latest seen, and the signing key to check against.
Inbound :: struct {
	first:  Ratchet,
	latest: Ratchet,
	pub:    ed25519.Public_Key,
	pub_bytes: [32]u8,
}

// outbound_init makes a session from a hundred and twenty-eight random
// bytes for the ratchet and thirty-two for the signing key.
outbound_init :: proc(o: ^Outbound, ratchet_seed: []u8, sign_seed: []u8) -> bool {
	if !ratchet_init(&o.ratchet, ratchet_seed, 0) {
		return false
	}
	if !ed25519.private_key_set_bytes(&o.sign, sign_seed) {
		return false
	}
	ed25519.private_key_public_bytes(&o.sign, o.pub[:])
	return true
}

// session_share writes the session for another participant: the format
// with the version byte 2, signed. `dst` needs SHARE_BYTES.
session_share :: proc(o: ^Outbound, dst: []u8) -> int {
	if len(dst) < SHARE_BYTES {
		return -1
	}
	n := put_ratchet(&o.ratchet, o.pub[:], 2, dst)
	ed25519.sign(&o.sign, dst[:n], dst[n:n + 64])
	return n + 64
}

// session_export writes an inbound session's earliest ratchet for keeping,
// the format with the version byte 1, unsigned. `dst` needs EXPORT_BYTES.
session_export :: proc(i: ^Inbound, dst: []u8) -> int {
	if len(dst) < EXPORT_BYTES {
		return -1
	}
	return put_ratchet(&i.first, i.pub_bytes[:], 1, dst)
}

@(private = "file")
put_ratchet :: proc(m: ^Ratchet, pub: []u8, version: u8, dst: []u8) -> int {
	dst[0] = version
	dst[1] = u8(m.counter >> 24)
	dst[2] = u8(m.counter >> 16)
	dst[3] = u8(m.counter >> 8)
	dst[4] = u8(m.counter)
	copy(dst[5:133], m.data[:])
	copy(dst[133:165], pub)
	return EXPORT_BYTES
}

// session_import makes an inbound session of a shared or an exported
// session: a shared one's signature is checked against the key inside.
session_import :: proc(i: ^Inbound, data: []u8) -> bool {
	if len(data) < EXPORT_BYTES {
		return false
	}
	version := data[0]
	switch version {
	case 2:
		if len(data) < SHARE_BYTES {
			return false
		}
	case 1:
	case:
		return false
	}
	copy(i.pub_bytes[:], data[133:165])
	if !ed25519.public_key_set_bytes(&i.pub, i.pub_bytes[:]) {
		return false
	}
	if version == 2 && !ed25519.verify(&i.pub, data[:EXPORT_BYTES], data[EXPORT_BYTES:SHARE_BYTES]) {
		return false
	}
	counter := u32(data[1]) << 24 | u32(data[2]) << 16 | u32(data[3]) << 8 | u32(data[4])
	if !ratchet_init(&i.first, data[5:133], counter) {
		return false
	}
	i.latest = i.first
	return true
}

// -- Messages ---------------------------------------------------------------------

// group_encrypt seals `plain` as the session's next message into `dst`
// and winds the ratchet: the version, the index and the cipher-text,
// eight bytes of MAC, and the signature. `dst` needs the plain-text
// rounded up a block, and ninety-five more.
group_encrypt :: proc(o: ^Outbound, plain: []u8, dst: []u8) -> int {
	k: Keys
	ratchet_keys(&o.ratchet, &k)
	clen := len(plain) + 16 - len(plain) % 16
	if len(dst) < 1 + 10 + 10 + clen + 72 {
		return -1
	}
	n := 0
	dst[n] = 3
	n += 1
	dst[n] = 0x08
	n += 1
	n += put_varint(dst[n:], u64(o.ratchet.counter))
	dst[n] = 0x12
	n += 1
	n += put_varint(dst[n:], u64(clen))
	if cbc_encrypt(k.aes[:], k.iv[:], plain, dst[n:]) != clen {
		return -1
	}
	n += clen
	mac8(k.mac[:], dst[:n], dst[n:n + 8])
	n += 8
	ed25519.sign(&o.sign, dst[:n], dst[n:n + 64])
	n += 64
	ratchet_advance(&o.ratchet)
	return n
}

// group_decrypt opens a message into `dst`, checking its signature and
// its MAC, and answers the length and the message's index. A message
// from before the earliest ratchet known cannot open.
group_decrypt :: proc(i: ^Inbound, msg: []u8, dst: []u8) -> (n: int, index: u32, ok: bool) {
	if len(msg) < 1 + 72 || msg[0] != 3 {
		return 0, 0, false
	}
	signed := msg[:len(msg) - 64]
	if !ed25519.verify(&i.pub, signed, msg[len(msg) - 64:]) {
		return 0, 0, false
	}
	body := msg[1:len(msg) - 72]
	cipher: []u8
	has_index := false
	for at := 0; at < len(body); {
		tag, num, bytes, next, fok := next_field(body, at)
		if !fok {
			return 0, 0, false
		}
		switch tag {
		case 0x08:
			index = u32(num)
			has_index = true
		case 0x12:
			cipher = bytes
		}
		at = next
	}
	if !has_index || cipher == nil {
		return 0, 0, false
	}
	// The ratchet at the message's index, from the nearest one known
	// that is not past it.
	r := i.first
	if index >= i.latest.counter && i.latest.counter >= i.first.counter {
		r = i.latest
	}
	if index < r.counter {
		return 0, index, false
	}
	ratchet_advance_to(&r, index)
	k: Keys
	ratchet_keys(&r, &k)
	if !mac8_ok(k.mac[:], msg[:len(msg) - 72], msg[len(msg) - 72:len(msg) - 64]) {
		return 0, index, false
	}
	n, ok = cbc_decrypt(k.aes[:], k.iv[:], cipher, dst)
	if ok && index >= i.latest.counter {
		i.latest = r
	}
	return n, index, ok
}
