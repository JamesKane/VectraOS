/*
libauth/noise -- the Noise IK handshake, `Noise_IK_25519_ChaChaPoly_BLAKE2s`.

`docs/FLEET.md` step 2 proves a user by a Noise handshake on the raw stream
before 9P begins. The pattern is `IK`: the initiator already knows the
responder's static public key (from `ndb`), sends its own static key
encrypted in the first message, and the second message completes the exchange.
Both ends come away holding two transport keys and each other's static key --
a name for the far side.

This is the pure state machine, over `sys/libcrypto`'s AEAD and X25519 and
BLAKE2s. It touches no file and no socket: `write_message` fills a buffer,
`read_message` consumes one, and `split` hands back the two transport ciphers.
The library that drives it over a stream, and `factotum` that holds the keys,
are built on this. It is checked by a loopback handshake in `tests/crypto`.

The Noise spec's own terms are used: `ck` the chaining key, `h` the handshake
hash, a `Cipher` the key-and-counter, and the IK message tokens `e, es, s, ss`
then `e, ee, se`.
*/
package libauth

import "core:crypto/blake2s"
import "core:crypto/x25519"
import "vsys:libcrypto"

KEY_SIZE :: 32
HASH_SIZE :: blake2s.DIGEST_SIZE // 32
DH_SIZE :: 32
TAG_SIZE :: libcrypto.TAG_SIZE // 16

// The protocol name, hashed into `h` to start. Exactly the suite this speaks.
PROTOCOL_NAME :: "Noise_IK_25519_ChaChaPoly_BLAKE2s"

// -- BLAKE2s HMAC and Noise's HKDF --------------------------------------------

BLAKE2S_BLOCK :: 64

/*
hmac_blake2s is the standard HMAC over BLAKE2s: the key padded to a block,
xored with the two pads, around two hashes. Noise's HKDF is built on it, and
`core:crypto/hmac` cannot be reached freestanding, so it is here. A key longer
than a block is hashed first, which no caller here does but the construction
requires.
*/
hmac_blake2s :: proc(out: []u8, key, data: []u8) #no_bounds_check {
	block: [BLAKE2S_BLOCK]u8
	if len(key) > BLAKE2S_BLOCK {
		ctx: blake2s.Context
		blake2s.init(&ctx)
		blake2s.update(&ctx, key)
		blake2s.final(&ctx, block[:HASH_SIZE])
	} else {
		copy(block[:], key)
	}
	ipad: [BLAKE2S_BLOCK]u8
	opad: [BLAKE2S_BLOCK]u8
	for i in 0 ..< BLAKE2S_BLOCK {
		ipad[i] = block[i] ~ 0x36
		opad[i] = block[i] ~ 0x5c
	}
	inner: [HASH_SIZE]u8
	ci: blake2s.Context
	blake2s.init(&ci)
	blake2s.update(&ci, ipad[:])
	blake2s.update(&ci, data)
	blake2s.final(&ci, inner[:])
	co: blake2s.Context
	blake2s.init(&co)
	blake2s.update(&co, opad[:])
	blake2s.update(&co, inner[:])
	blake2s.final(&co, out[:HASH_SIZE])
}

/*
hkdf2 is Noise's HKDF with two outputs: `o1 = HMAC(HMAC(ck, ikm), 1)` and
`o2 = HMAC(temp, o1 || 2)`. `hkdf3` is the same with a third, which the
IK pattern does not use but the spec defines. Only two are needed here.
*/
hkdf2 :: proc(o1, o2: []u8, ck, ikm: []u8) #no_bounds_check {
	temp: [HASH_SIZE]u8
	hmac_blake2s(temp[:], ck, ikm)
	one := [1]u8{0x01}
	hmac_blake2s(o1, temp[:], one[:])
	buf: [HASH_SIZE + 1]u8
	copy(buf[:HASH_SIZE], o1[:HASH_SIZE])
	buf[HASH_SIZE] = 0x02
	hmac_blake2s(o2, temp[:], buf[:])
}

// -- The symmetric state ------------------------------------------------------

