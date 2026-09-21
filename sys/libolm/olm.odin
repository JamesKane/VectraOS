/*
Olm: the double ratchet between two devices, `docs/WEB.md` section 8,
over Curve25519, HMAC-SHA-256 and AES-256 in CBC mode. A session starts
from a triple Diffie-Hellman of identity and one-time keys into a root
key and a chain key under "OLM_ROOT". Each side sends on a chain of its
own; a new ratchet key from the other side makes a new root and chain
under "OLM_RATCHET". A chain advances by HMAC of one byte, and a
message key is HMAC of another, sealed with keys derived under
"OLM_KEYS". Until a message has come back, every message out is a
pre-key message carrying the keys the far side needs to begin.

Nothing here draws randomness: the keys and seeds come in as bytes, so
a test can fix them and a server can draw them from /dev/random.
*/
package libolm

import "core:crypto/hkdf"
import "core:crypto/x25519"

MAX_RECEIVERS :: 4
MAX_SKIPPED :: 40

Chain :: struct {
	key:   [32]u8,
	index: u32,
}

Sender :: struct {
	priv:  [32]u8, // This side's ratchet key
	pub:   [32]u8,
	chain: Chain,
}

Receiver :: struct {
	pub:   [32]u8, // The far side's ratchet key the chain hangs off
	chain: Chain,
	used:  bool,
}

Skipped :: struct {
	pub:   [32]u8,
	index: u32,
	key:   [32]u8, // The message key kept for a message that came late
	used:  bool,
}

Session :: struct {
	root:          [32]u8,
	sender:        Sender,
	has_sender:    bool,
	receivers:     [MAX_RECEIVERS]Receiver,
	next_receiver: int,
	skipped:       [MAX_SKIPPED]Skipped,
	next_skipped:  int,
	received:      bool, // A message came in, so messages out are the compact kind
	// What a pre-key message carries until then.
	identity_pub:  [32]u8,
	base_pub:      [32]u8,
	their_one_time: [32]u8,
}

/*
outbound begins a session to a device whose identity key and one-time
key this side has: this side's identity key, a fresh base key for the
triple Diffie-Hellman, and a fresh ratchet key.
*/
outbound :: proc(s: ^Session, identity_priv: []u8, their_identity_pub: []u8, their_one_time_pub: []u8, base_priv: []u8, ratchet_priv: []u8) -> bool {
	if len(identity_priv) != 32 || len(their_identity_pub) != 32 || len(their_one_time_pub) != 32 || len(base_priv) != 32 || len(ratchet_priv) != 32 {
		return false
	}
	s^ = Session{}
	secret: [96]u8
	x25519.scalarmult(secret[0:32], identity_priv, their_one_time_pub)
	x25519.scalarmult(secret[32:64], base_priv, their_identity_pub)
	x25519.scalarmult(secret[64:96], base_priv, their_one_time_pub)
	root_chain(s, secret[:], nil, "OLM_ROOT")
	copy(s.sender.priv[:], ratchet_priv)
	x25519.scalarmult_basepoint(s.sender.pub[:], ratchet_priv)
	s.has_sender = true
	x25519.scalarmult_basepoint(s.identity_pub[:], identity_priv)
	x25519.scalarmult_basepoint(s.base_pub[:], base_priv)
	copy(s.their_one_time[:], their_one_time_pub)
	return true
}

/*
inbound begins a session from a pre-key message that arrived: this side's
identity key and the one-time key the message names. The message's own
text is opened by `decrypt` after, with `prekey` true.
*/
inbound :: proc(s: ^Session, identity_priv: []u8, one_time_priv: []u8, prekey: []u8) -> bool {
	if len(identity_priv) != 32 || len(one_time_priv) != 32 {
		return false
	}
	their_one_time, base, identity, inner, ok := parse_prekey(prekey)
	if !ok {
		return false
	}
	_ = their_one_time
	s^ = Session{}
	secret: [96]u8
	x25519.scalarmult(secret[0:32], one_time_priv, identity)
	x25519.scalarmult(secret[32:64], identity_priv, base)
	x25519.scalarmult(secret[64:96], one_time_priv, base)
	root_chain(s, secret[:], nil, "OLM_ROOT")
	// The chain this root made is the far side's sending chain, hung off
	// the ratchet key its message carries.
	ratchet_pub, _, _, _, parsed := parse_message(inner)
	if !parsed {
		return false
	}
	r := &s.receivers[0]
	r.used = true
	copy(r.pub[:], ratchet_pub)
	r.chain = s.sender.chain
	s.has_sender = false
	s.next_receiver = 1
	s.received = true
	return true
}

