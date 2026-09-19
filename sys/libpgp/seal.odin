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
	if !begin_hash(&ctx, s) || !hash_document(&ctx, s.type, data) {
		return false
	}
	return finish_verify(&ctx, s, key)
}

// hash_document feeds a document as its signature type has it: the bytes
// for a binary signature, the lines with CRLF ends for a text one.
@(private = "file")
hash_document :: proc(ctx: ^hash.Context, type: int, data: []u8) -> bool {
	switch type {
	case 0x00:
		hash.update(ctx, data)
	case 0x01:
		at := 0
		crlf := [2]u8{'\r', '\n'}
		for i in 0 ..< len(data) {
			if data[i] == '\n' {
				end := i
				if end > at && data[end - 1] == '\r' {
					end -= 1
				}
				hash.update(ctx, data[at:end])
				hash.update(ctx, crlf[:])
				at = i + 1
			}
		}
		hash.update(ctx, data[at:])
	case:
		return false
	}
	return true
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
	digest: [64]u8
	dn := finish_digest(ctx, s, digest[:])
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

// finish_digest hashes the trailer and its tail and answers the digest's
// length in `digest`.
@(private = "file")
finish_digest :: proc(ctx: ^hash.Context, s: ^Signature, digest: []u8) -> int {
	hash.update(ctx, s.trailer)
	tail: [6]u8
	tail[0] = u8(s.version)
	tail[1] = 0xFF
	n := len(s.trailer)
	tail[2], tail[3], tail[4], tail[5] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
	hash.update(ctx, tail[:])
	dn := s.hash == HASH_SHA512 ? 64 : 32
	hash.final(ctx, digest[:dn])
	return dn
}

// -- Signing ---------------------------------------------------------------------------

// What a signature is made with, beside the key: its time, and the salt a
// version 6 signature hashes first, thirty-two random octets.
Sign_Params :: struct {
	created: u32,
	salt:    [32]u8,
}

/*
What a signature is over. A document of a type, 0 binary or 1 text; a key
alone, for a direct-key signature; a key and its subkey, for a binding.
*/
Sign_Input :: struct {
	type:    int,
	data:    []u8, // A document's bytes
	primary: ^Key, // For a signature over a key
	subkey:  ^Key, // And its subkey, for a binding
}

/*
A signature part way: its packet body up to the salt, and the digest to
sign. `sign_begin` makes one, whoever holds the secret signs the digest,
and `sign_finish` writes the packet. `factotum` is the one that holds the
secret in this system, and a program asks it for the sixty-four octets.
*/
Sign_Job :: struct {
	body:   [320]u8,
	n:      int,
	digest: [64]u8,
	dn:     int,
	salt:   [32]u8,
}

/*
sign_begin lays out a version 6 Ed25519 signature packet over `input` by
the key with `fingerprint`, up to the salt, and hashes what it signs. The
hashed subpackets are the time, then `extra` as given, then the issuer's
fingerprint, the way the RFC's samples are made.
*/
sign_begin :: proc(job: ^Sign_Job, signer: ^Key, input: Sign_Input, extra: []u8, p: Sign_Params) -> bool {
	p := p
	if signer.algo != ALGO_ED25519 || signer.version != 6 || 5 + 1 + len(extra) + 2 + signer.fpr_len > 200 {
		return false
	}
	body := job.body[:]
	body[0], body[1], body[2], body[3] = 6, u8(input.type), ALGO_ED25519, HASH_SHA512
	n := 4
	hashed := 6 + len(extra) + 2 + 1 + signer.fpr_len
	body[n], body[n + 1], body[n + 2], body[n + 3] = 0, 0, 0, u8(hashed)
	n += 4
	body[n], body[n + 1] = 5, 0x82 // Critical: signature creation time
	body[n + 2], body[n + 3], body[n + 4], body[n + 5] = u8(p.created >> 24), u8(p.created >> 16), u8(p.created >> 8), u8(p.created)
	n += 6
	n += copy(body[n:], extra)
	body[n], body[n + 1], body[n + 2] = u8(2 + signer.fpr_len), SUB_ISSUER_FPR, 6
	n += 3
	n += copy(body[n:], signer.fingerprint[:signer.fpr_len])
	job.salt = p.salt
	s := Signature{version = 6, type = input.type, algo = ALGO_ED25519, hash = HASH_SHA512, salt = job.salt[:], trailer = body[:n]}
	ctx: hash.Context
	if !begin_hash(&ctx, &s) {
		return false
	}
	switch {
	case input.type == 0x1F && input.primary != nil:
		hash_key(&ctx, input.primary)
	case input.type == 0x18 && input.primary != nil && input.subkey != nil:
		hash_key(&ctx, input.primary)
		hash_key(&ctx, input.subkey)
	case input.type <= 1:
		if !hash_document(&ctx, input.type, input.data) {
			return false
		}
	case:
		return false
	}
	job.dn = finish_digest(&ctx, &s, job.digest[:])
	// The unhashed area is empty, then the digest's first two octets and
	// the salt. The signature over the digest comes with `sign_finish`.
	body[n], body[n + 1], body[n + 2], body[n + 3] = 0, 0, 0, 0
	n += 4
	body[n], body[n + 1] = job.digest[0], job.digest[1]
	n += 2
	body[n] = 32
	n += 1
	n += copy(body[n:], job.salt[:])
	job.n = n
	return true
}

// sign_finish writes the packet with `sig`, the sixty-four octets over the
// job's digest, into `out`, and answers the length or -1.
sign_finish :: proc(job: ^Sign_Job, sig: []u8, out: []u8) -> int {
	if len(sig) != 64 || job.n == 0 {
		return -1
	}
	copy(job.body[job.n:], sig)
	return put_packet(out, 0, SIGNATURE, job.body[:job.n + 64])
}

// sign_digest signs a job's digest with a secret Ed25519 key held here.
sign_digest :: proc(job: ^Sign_Job, signer: ^Key, sig: []u8) -> bool {
	if len(signer.secret) != 32 || len(sig) != 64 {
		return false
	}
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, signer.secret) {
		return false
	}
	ed25519.sign(&priv, job.digest[:job.dn], sig)
	return true
}