Cipher :: struct {
	k:       [KEY_SIZE]u8,
	n:       u64,
	has_key: bool,
}

State :: struct {
	ck:     [HASH_SIZE]u8, // chaining key
	h:      [HASH_SIZE]u8, // handshake hash
	cipher: Cipher,
}

// mix_hash folds `data` into the running handshake hash.
mix_hash :: proc(s: ^State, data: []u8) #no_bounds_check {
	ctx: blake2s.Context
	blake2s.init(&ctx)
	blake2s.update(&ctx, s.h[:])
	blake2s.update(&ctx, data)
	blake2s.final(&ctx, s.h[:])
}

// mix_key takes a DH result into the chaining key and a fresh cipher key.
mix_key :: proc(s: ^State, ikm: []u8) #no_bounds_check {
	o1: [HASH_SIZE]u8
	o2: [HASH_SIZE]u8
	hkdf2(o1[:], o2[:], s.ck[:], ikm)
	copy(s.ck[:], o1[:])
	copy(s.cipher.k[:], o2[:])
	s.cipher.n = 0
	s.cipher.has_key = true
}

// noise_nonce lays a Noise counter into a 12-byte AEAD nonce: four zero bytes
// then the counter, little-endian.
noise_nonce :: proc(n: u64) -> [12]u8 {
	out: [12]u8
	x := n
	for i in 0 ..< 8 {
		out[4 + i] = u8(x)
		x >>= 8
	}
	return out
}

/*
encrypt_and_hash seals `plaintext` into `dst` with the handshake hash as
associated data, then folds the ciphertext into the hash. `dst` is the
plaintext length plus a tag. Before any key is mixed the plaintext is sent in
the clear and only hashed, which the pattern's first tokens require.
*/
encrypt_and_hash :: proc(s: ^State, dst, plaintext: []u8) -> int #no_bounds_check {
	if !s.cipher.has_key {
		copy(dst[:len(plaintext)], plaintext)
		mix_hash(s, dst[:len(plaintext)])
		return len(plaintext)
	}
	nonce := noise_nonce(s.cipher.n)
	tag := dst[len(plaintext):len(plaintext) + TAG_SIZE]
	libcrypto.seal(dst[:len(plaintext)], tag, s.cipher.k[:], nonce[:], s.h[:], plaintext)
	s.cipher.n += 1
	mix_hash(s, dst[:len(plaintext) + TAG_SIZE])
	return len(plaintext) + TAG_SIZE
}

/*
decrypt_and_hash opens `ciphertext` into `dst` with the handshake hash as
associated data, folds the ciphertext into the hash, and answers whether the
tag held. `dst` is the ciphertext length less a tag.
*/
decrypt_and_hash :: proc(s: ^State, dst, ciphertext: []u8) -> (int, bool) #no_bounds_check {
	if !s.cipher.has_key {
		copy(dst[:len(ciphertext)], ciphertext)
		mix_hash(s, ciphertext)
		return len(ciphertext), true
	}
	n := len(ciphertext) - TAG_SIZE
	if n < 0 {
		return 0, false
	}
	nonce := noise_nonce(s.cipher.n)
	ok := libcrypto.open(dst[:n], s.cipher.k[:], nonce[:], s.h[:], ciphertext[:n], ciphertext[n:])
	if !ok {
		return 0, false
	}
	s.cipher.n += 1
	mix_hash(s, ciphertext)
	return n, true
}

// -- The handshake ------------------------------------------------------------

Handshake :: struct {
	s:         State,
	initiator: bool,
	// Local static and ephemeral private keys, and their public halves.
	spriv:     [DH_SIZE]u8,
	spub:      [DH_SIZE]u8,
	epriv:     [DH_SIZE]u8,
	epub:      [DH_SIZE]u8,
	// The far side's static and ephemeral public keys, filled as they arrive.
	rs:        [DH_SIZE]u8,
	re:        [DH_SIZE]u8,
	have_rs:   bool,
}

@(private)
dh :: proc(out, priv, pub: []u8) {
	x25519.scalarmult(out, priv, pub)
}