// root_chain derives the root key and a chain key from a secret, under
// `info`, with the old root as the salt when there is one, and leaves the
// chain as the sender's, index zero.
@(private = "file")
root_chain :: proc(s: ^Session, secret: []u8, salt: []u8, info: string) {
	out: [64]u8
	zero: [32]u8
	hkdf.extract_and_expand(.SHA256, salt == nil ? zero[:] : salt, secret, transmute([]u8)info, out[:])
	copy(s.root[:], out[:32])
	copy(s.sender.chain.key[:], out[32:64])
	s.sender.chain.index = 0
}

/*
encrypt seals `plain` as the next message into `dst`. A fresh ratchet key
is taken from `ratchet_priv` when a new sending chain is needed, which is
after a message came in on a new chain. Until a message has come in at
all, the message is a pre-key message. `dst` needs the plain-text
rounded up a block, and about two hundred more.
*/
encrypt :: proc(s: ^Session, plain: []u8, dst: []u8, ratchet_priv: []u8) -> int {
	if !s.has_sender {
		if len(ratchet_priv) != 32 || s.next_receiver == 0 {
			return -1
		}
		copy(s.sender.priv[:], ratchet_priv)
		x25519.scalarmult_basepoint(s.sender.pub[:], ratchet_priv)
		last := &s.receivers[(s.next_receiver - 1) % MAX_RECEIVERS]
		secret: [32]u8
		x25519.scalarmult(secret[:], s.sender.priv[:], last.pub[:])
		old_root := s.root
		root_chain(s, secret[:], old_root[:], "OLM_RATCHET")
		s.has_sender = true
	}
	mkey: [32]u8
	hmac_byte(s.sender.chain.key[:], 1, mkey[:])
	hmac_byte(s.sender.chain.key[:], 2, s.sender.chain.key[:])
	j := s.sender.chain.index
	s.sender.chain.index += 1
	k: Keys
	derive_keys(mkey[:], "OLM_KEYS", &k)
	clen := len(plain) + 16 - len(plain) % 16
	inner: [4096]u8
	if 1 + 34 + 11 + 11 + clen + 8 > len(inner) {
		return -1
	}
	n := 0
	inner[n] = 3
	n += 1
	inner[n] = 0x0A
	inner[n + 1] = 32
	n += 2
	copy(inner[n:], s.sender.pub[:])
	n += 32
	inner[n] = 0x10
	n += 1
	n += put_varint(inner[n:], u64(j))
	inner[n] = 0x22
	n += 1
	n += put_varint(inner[n:], u64(clen))
	if cbc_encrypt(k.aes[:], k.iv[:], plain, inner[n:]) != clen {
		return -1
	}
	n += clen
	mac8(k.mac[:], inner[:n], inner[n:n + 8])
	n += 8
	if s.received {
		if len(dst) < n {
			return -1
		}
		copy(dst, inner[:n])
		return n
	}
	// A pre-key message: the keys the far side needs, then the message.
	m := 0
	if len(dst) < 1 + 34 * 3 + 1 + 10 + n {
		return -1
	}
	dst[m] = 3
	m += 1
	tags := [3]u8{0x0A, 0x12, 0x1A}
	for part, i in ([3][]u8{s.their_one_time[:], s.base_pub[:], s.identity_pub[:]}) {
		dst[m] = tags[i]
		dst[m + 1] = 32
		copy(dst[m + 2:], part)
		m += 34
	}
	dst[m] = 0x22
	m += 1
	m += put_varint(dst[m:], u64(n))
	copy(dst[m:], inner[:n])
	return m + n
}

