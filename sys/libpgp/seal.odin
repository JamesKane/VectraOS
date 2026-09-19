/*
The seal's two verbs over the packets: a signature checked, and a message
opened. `docs/WEB.md` section 6.

A signature is over a hash: for version 6 the salt first, then the data,
then the packet's own fields as a trailer. The data is a key's public
fields under a key-packet header for a key signature, and the document
for a document signature. Ed25519 then signs the digest itself, as
OpenPGP has it. A message is opened by unwrapping its session key with
the key HKDF derives from an X25519 agreement, then deriving the message
key and nonce from the session key and the packet's salt, and opening
each chunk in OCB, the final tag last, which says the whole was there.
*/
package libpgp

import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/x25519"

// A transferable key: the primary, its direct-key signature, the subkeys
// and their binding signatures, as far as the seal needs them.
Cert :: struct {
	primary: Key,
	subkeys: [4]Key,
	nsub:    int,
	sigs:    [8]Signature, // In the order they came
	sig_of:  [8]int, // Which key each binds: -1 the primary, else a subkey index
	nsigs:   int,
	user_id: []u8,
}

// parse_cert reads a transferable public or secret key from its packets.
parse_cert :: proc(data: []u8) -> (c: Cert, ok: bool) {
	at := 0
	have_primary := false
	last := -2 // What a signature would bind: -1 the primary, else the subkey
	for {
		p, after, pok := next(data, at)
		if !pok {
			break
		}
		at = after
		switch p.tag {
		case PUBLIC_KEY, SECRET_KEY:
			k, kok := parse_key(p)
			if !kok || have_primary {
				return c, false
			}
			c.primary = k
			have_primary = true
			last = -1
		case PUBLIC_SUBKEY, SECRET_SUBKEY:
			k, kok := parse_key(p)
			if !kok || c.nsub >= len(c.subkeys) {
				return c, false
			}
			c.subkeys[c.nsub] = k
			last = c.nsub
			c.nsub += 1
		case SIGNATURE:
			s, sok := parse_signature(p)
			if !sok {
				return c, false
			}
			if c.nsigs < len(c.sigs) {
				c.sigs[c.nsigs] = s
				c.sig_of[c.nsigs] = last
				c.nsigs += 1
			}
		case USER_ID:
			c.user_id = p.body
		case PADDING:
		}
	}
	return c, have_primary
}

/*
verify_cert checks every signature a certificate carries against its
primary key: the direct-key signature over the primary, a certification
over the primary and the user id, and each subkey binding over the
primary and the subkey. True when every one holds and there is at least
one.
*/
verify_cert :: proc(c: ^Cert) -> bool {
	if c.nsigs == 0 || c.primary.algo != ALGO_ED25519 {
		return false
	}
	for i in 0 ..< c.nsigs {
		s := &c.sigs[i]
		ctx: hash.Context
		if !begin_hash(&ctx, s) {
			return false
		}
		switch {
		case s.type == 0x1F && c.sig_of[i] == -1:
			hash_key(&ctx, &c.primary)
		case s.type >= 0x10 && s.type <= 0x13 && c.sig_of[i] == -1:
			hash_key(&ctx, &c.primary)
			head: [5]u8
			head[0] = 0xB4
			n := len(c.user_id)
			head[1], head[2], head[3], head[4] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
			hash.update(&ctx, head[:])
			hash.update(&ctx, c.user_id)
		case s.type == 0x18 && c.sig_of[i] >= 0:
			hash_key(&ctx, &c.primary)
			hash_key(&ctx, &c.subkeys[c.sig_of[i]])
		case:
			return false
		}
		if !finish_verify(&ctx, s, &c.primary) {
			return false
		}
	}
	return true
}

// verify_data checks a document signature by `key` over `data`: a binary
// signature over the bytes, a text one over them with CRLF line ends.
verify_data :: proc(key: ^Key, s: ^Signature, data: []u8) -> bool {
	ctx: hash.Context
	if !begin_hash(&ctx, s) {
		return false
	}
	switch s.type {
	case 0x00:
		hash.update(&ctx, data)
	case 0x01:
		at := 0
		crlf := [2]u8{'\r', '\n'}
		for i in 0 ..< len(data) {
			if data[i] == '\n' {
				end := i
				if end > at && data[end - 1] == '\r' {
					end -= 1
				}
				hash.update(&ctx, data[at:end])
				hash.update(&ctx, crlf[:])
				at = i + 1
			}
		}
		hash.update(&ctx, data[at:])
	case:
		return false
	}
	return finish_verify(&ctx, s, key)
}