// public_of derives the X25519 public key from a private one, the basepoint
// scalar multiply. A caller that has a private key and needs to name its
// public half uses it.
public_of :: proc(pub, priv: []u8) {
	x25519.scalarmult_basepoint(pub, priv)
}

/*
init_initiator starts the IK handshake for the side that dials. It needs its
own static private key and the responder's static public key, known from the
database. `epriv` is a fresh ephemeral private key, the one secret this side
must generate per handshake.
*/
init_initiator :: proc(hs: ^Handshake, spriv, rs, epriv: []u8) #no_bounds_check {
	hs.initiator = true
	copy(hs.spriv[:], spriv)
	public_of(hs.spub[:], hs.spriv[:])
	copy(hs.epriv[:], epriv)
	public_of(hs.epub[:], hs.epriv[:])
	copy(hs.rs[:], rs)
	hs.have_rs = true
	init_symmetric(&hs.s)
	// The pre-message: the responder's static key is known, and hashed in.
	mix_hash(&hs.s, hs.rs[:])
}

/*
init_responder starts the IK handshake for the side that listens. It needs its
own static private key; the initiator's static key arrives encrypted in the
first message. `epriv` is this side's fresh ephemeral private key.
*/
init_responder :: proc(hs: ^Handshake, spriv, epriv: []u8) #no_bounds_check {
	hs.initiator = false
	copy(hs.spriv[:], spriv)
	public_of(hs.spub[:], hs.spriv[:])
	copy(hs.epriv[:], epriv)
	public_of(hs.epub[:], hs.epriv[:])
	init_symmetric(&hs.s)
	// The pre-message: this side's own static key is what the initiator knew.
	mix_hash(&hs.s, hs.spub[:])
}

@(private)
init_symmetric :: proc(s: ^State) #no_bounds_check {
	// The protocol name is exactly one hash long here, so it is the initial
	// chaining key and handshake hash both.
	name := transmute([]u8)string(PROTOCOL_NAME)
	ctx: blake2s.Context
	blake2s.init(&ctx)
	blake2s.update(&ctx, name)
	blake2s.final(&ctx, s.h[:])
	copy(s.ck[:], s.h[:])
	s.cipher.has_key = false
	s.cipher.n = 0
}

/*
write_msg1 writes the initiator's first message into `dst`: `e, es, s, ss` and
the payload. The layout is the ephemeral public key, the static public key
encrypted, and the payload encrypted. Answers the length written.
*/
write_msg1 :: proc(hs: ^Handshake, dst, payload: []u8) -> int #no_bounds_check {
	at := 0
	// e
	copy(dst[at:at + DH_SIZE], hs.epub[:])
	mix_hash(&hs.s, hs.epub[:])
	at += DH_SIZE
	// es
	tmp: [DH_SIZE]u8
	dh(tmp[:], hs.epriv[:], hs.rs[:])
	mix_key(&hs.s, tmp[:])
	// s (encrypted)
	at += encrypt_and_hash(&hs.s, dst[at:], hs.spub[:])
	// ss
	dh(tmp[:], hs.spriv[:], hs.rs[:])
	mix_key(&hs.s, tmp[:])
	// payload (encrypted)
	at += encrypt_and_hash(&hs.s, dst[at:], payload)
	return at
}

/*
read_msg1 consumes the initiator's first message on the responder, filling the
initiator's ephemeral and static public keys and the payload into `payload`.
Answers the payload length and whether every tag held.
*/
read_msg1 :: proc(hs: ^Handshake, msg, payload: []u8) -> (int, bool) #no_bounds_check {
	at := 0
	// e
	copy(hs.re[:], msg[at:at + DH_SIZE])
	mix_hash(&hs.s, hs.re[:])
	at += DH_SIZE
	// es: this side's static with the initiator's ephemeral. The token names
	// the ephemeral of one end and the static of the other; the responder
	// owns the static half here.
	tmp: [DH_SIZE]u8
	dh(tmp[:], hs.spriv[:], hs.re[:])
	mix_key(&hs.s, tmp[:])
	// s (encrypted static key: DH_SIZE + tag)
	sbuf: [DH_SIZE]u8
	if _, ok := decrypt_and_hash(&hs.s, sbuf[:], msg[at:at + DH_SIZE + TAG_SIZE]); !ok {
		return 0, false
	}
	copy(hs.rs[:], sbuf[:])
	hs.have_rs = true
	at += DH_SIZE + TAG_SIZE
	// ss
	dh(tmp[:], hs.spriv[:], hs.rs[:])
	mix_key(&hs.s, tmp[:])
	// payload
	n, ok := decrypt_and_hash(&hs.s, payload, msg[at:])
	return n, ok
}

