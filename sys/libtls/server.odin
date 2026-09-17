/*
The TLS 1.3 server side of the handshake, RFC 8446 section 4. Enough of one
to answer a client and prove it.

The client engine in `handshake.odin` and `flight.odin` is what `tlsclient` and
`webfs` run. This is the other end of the same exchange, message by message.
It reads a ClientHello. It writes a ServerHello and derives the same keys. It
writes the sealed flight: EncryptedExtensions, the Certificate, a
CertificateVerify signed live over the transcript, and its Finished. Then it
checks the client's Finished and switches to the application keys.

`tests/tlssrv` stands one on `/net/tcp`, so `tlsclient` is proven over a real
connection. `tests/crypto` stands one on an in-memory pipe and fragments its
flight on purpose.

Byte-in, byte-out, like the client. Each proc takes or writes one whole
handshake message, and the caller frames records and moves them. What is
offered is what the client offers: one suite, X25519, an ECDSA P-256
certificate. A server that must answer the world (`docs/WEB.md` step 6's
`httpd`) grows from here rather than starting over. This holds no lock. The
CertificateVerify signature allocates from `context.allocator` and is freed
before the proc returns.
*/
package libtls

import "core:crypto/ecdsa"
import "core:crypto/hash"
import "core:crypto/x25519"

// Where a server is in the handshake.
Server_State :: enum {
	Start,
	Send_Flight,
	Wait_Client_Finished,
	Connected,
	Failed,
}

Server :: struct {
	conn:  Conn, // the transcript, the secrets, and the record keys of each direction
	state: Server_State,

	// The identity: the leaf certificate in DER, and the key that signs for it.
	cert_der: []u8,
	key:      ecdsa.Private_Key,

	// The server's ephemeral X25519 key.
	priv: [32]u8,
	pub:  [32]u8,
}

// What a ClientHello offered that a server acts on. The client's X25519 public
// value and its legacy session id (echoed back). Two flags: whether it spoke
// TLS 1.3, and whether it offered the one suite this server has.
Client_Offer :: struct {
	random:     []u8,
	session_id: []u8,
	key_share:  []u8,
	tls13:      bool,
	suite:      bool,
}

// server_init gives a freshly zeroed `Server` its certificate and key. The
// key's scalar is the certificate's own private half. A caller that has the
// wrong one produces a CertificateVerify the client refuses.
server_init :: proc(s: ^Server, cert_der: []u8, priv_scalar: []u8) -> bool {
	s.cert_der = cert_der
	if !ecdsa.private_key_set_bytes(&s.key, .SECP256R1, priv_scalar) {
		s.state = .Failed
		return false
	}
	s.state = .Start
	return true
}

/*
parse_client_hello walks a ClientHello body (RFC 8446 section 4.1.2) and
answers what this server needs from it. `ok` is false on a malformed body. A
client that offered no TLS 1.3, no AES-128-GCM-SHA256 or no X25519 share is
not an error here. The offer's flags report it, so the caller can say which.
*/
parse_client_hello :: proc(body: []u8) -> (offer: Client_Offer, ok: bool) {
	r := reader(body)
	_ = r_u16(&r) // legacy_version
	offer.random = r_bytes(&r, 32)
	offer.session_id = r_vec8(&r)

	suites := r_vec16(&r)
	sr := reader(suites)
	for r_remaining(&sr) >= 2 && !sr.err {
		if r_u16(&sr) == TLS_AES_128_GCM_SHA256 {
			offer.suite = true
		}
	}
	_ = r_vec8(&r) // legacy_compression_methods

	exts := r_vec16(&r)
	er := reader(exts)
	for r_remaining(&er) > 0 && !er.err {
		etype := r_u16(&er)
		edata := r_vec16(&er)
		switch etype {
		case EXT_SUPPORTED_VERSIONS:
			vr := reader(edata)
			versions := r_vec8(&vr)
			vv := reader(versions)
			for r_remaining(&vv) >= 2 && !vv.err {
				if r_u16(&vv) == VERSION_TLS13 {
					offer.tls13 = true
				}
			}
		case EXT_KEY_SHARE:
			kr := reader(edata)
			shares := r_vec16(&kr)
			ss := reader(shares)
			for r_remaining(&ss) > 0 && !ss.err {
				group := r_u16(&ss)
				key := r_vec16(&ss)
				if group == GROUP_X25519 && len(key) == 32 {
					offer.key_share = key
				}
			}
		}
	}
	if r.err || er.err {
		return offer, false
	}
	return offer, true
}