/*
verify_message checks an inline-signed message: a one-pass packet, the
literal data, and the signature over it, by `key`. It answers the literal
and whether the signature held.
*/
verify_message :: proc(data: []u8, key: ^Key) -> (l: Literal, ok: bool) {
	at := 0
	have_literal := false
	for {
		p, after, pok := next(data, at)
		if !pok {
			break
		}
		at = after
		switch p.tag {
		case LITERAL:
			l, have_literal = parse_literal(p)
		case SIGNATURE:
			s, sok := parse_signature(p)
			if !sok || !have_literal {
				return l, false
			}
			return l, verify_data(key, &s, l.data)
		case ONE_PASS, PADDING:
		}
	}
	return l, false
}

@(private = "file")
begin_hash :: proc(ctx: ^hash.Context, s: ^Signature) -> bool {
	switch s.hash {
	case HASH_SHA256:
		hash.init(ctx, .SHA256)
	case HASH_SHA512:
		hash.init(ctx, .SHA512)
	case:
		return false
	}
	if s.version == 6 {
		hash.update(ctx, s.salt)
	}
	return true
}

// hash_key feeds a key's public fields under the header a signature over
// a key uses: 0x99 and two octets for version 4, 0x9B and four for 6.
@(private = "file")
hash_key :: proc(ctx: ^hash.Context, k: ^Key) {
	head: [5]u8
	n := len(k.body)
	if k.version == 6 {
		head[0] = 0x9B
		head[1], head[2], head[3], head[4] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
		hash.update(ctx, head[:5])
	} else {
		head[0] = 0x99
		head[1], head[2] = u8(n >> 8), u8(n)
		hash.update(ctx, head[:3])
	}
	hash.update(ctx, k.body)
}

// finish_verify hashes the trailer, checks the digest's first two octets
// against the packet's, and verifies the Ed25519 signature over the digest.
@(private = "file")
finish_verify :: proc(ctx: ^hash.Context, s: ^Signature, key: ^Key) -> bool {
	hash.update(ctx, s.trailer)
	tail: [6]u8
	tail[0] = u8(s.version)
	tail[1] = 0xFF
	n := len(s.trailer)
	tail[2], tail[3], tail[4], tail[5] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
	hash.update(ctx, tail[:])
	digest: [64]u8
	dn := s.hash == HASH_SHA512 ? 64 : 32
	hash.final(ctx, digest[:dn])
	if digest[0] != s.left[0] || digest[1] != s.left[1] {
		return false
	}
	if s.algo != ALGO_ED25519 || key.algo != ALGO_ED25519 || len(s.material) != 64 || len(key.public) != 32 {
		return false
	}
	pub: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pub, key.public) {
		return false
	}
	return ed25519.verify(&pub, digest[:dn], s.material)
}

// -- Opening a message ------------------------------------------------------------------

MAX_SESSION :: 32

/*
open_message opens a message sealed to `sub`, an X25519 secret subkey, into
`out`, and answers the literal data in it. The session key comes off the
first PKESK packet that names the subkey, or names nobody. False when
nothing opens, or a tag does not hold.
*/
open_message :: proc(data: []u8, sub: ^Key, out: []u8) -> (l: Literal, ok: bool) {
	session: [MAX_SESSION]u8
	slen := 0
	at := 0
	for {
		p, after, pok := next(data, at)
		if !pok {
			break
		}
		at = after
		switch p.tag {
		case PKESK:
			if slen > 0 {
				continue
			}
			e, eok := parse_pkesk(p)
			if !eok {
				continue
			}
			if len(e.fingerprint) > 0 && (len(e.fingerprint) != sub.fpr_len || string(e.fingerprint) != string(sub.fingerprint[:sub.fpr_len])) {
				continue
			}
			slen = open_session(&e, sub, session[:])
		case SEIPD:
			if slen == 0 {
				return l, false
			}
			s, sok := parse_seipd(p)
			if !sok {
				return l, false
			}
			n := open_seipd(&s, session[:slen], out)
			if n < 0 {
				return l, false
			}
			return first_literal(out[:n])
		}
	}
	return l, false
}