/*
write_msg2 writes the responder's second message into `dst`: `e, ee, se` and
the payload. After it, both sides may `split`.
*/
write_msg2 :: proc(hs: ^Handshake, dst, payload: []u8) -> int #no_bounds_check {
	at := 0
	// e
	copy(dst[at:at + DH_SIZE], hs.epub[:])
	mix_hash(&hs.s, hs.epub[:])
	at += DH_SIZE
	tmp: [DH_SIZE]u8
	// ee
	dh(tmp[:], hs.epriv[:], hs.re[:])
	mix_key(&hs.s, tmp[:])
	// se: responder's ephemeral with initiator's static
	dh(tmp[:], hs.epriv[:], hs.rs[:])
	mix_key(&hs.s, tmp[:])
	at += encrypt_and_hash(&hs.s, dst[at:], payload)
	return at
}

/*
read_msg2 consumes the responder's second message on the initiator. After it,
both sides may `split`.
*/
read_msg2 :: proc(hs: ^Handshake, msg, payload: []u8) -> (int, bool) #no_bounds_check {
	at := 0
	copy(hs.re[:], msg[at:at + DH_SIZE])
	mix_hash(&hs.s, hs.re[:])
	at += DH_SIZE
	tmp: [DH_SIZE]u8
	// ee
	dh(tmp[:], hs.epriv[:], hs.re[:])
	mix_key(&hs.s, tmp[:])
	// se: initiator's static with responder's ephemeral
	dh(tmp[:], hs.spriv[:], hs.re[:])
	mix_key(&hs.s, tmp[:])
	return decrypt_and_hash(&hs.s, payload, msg[at:])
}

/*
split ends the handshake and hands back the two transport ciphers. The first
is the initiator's send / responder's receive, the second the reverse, so each
side keeps the right one for each direction. `docs/FLEET.md` seals every stream
with these.
*/
split :: proc(hs: ^Handshake) -> (send, recv: Cipher) #no_bounds_check {
	o1: [HASH_SIZE]u8
	o2: [HASH_SIZE]u8
	empty: [0]u8
	hkdf2(o1[:], o2[:], hs.s.ck[:], empty[:])
	c1: Cipher
	c2: Cipher
	copy(c1.k[:], o1[:])
	c1.has_key = true
	copy(c2.k[:], o2[:])
	c2.has_key = true
	if hs.initiator {
		return c1, c2
	}
	return c2, c1
}

/*
transport_seal and transport_open are the sealed stream after the handshake:
each frame under the direction's key, its counter the frame number. `dst` is
the plaintext length plus a tag on seal, and less a tag on open.
*/
transport_seal :: proc(c: ^Cipher, dst, plaintext: []u8) #no_bounds_check {
	nonce := noise_nonce(c.n)
	tag := dst[len(plaintext):len(plaintext) + TAG_SIZE]
	libcrypto.seal(dst[:len(plaintext)], tag, c.k[:], nonce[:], nil, plaintext)
	c.n += 1
}

transport_open :: proc(c: ^Cipher, dst, frame: []u8) -> bool #no_bounds_check {
	n := len(frame) - TAG_SIZE
	if n < 0 {
		return false
	}
	nonce := noise_nonce(c.n)
	if !libcrypto.open(dst[:n], c.k[:], nonce[:], nil, frame[:n], frame[n:]) {
		return false
	}
	c.n += 1
	return true
}
