/*
The TLS 1.3 client handshake, RFC 8446 section 4, the driving half.

A `Conn` carries a handshake from a ClientHello to shared keys. It keeps the one
thing the whole handshake is measured against -- the running transcript hash,
Hash of every handshake message in order -- and the ephemeral key, the secrets
the ladder yields, and the record keys of each direction. The caller moves bytes
on the wire; the `Conn` reads and writes handshake messages and installs keys.

This file is the key exchange and the handshake keys: the ClientHello a client
sends, and the ServerHello it reads, after which both ends hold the handshake
traffic keys and every later message is sealed. The sealed flight that follows
-- the certificate, its proof, and the Finished -- is opened by the next file,
which has these keys to open it with.

The transcript is a `hash.Context` updated with each message and read by
snapshotting a clone, so the running hash is never disturbed by the reads the
key schedule needs at each step (RFC 8446 section 4.4.1's "Transcript-Hash").
*/
package libtls

import "core:crypto/hash"
import "core:crypto/x25519"

// Where a client is in the handshake.
Client_State :: enum {
	Start,
	Wait_Server_Hello,
	Wait_Flight,
	Send_Finished,
	Connected,
	Failed,
}

Conn :: struct {
	state:      Client_State,
	transcript: hash.Context,

	// The client's ephemeral X25519 key, and the negotiated group and suite.
	priv:   [32]u8,
	pub:    [32]u8,
	group:  u16,
	cipher: u16,

	// The ladder's secrets, and the handshake traffic secrets branched from it.
	secrets:     Secrets,
	c_hs_secret: [HASH_LEN]u8,
	s_hs_secret: [HASH_LEN]u8,

	// The application traffic secrets, derived when the server's Finished lands.
	c_ap_secret: [HASH_LEN]u8,
	s_ap_secret: [HASH_LEN]u8,

	// The server leaf's public key, captured at Certificate so CertificateVerify
	// can check its signature. Held as raw bytes -- not an x509.Certificate whose
	// slices would point into the caller's message buffer -- so the value outlives
	// the buffer the Certificate message was read from.
	leaf_algo:      Leaf_Algo,
	leaf_ec:        [65]u8, // ECDSA point (0x04||X||Y) or Ed25519 key
	leaf_ec_len:    int,
	leaf_rsa_n:     [512]u8, // up to RSA-4096
	leaf_rsa_n_len: int,
	leaf_rsa_e:     [8]u8,
	leaf_rsa_e_len: int,

	// The leaf certificate's sha256, over its DER, whether or not it chained:
	// what a trust-on-first-use client remembers a host by. `chained` says the
	// leaf verified to a root; it is false only when `tofu` let it through.
	leaf_sha256: [32]u8,
	chained:     bool,
	tofu:        bool, // A leaf that chains to no root is accepted, unchained

	// Record keys: `write` seals what this end sends, `read` opens what it gets.
	write: Record_Keys,
	read:  Record_Keys,
}

// transcript_update folds one whole handshake message (type, length and body)
// into the running hash, in the order the messages appear.
transcript_update :: proc(c: ^Conn, msg: []u8) {
	hash.update(&c.transcript, msg)
}

// transcript_snapshot writes Transcript-Hash(messages so far) into `out` by
// finalizing a clone, so the running hash keeps growing after the read.
transcript_snapshot :: proc(c: ^Conn, out: []u8) {
	hash.final(&c.transcript, out, true)
}

/*
client_hello starts a handshake: it takes the ephemeral private key and the
ClientHello random (the caller draws both from `/dev/random`; a test fixes them
to a trace's), derives the public value, writes the ClientHello into `out`, and
folds it into a fresh transcript. Returns the message length, or -1 if `out` is
too small.
*/
client_hello :: proc(c: ^Conn, priv: [32]u8, random: [32]u8, server_name: string, out: []u8) -> int {
	hash.init(&c.transcript, HASH)
	c.priv = priv
	x25519.scalarmult_basepoint(c.pub[:], c.priv[:])

	rnd := random
	w := writer(out)
	write_client_hello(&w, Client_Hello{random = rnd[:], key_share = c.pub[:], server_name = server_name})
	if w.err {
		c.state = .Failed
		return -1
	}
	transcript_update(c, out[:w.pos])
	c.state = .Wait_Server_Hello
	return w.pos
}

/*
server_hello reads the ServerHello handshake message (type, length and all),
negotiates, does the X25519 exchange, and installs the handshake keys. After it,
`c.write` and `c.read` seal and open the handshake traffic. It fails a
HelloRetryRequest, a suite or group this client did not offer, and a malformed
message; this client offers exactly one of each, so a retry is a server that
wanted something else.
*/
server_hello :: proc(c: ^Conn, sh_msg: []u8) -> bool {
	if c.state != .Wait_Server_Hello {
		c.state = .Failed
		return false
	}
	r := reader(sh_msg)
	msg_type, body, ok := read_handshake(&r)
	if !ok || msg_type != HS_SERVER_HELLO {
		c.state = .Failed
		return false
	}
	sh, shok := parse_server_hello(body)
	if !shok || sh.is_retry || sh.cipher_suite != TLS_AES_128_GCM_SHA256 || sh.group != GROUP_X25519 || len(sh.key_share) != 32 {
		c.state = .Failed
		return false
	}
	c.cipher = sh.cipher_suite
	c.group = sh.group
	transcript_update(c, sh_msg)

	shared: [32]u8
	x25519.scalarmult(shared[:], c.priv[:], sh.key_share)
	install_handshake_keys(c, shared[:], true)

	c.state = .Wait_Flight
	return true
}

/*
install_handshake_keys runs the ladder from the (EC)DHE secret and branches the
handshake traffic secrets off it with the transcript so far -- Hash(ClientHello
|| ServerHello). `client_is_us` picks which secret seals and which opens: a
client writes under the client secret and reads the server's, a server the
reverse. It is exported so a test can stand on the other side of the exchange
and confirm both ends reach the same keys.
*/
install_handshake_keys :: proc(c: ^Conn, ecdhe: []u8, client_is_us: bool) {
	ladder(&c.secrets, ecdhe)

	th: [HASH_LEN]u8
	transcript_snapshot(c, th[:])
	derive_secret(c.secrets.handshake[:], "c hs traffic", th[:], c.c_hs_secret[:])
	derive_secret(c.secrets.handshake[:], "s hs traffic", th[:], c.s_hs_secret[:])

	if client_is_us {
		record_keys(&c.write, c.c_hs_secret[:])
		record_keys(&c.read, c.s_hs_secret[:])
	} else {
		record_keys(&c.write, c.s_hs_secret[:])
		record_keys(&c.read, c.c_hs_secret[:])
	}
}