// open_session unwraps the session key an X25519 PKESK carries, with the
// subkey's secret. Answers its length, or zero.
@(private = "file")
open_session :: proc(e: ^Pkesk, sub: ^Key, into: []u8) -> int {
	if sub.algo != ALGO_X25519 || len(sub.secret) != 32 || len(sub.public) != 32 || len(e.wrapped) < 24 || len(e.wrapped) - 8 > len(into) {
		return 0
	}
	shared: [32]u8
	x25519.scalarmult(shared[:], sub.secret, e.ephemeral)
	ikm: [96]u8
	copy(ikm[:32], e.ephemeral)
	copy(ikm[32:64], sub.public)
	copy(ikm[64:], shared[:])
	kek: [16]u8
	hkdf.extract_and_expand(.SHA256, nil, ikm[:], transmute([]u8)string("OpenPGP X25519"), kek[:])
	if !unwrap(kek[:], e.wrapped, into) {
		return 0
	}
	return len(e.wrapped) - 8
}

// open_seipd opens a version 2 packet's chunks into `out` and answers the
// plaintext's length, or -1 when a tag does not hold or the mode is not OCB.
@(private = "file")
open_seipd :: proc(s: ^Seipd, session: []u8, out: []u8) -> int {
	if s.aead != AEAD_OCB || s.chunk > 16 {
		return -1
	}
	klen := 0
	switch s.cipher {
	case CIPHER_AES128:
		klen = 16
	case CIPHER_AES256:
		klen = 32
	case:
		return -1
	}
	if len(session) != klen {
		return -1
	}
	derived: [32 + NONCE - 8]u8
	hkdf.extract_and_expand(.SHA256, s.salt, session, s.info[:], derived[:klen + NONCE - 8])
	o: Ocb
	ocb_init(&o, derived[:klen])
	iv := derived[klen:klen + NONCE - 8]
	if len(s.data) < TAG {
		return -1
	}
	chunks := s.data[:len(s.data) - TAG]
	final := s.data[len(s.data) - TAG:]
	size := 1 << uint(s.chunk + 6)
	nonce: [NONCE]u8
	copy(nonce[:], iv)
	total := 0
	index := u64(0)
	at := 0
	for at < len(chunks) {
		n := min(size + TAG, len(chunks) - at)
		if n < TAG || total + n - TAG > len(out) {
			return -1
		}
		put_index(nonce[:], index)
		if !ocb_open(&o, nonce[:], s.info[:], chunks[at:at + n], out[total:]) {
			return -1
		}
		total += n - TAG
		at += n
		index += 1
	}
	// The final tag, over nothing, with the plaintext's length in the
	// associated data: a truncated message fails here.
	put_index(nonce[:], index)
	aad: [13]u8
	copy(aad[:5], s.info[:])
	t := u64(total)
	for k in 0 ..< 8 {
		aad[5 + k] = u8(t >> uint(8 * (7 - k)))
	}
	if !ocb_open(&o, nonce[:], aad[:], final, out[total:total]) {
		return -1
	}
	return total
}

@(private = "file")
put_index :: proc "contextless" (nonce: []u8, index: u64) #no_bounds_check {
	for k in 0 ..< 8 {
		nonce[NONCE - 8 + k] = u8(index >> uint(8 * (7 - k)))
	}
}

// first_literal answers the literal data packet in a stream of packets.
first_literal :: proc(data: []u8) -> (l: Literal, ok: bool) {
	at := 0
	for {
		p, after, pok := next(data, at)
		if !pok {
			return l, false
		}
		at = after
		if p.tag == LITERAL {
			return parse_literal(p)
		}
	}
}

// find_subkey answers the first subkey of `algo` in a certificate, or nil.
find_subkey :: proc(c: ^Cert, algo: int) -> ^Key {
	for i in 0 ..< c.nsub {
		if c.subkeys[i].algo == algo {
			return &c.subkeys[i]
		}
	}
	return nil
}