/*
sign_data writes a version 6 Ed25519 signature packet of `type` (0 binary,
1 text) over `data` by `signer`, whose secret must be there, into `out`,
and answers the packet's length or -1.
*/
sign_data :: proc(signer: ^Key, type: int, data: []u8, p: Sign_Params, out: []u8) -> int {
	job: Sign_Job
	if !sign_begin(&job, signer, Sign_Input{type = type, data = data}, nil, p) {
		return -1
	}
	sig: [64]u8
	if !sign_digest(&job, signer, sig[:]) {
		return -1
	}
	return sign_finish(&job, sig[:], out)
}

/*
sign_message writes an inline-signed message: a one-pass signature
packet, the literal data in `format` ('b' or 'u'), and the signature over
it, text-canonical for 'u'. Answers the length written, or -1.
*/
sign_message :: proc(signer: ^Key, data: []u8, format: u8, p: Sign_Params, out: []u8) -> int {
	p := p
	if signer.version != 6 {
		return -1
	}
	type := format == 'b' ? 0 : 1
	one: [128]u8
	n := 0
	one[0], one[1], one[2], one[3], one[4] = 6, u8(type), HASH_SHA512, ALGO_ED25519, 32
	n = 5
	n += copy(one[n:], p.salt[:])
	// The fingerprint bare: a version 6 one-pass packet has no count on it.
	n += copy(one[n:], signer.fingerprint[:signer.fpr_len])
	one[n] = 1 // The last one-pass packet before the data
	n += 1
	at := put_packet(out, 0, ONE_PASS, one[:n])
	if at < 0 {
		return -1
	}
	at = put_literal(out, at, format, data)
	if at < 0 {
		return -1
	}
	sn := sign_data(signer, type, data, p, out[at:])
	if sn < 0 {
		return -1
	}
	return at + sn
}

// -- Sealing ------------------------------------------------------------------------------

// What a message is sealed with, beside the recipient's key: an ephemeral
// X25519 secret, the session key (sixteen octets for AES-128, thirty-two
// for AES-256), the salt, and the padding packet's octets. Every one is
// random in use, and the RFC's in the test that reproduces its sample.
Seal_Params :: struct {
	ephemeral: [32]u8,
	session:   []u8,
	salt:      [32]u8,
	padding:   []u8,
	chunk:     u8, // The chunk size octet, 6 for 4 KiB chunks
}