/*
decrypt opens a message into `dst`: a pre-key message when `prekey`, else
the compact kind. A message on a new ratchet key makes a new receiving
chain and ends the sending one; a message from earlier in a chain opens
with a key kept when it was skipped.
*/
decrypt :: proc(s: ^Session, msg: []u8, dst: []u8, prekey: bool) -> (n: int, ok: bool) {
	inner := msg
	if prekey {
		_, _, _, inner, ok = parse_prekey(msg)
		if !ok {
			return 0, false
		}
	}
	ratchet_pub, j, cipher, mac, parsed := parse_message(inner)
	if !parsed {
		return 0, false
	}
	signed := inner[:len(inner) - 8]
	r := receiver_for(s, ratchet_pub)
	if r == nil {
		// A new chain from the far side: a new root off our ratchet key
		// and theirs, and our sending chain is done with.
		if !s.has_sender {
			return 0, false
		}
		secret: [32]u8
		x25519.scalarmult(secret[:], s.sender.priv[:], ratchet_pub)
		old_root := s.root
		root_chain(s, secret[:], old_root[:], "OLM_RATCHET")
		r = &s.receivers[s.next_receiver % MAX_RECEIVERS]
		s.next_receiver += 1
		r.used = true
		copy(r.pub[:], ratchet_pub)
		r.chain = s.sender.chain
		s.has_sender = false
	}
	mkey: [32]u8
	if j < r.chain.index {
		// From earlier in the chain: the key kept for it, once.
		found := false
		for &sk in s.skipped {
			if sk.used && sk.index == j && sk.pub == r.pub {
				mkey = sk.key
				sk.used = false
				found = true
				break
			}
		}
		if !found {
			return 0, false
		}
	} else {
		// Forward to the message's index, keeping the keys skipped.
		for r.chain.index < j {
			sk := &s.skipped[s.next_skipped % MAX_SKIPPED]
			s.next_skipped += 1
			sk.used = true
			sk.pub = r.pub
			sk.index = r.chain.index
			hmac_byte(r.chain.key[:], 1, sk.key[:])
			hmac_byte(r.chain.key[:], 2, r.chain.key[:])
			r.chain.index += 1
		}
		hmac_byte(r.chain.key[:], 1, mkey[:])
		hmac_byte(r.chain.key[:], 2, r.chain.key[:])
		r.chain.index += 1
	}
	k: Keys
	derive_keys(mkey[:], "OLM_KEYS", &k)
	if !mac8_ok(k.mac[:], signed, mac) {
		return 0, false
	}
	n, ok = cbc_decrypt(k.aes[:], k.iv[:], cipher, dst)
	if ok {
		s.received = true
	}
	return n, ok
}

@(private = "file")
receiver_for :: proc(s: ^Session, pub: []u8) -> ^Receiver {
	for &r in s.receivers {
		if r.used && string(r.pub[:]) == string(pub) {
			return &r
		}
	}
	return nil
}

// parse_message takes a compact message apart: the ratchet key, the
// chain index, the cipher-text and the MAC.
parse_message :: proc(msg: []u8) -> (ratchet_pub: []u8, index: u32, cipher: []u8, mac: []u8, ok: bool) {
	if len(msg) < 1 + 8 || msg[0] != 3 {
		return
	}
	body := msg[1:len(msg) - 8]
	mac = msg[len(msg) - 8:]
	has_index := false
	for at := 0; at < len(body); {
		tag, num, bytes, next, fok := next_field(body, at)
		if !fok {
			return
		}
		switch tag {
		case 0x0A:
			ratchet_pub = bytes
		case 0x10:
			index = u32(num)
			has_index = true
		case 0x22:
			cipher = bytes
		}
		at = next
	}
	ok = has_index && len(ratchet_pub) == 32 && cipher != nil
	return
}

// parse_prekey takes a pre-key message apart: the one-time key it was
// made for, the base key, the identity key, and the message inside.
parse_prekey :: proc(msg: []u8) -> (one_time, base, identity, inner: []u8, ok: bool) {
	if len(msg) < 2 || msg[0] != 3 {
		return
	}
	body := msg[1:]
	for at := 0; at < len(body); {
		tag, _, bytes, next, fok := next_field(body, at)
		if !fok {
			return
		}
		switch tag {
		case 0x0A:
			one_time = bytes
		case 0x12:
			base = bytes
		case 0x1A:
			identity = bytes
		case 0x22:
			inner = bytes
		}
		at = next
	}
	ok = len(one_time) == 32 && len(base) == 32 && len(identity) == 32 && inner != nil
	return
}

// basepoint answers the public key of a Curve25519 private key.
basepoint :: proc(dst: []u8, scalar: []u8) {
	x25519.scalarmult_basepoint(dst, scalar)
}