/*
answer_client_hello answers a ClientHello. It reads the whole message and
refuses an offer this server cannot meet. It writes the ServerHello into
`out`, does the X25519 exchange, and installs the handshake keys. After it,
`s.conn.write` seals the flight and `s.conn.read` opens the client's Finished.

`priv` is the server's ephemeral scalar and `random` its 32 fresh bytes. A
fixture may fix both. A real server draws them from `/dev/random`. Returns the
ServerHello's length, or -1 on any refusal, with the server left `.Failed`.
*/
answer_client_hello :: proc(s: ^Server, ch_msg: []u8, priv: [32]u8, random: [32]u8, out: []u8) -> int {
	if s.state != .Start {
		s.state = .Failed
		return -1
	}
	r := reader(ch_msg)
	msg_type, body, ok := read_handshake(&r)
	if !ok || msg_type != HS_CLIENT_HELLO {
		s.state = .Failed
		return -1
	}
	offer, pok := parse_client_hello(body)
	if !pok || !offer.tls13 || !offer.suite || len(offer.key_share) != 32 {
		s.state = .Failed
		return -1
	}

	hash.init(&s.conn.transcript, HASH)
	transcript_update(&s.conn, ch_msg)

	s.priv = priv
	x25519.scalarmult_basepoint(s.pub[:], s.priv[:])

	rnd := random
	w := writer(out)
	w_u8(&w, HS_SERVER_HELLO)
	hs := w_open24(&w)
	w_u16(&w, VERSION_TLS12) // legacy_version
	w_bytes(&w, rnd[:])
	sid := w_open8(&w)
	w_bytes(&w, offer.session_id) // legacy_session_id_echo
	w_close8(&w, sid)
	w_u16(&w, TLS_AES_128_GCM_SHA256)
	w_u8(&w, 0) // legacy_compression_method
	exts := w_open16(&w)
	e := ext_open(&w, EXT_SUPPORTED_VERSIONS)
	w_u16(&w, VERSION_TLS13)
	ext_close(&w, e)
	e = ext_open(&w, EXT_KEY_SHARE)
	w_u16(&w, GROUP_X25519)
	k := w_open16(&w)
	w_bytes(&w, s.pub[:])
	w_close16(&w, k)
	ext_close(&w, e)
	w_close16(&w, exts)
	w_close24(&w, hs)
	if w.err {
		s.state = .Failed
		return -1
	}
	transcript_update(&s.conn, out[:w.pos])

	shared: [32]u8
	x25519.scalarmult(shared[:], s.priv[:], offer.key_share)
	install_handshake_keys(&s.conn, shared[:], false)

	s.conn.cipher = TLS_AES_128_GCM_SHA256
	s.conn.group = GROUP_X25519
	s.state = .Send_Flight
	return w.pos
}

// server_encrypted_extensions writes an EncryptedExtensions message with no
// extensions into `out` (RFC 8446 section 4.3.1) and folds it into the
// transcript. Returns its length, or -1.
server_encrypted_extensions :: proc(s: ^Server, out: []u8) -> int {
	if s.state != .Send_Flight {
		s.state = .Failed
		return -1
	}
	w := writer(out)
	w_u8(&w, HS_ENCRYPTED_EXTENSIONS)
	m := w_open24(&w)
	x := w_open16(&w)
	w_close16(&w, x)
	w_close24(&w, m)
	if w.err {
		s.state = .Failed
		return -1
	}
	transcript_update(&s.conn, out[:w.pos])
	return w.pos
}

// server_certificate writes a Certificate message holding the one leaf (RFC
// 8446 section 4.4.2). The request context is empty and the entry has no
// extensions. The message is folded into the transcript. Returns its length,
// or -1.
server_certificate :: proc(s: ^Server, out: []u8) -> int {
	if s.state != .Send_Flight {
		s.state = .Failed
		return -1
	}
	w := writer(out)
	w_u8(&w, HS_CERTIFICATE)
	m := w_open24(&w)
	w_u8(&w, 0) // certificate_request_context, empty
	list := w_open24(&w)
	entry := w_open24(&w)
	w_bytes(&w, s.cert_der)
	w_close24(&w, entry)
	x := w_open16(&w)
	w_close16(&w, x)
	w_close24(&w, list)
	w_close24(&w, m)
	if w.err {
		s.state = .Failed
		return -1
	}
	transcript_update(&s.conn, out[:w.pos])
	return w.pos
}