/*
seal_message writes a message sealed to `recipient`, an X25519 key: a
version 6 session key packet naming it, and version 2 sealed data in
AES-OCB holding the literal data, binary, and the padding. Answers the
length written, or -1.
*/
seal_message :: proc(recipient: ^Key, data: []u8, p: Seal_Params, out: []u8) -> int {
	p := p
	if recipient.algo != ALGO_X25519 || len(recipient.public) != 32 || recipient.version != 6 {
		return -1
	}
	klen := len(p.session)
	cipher := 0
	switch klen {
	case 16:
		cipher = CIPHER_AES128
	case 32:
		cipher = CIPHER_AES256
	case:
		return -1
	}
	// The session key packet.
	eph_pub: [32]u8
	x25519.scalarmult_basepoint(eph_pub[:], p.ephemeral[:])
	shared: [32]u8
	x25519.scalarmult(shared[:], p.ephemeral[:], recipient.public)
	ikm: [96]u8
	copy(ikm[:32], eph_pub[:])
	copy(ikm[32:64], recipient.public)
	copy(ikm[64:], shared[:])
	kek: [16]u8
	hkdf.extract_and_expand(.SHA256, nil, ikm[:], transmute([]u8)string("OpenPGP X25519"), kek[:])
	pk: [128]u8
	n := 0
	pk[0], pk[1], pk[2] = 6, u8(1 + recipient.fpr_len), 6
	n = 3
	n += copy(pk[n:], recipient.fingerprint[:recipient.fpr_len])
	pk[n] = ALGO_X25519
	n += 1
	n += copy(pk[n:], eph_pub[:])
	pk[n] = u8(klen + 8)
	n += 1
	if !wrap(kek[:], p.session, pk[n:n + klen + 8]) {
		return -1
	}
	n += klen + 8
	at := put_packet(out, 0, PKESK, pk[:n])
	if at < 0 {
		return -1
	}
	// The plaintext: the literal and the padding.
	plain := make([]u8, len(data) + len(p.padding) + 32)
	defer delete(plain)
	pn := put_literal(plain, 0, 'b', data)
	pn = put_packet(plain, pn, PADDING, p.padding)
	if pn < 0 {
		return -1
	}
	// The sealed data packet, its chunks and the final tag.
	body := make([]u8, 4 + 32 + pn + (pn / (1 << uint(p.chunk + 6)) + 2) * TAG)
	defer delete(body)
	body[0], body[1], body[2], body[3] = 2, u8(cipher), AEAD_OCB, p.chunk
	copy(body[4:36], p.salt[:])
	info := [5]u8{0xC0 | SEIPD, 2, u8(cipher), AEAD_OCB, p.chunk}
	derived: [32 + NONCE - 8]u8
	hkdf.extract_and_expand(.SHA256, p.salt[:], p.session, info[:], derived[:klen + NONCE - 8])
	o: Ocb
	ocb_init(&o, derived[:klen])
	nonce: [NONCE]u8
	copy(nonce[:], derived[klen:klen + NONCE - 8])
	size := 1 << uint(p.chunk + 6)
	bn := 36
	index := u64(0)
	pat := 0
	for pat < pn {
		m := min(size, pn - pat)
		put_index(nonce[:], index)
		if !ocb_seal(&o, nonce[:], info[:], plain[pat:pat + m], body[bn:]) {
			return -1
		}
		bn += m + TAG
		pat += m
		index += 1
	}
	put_index(nonce[:], index)
	aad: [13]u8
	copy(aad[:5], info[:])
	t := u64(pn)
	for k in 0 ..< 8 {
		aad[5 + k] = u8(t >> uint(8 * (7 - k)))
	}
	if !ocb_seal(&o, nonce[:], aad[:], nil, body[bn:]) {
		return -1
	}
	bn += TAG
	at = put_packet(out, at, SEIPD, body[:bn])
	return at
}

// -- Writing packets ------------------------------------------------------------------------

// put_packet writes a packet in the OpenPGP format at `at` and answers
// where the next goes, or -1 when it does not fit.
put_packet :: proc(out: []u8, at: int, tag: int, body: []u8) -> int #no_bounds_check {
	if at < 0 || at + 6 + len(body) > len(out) {
		return -1
	}
	out[at] = 0xC0 | u8(tag)
	n := put_length(out, at + 1, len(body))
	copy(out[n:], body)
	return n + len(body)
}

// put_length writes an OpenPGP format length at `at` and answers where
// the body goes.
put_length :: proc(out: []u8, at: int, n: int) -> int #no_bounds_check {
	switch {
	case n < 192:
		out[at] = u8(n)
		return at + 1
	case n < 8384:
		v := n - 192
		out[at] = u8(v >> 8 + 192)
		out[at + 1] = u8(v & 0xFF)
		return at + 2
	}
	out[at] = 255
	out[at + 1], out[at + 2], out[at + 3], out[at + 4] = u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)
	return at + 5
}

// put_literal writes a literal data packet with no name and a zero date.
put_literal :: proc(out: []u8, at: int, format: u8, data: []u8) -> int #no_bounds_check {
	if at < 0 || at + 12 + len(data) > len(out) {
		return -1
	}
	head := [6]u8{format, 0, 0, 0, 0, 0}
	out[at] = 0xC0 | LITERAL
	n := put_length(out, at + 1, len(head) + len(data))
	copy(out[n:], head[:])
	copy(out[n + len(head):], data)
	return n + len(head) + len(data)
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
// subkey's secret. Answers its length, or zero. `factotum` runs this for
// a program that holds no secret, and hands the session key back.
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
// A program with the session key from `factotum` opens the data itself.
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