/*
server_certificate_verify signs the transcript through the Certificate with the
leaf's key and writes the CertificateVerify (RFC 8446 section 4.4.3). The
signature is ECDSA P-256 over SHA-256, deterministic (RFC 6979), so a fixture
needs no randomness. Returns its length, or -1.
*/
server_certificate_verify :: proc(s: ^Server, out: []u8) -> int {
	if s.state != .Send_Flight {
		s.state = .Failed
		return -1
	}
	th: [HASH_LEN]u8
	transcript_snapshot(&s.conn, th[:])
	content: [64 + len(CV_CONTEXT_SERVER) + 1 + HASH_LEN]u8
	build_cert_verify_content(th[:], content[:])
	sig, ok := ecdsa.sign_asn1(&s.key, .SHA256, content[:], context.allocator, true)
	if !ok {
		s.state = .Failed
		return -1
	}
	defer delete(sig)

	w := writer(out)
	w_u8(&w, HS_CERTIFICATE_VERIFY)
	m := w_open24(&w)
	w_u16(&w, SIG_ECDSA_SECP256R1_SHA256)
	sm := w_open16(&w)
	w_bytes(&w, sig)
	w_close16(&w, sm)
	w_close24(&w, m)
	if w.err {
		s.state = .Failed
		return -1
	}
	transcript_update(&s.conn, out[:w.pos])
	return w.pos
}

/*
server_finished writes the server's Finished: the MAC of the transcript through
CertificateVerify, under the server handshake secret. It folds the message in
and derives both application traffic secrets over the transcript through it.
The record keys stay the handshake ones until the client's Finished is
checked. Returns its length, or -1.
*/
server_finished :: proc(s: ^Server, out: []u8) -> int {
	if s.state != .Send_Flight {
		s.state = .Failed
		return -1
	}
	th: [HASH_LEN]u8
	transcript_snapshot(&s.conn, th[:])
	verify_data: [HASH_LEN]u8
	finished_mac(s.conn.s_hs_secret[:], th[:], verify_data[:])

	w := writer(out)
	w_u8(&w, HS_FINISHED)
	m := w_open24(&w)
	w_bytes(&w, verify_data[:])
	w_close24(&w, m)
	if w.err {
		s.state = .Failed
		return -1
	}
	transcript_update(&s.conn, out[:w.pos])

	th2: [HASH_LEN]u8
	transcript_snapshot(&s.conn, th2[:])
	derive_secret(s.conn.secrets.master[:], "c ap traffic", th2[:], s.conn.c_ap_secret[:])
	derive_secret(s.conn.secrets.master[:], "s ap traffic", th2[:], s.conn.s_ap_secret[:])
	s.state = .Wait_Client_Finished
	return w.pos
}

/*
server_client_finished checks the client's Finished. The expected value is the
MAC of the transcript through the server's own Finished, under the client
handshake secret. A good one is folded in, and both directions switch to the
application keys: `s.conn.write` seals under the server's, `s.conn.read` opens
under the client's. Returns false on a wrong MAC or message, with the server
left `.Failed`.
*/
server_client_finished :: proc(s: ^Server, msg: []u8) -> bool {
	if s.state != .Wait_Client_Finished {
		s.state = .Failed
		return false
	}
	r := reader(msg)
	msg_type, body, ok := read_handshake(&r)
	if !ok || msg_type != HS_FINISHED || len(body) != HASH_LEN {
		s.state = .Failed
		return false
	}
	th: [HASH_LEN]u8
	transcript_snapshot(&s.conn, th[:])
	expected: [HASH_LEN]u8
	finished_mac(s.conn.c_hs_secret[:], th[:], expected[:])
	if !slice_eq(expected[:], body) {
		s.state = .Failed
		return false
	}
	transcript_update(&s.conn, msg)

	record_keys(&s.conn.write, s.conn.s_ap_secret[:])
	record_keys(&s.conn.read, s.conn.c_ap_secret[:])
	s.state = .Connected
	return true
}
