/*
The TLS 1.3 server's encrypted flight, RFC 8446 section 4.4 -- the half of the
handshake that makes it secure.

After the ServerHello the whole flight arrives sealed under the server's
handshake traffic key: EncryptedExtensions, the Certificate, the
CertificateVerify that proves the server holds the certificate's private key,
and the Finished that binds the whole transcript. The caller opens each record
with `c.read` (installed by `server_hello`) and hands the plaintext handshake
message here; these procs check it, fold it into the transcript, and at the end
verify the chain, the signature and the MAC. Nothing here does I/O, exactly as
the two hellos before it.

The order is fixed and each step leans on the last:

  - `encrypted_extensions` accepts the server's extensions.
  - `certificate` parses the chain, verifies it to a trust root, and keeps the
    leaf's public key.
  - `certificate_verify` builds the string RFC 8446 section 4.4.3 signs -- the
    transcript through the Certificate -- and checks the server's signature over
    it with that key. This is the step that authenticates the server.
  - `finished` checks the server's Finished MAC over the transcript through the
    CertificateVerify, and derives the application traffic secrets.
  - `client_finished` writes the client's own Finished (the caller seals it under
    the still-current handshake key), and `enter_application` then switches both
    directions to the application keys.

A single failed check anywhere sets the connection to `.Failed` and returns
false; a client that ignores that and keeps talking would be talking to an
unauthenticated peer, so a caller stops at the first false.
*/
package libtls

import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:crypto/rsa"
import "core:crypto/x509"
import "core:time"

// The public-key kind of the server's leaf certificate, enough to pick the
// verifier for its CertificateVerify signature.
Leaf_Algo :: enum {
	Unknown,
	ECDSA_P256,
	RSA,
	Ed25519,
}

// The context string TLS 1.3 signs in a server CertificateVerify, RFC 8446
// section 4.4.3, and the 64 spaces and separator byte that frame it.
CV_CONTEXT_SERVER :: "TLS 1.3, server CertificateVerify"

// MAX_CHAIN_CERTS bounds a Certificate message's list: a leaf and its
// intermediates. A chain longer than this is refused rather than parsed.
MAX_CHAIN_CERTS :: 10

/*
encrypted_extensions takes the EncryptedExtensions message (RFC 8446 section
4.3.1), the first of the sealed flight. This client offered no extension whose
answer it must act on -- no ALPN, no early data -- so the body is accepted
whole and folded into the transcript; a server that sends a forbidden extension
here is not policed, only recorded. Returns false on the wrong message.
*/
encrypted_extensions :: proc(c: ^Conn, msg: []u8) -> bool {
	if c.state != .Wait_Flight {
		c.state = .Failed
		return false
	}
	r := reader(msg)
	msg_type, _, ok := read_handshake(&r)
	if !ok || msg_type != HS_ENCRYPTED_EXTENSIONS {
		c.state = .Failed
		return false
	}
	transcript_update(c, msg)
	return true
}

/*
certificate takes the Certificate message (RFC 8446 section 4.4.2), parses the
chain, and verifies it: the leaf must chain to one of `roots`, be valid at
`now`, and -- when `dns_name` is non-empty -- name that host. The leaf's public
key is kept for `certificate_verify`. `roots` is the caller's trust store (a
`tlsclient` reads `/lib/tls/roots`); the parse and the chain search allocate
from `allocator`, and this frees what it allocates.

Returns false on a malformed message, an unverifiable chain, or a leaf whose key
this client cannot use to check a signature.
*/
certificate :: proc(
	c: ^Conn,
	msg: []u8,
	roots: []^x509.Certificate,
	now: time.Time,
	dns_name: string,
	allocator := context.allocator,
) -> bool {
	if c.state != .Wait_Flight {
		c.state = .Failed
		return false
	}
	r := reader(msg)
	msg_type, body, ok := read_handshake(&r)
	if !ok || msg_type != HS_CERTIFICATE {
		c.state = .Failed
		return false
	}

	// certificate_request_context (empty when the server answers a ClientHello),
	// then the certificate_list.
	br := reader(body)
	_ = r_vec8(&br) // certificate_request_context
	list := r_vec24(&br)
	if br.err {
		c.state = .Failed
		return false
	}

	// Parse each CertificateEntry into a fixed array; the first is the leaf, the
	// rest are intermediates offered to bridge it to a root.
	certs: [MAX_CHAIN_CERTS]x509.Certificate
	n_certs := 0
	lr := reader(list)
	for r_remaining(&lr) > 0 && !lr.err {
		der := r_vec24(&lr)
		_ = r_vec16(&lr) // per-certificate extensions
		if lr.err {
			break
		}
		if n_certs >= MAX_CHAIN_CERTS {
			c.state = .Failed
			return false
		}
		cert, perr := x509.parse(der, allocator)
		if perr != .None {
			c.state = .Failed
			return false
		}
		certs[n_certs] = cert
		n_certs += 1
	}
	if lr.err || n_certs == 0 {
		for i in 0 ..< n_certs {
			x509.destroy(&certs[i], allocator)
		}
		c.state = .Failed
		return false
	}
	defer for i in 0 ..< n_certs {
		x509.destroy(&certs[i], allocator)
	}

	leaf := &certs[0]
	inters: [MAX_CHAIN_CERTS]^x509.Certificate
	for i in 1 ..< n_certs {
		inters[i - 1] = &certs[i]
	}

	opts := x509.Verify_Options {
		roots         = roots,
		intermediates = inters[:n_certs - 1],
		current_time  = now,
		dns_name      = dns_name,
		required_eku  = x509.EKU_Bit.Server_Auth,
	}
	chain, verr := x509.verify_chain(leaf, opts, allocator)
	if verr != .None {
		c.state = .Failed
		return false
	}
	delete(chain, allocator)

	// Keep the leaf's public key for the CertificateVerify to come.
	if !capture_leaf_key(c, leaf) {
		c.state = .Failed
		return false
	}

	transcript_update(c, msg)
	return true
}

// capture_leaf_key copies the leaf certificate's public key into the connection
// as raw bytes, so it outlives the parsed certificate and its DER buffer.
capture_leaf_key :: proc(c: ^Conn, leaf: ^x509.Certificate) -> bool {
	#partial switch leaf.public_key_algorithm {
	case .ECDSA_P256:
		if len(leaf.ec_point) > len(c.leaf_ec) {
			return false
		}
		c.leaf_algo = .ECDSA_P256
		c.leaf_ec_len = copy(c.leaf_ec[:], leaf.ec_point)
	case .Ed25519:
		if len(leaf.ec_point) > len(c.leaf_ec) {
			return false
		}
		c.leaf_algo = .Ed25519
		c.leaf_ec_len = copy(c.leaf_ec[:], leaf.ec_point)
	case .RSA:
		if len(leaf.rsa_n) > len(c.leaf_rsa_n) || len(leaf.rsa_e) > len(c.leaf_rsa_e) {
			return false
		}
		c.leaf_algo = .RSA
		c.leaf_rsa_n_len = copy(c.leaf_rsa_n[:], leaf.rsa_n)
		c.leaf_rsa_e_len = copy(c.leaf_rsa_e[:], leaf.rsa_e)
	case:
		return false
	}
	return true
}

/*
certificate_verify takes the CertificateVerify message (RFC 8446 section 4.4.3)
and checks the server's signature. The signed content is 64 space bytes, the
context string, a zero byte, and the transcript hash through the Certificate --
the transcript exactly as it stands before this message is folded in. The
signature is checked against the leaf key captured at `certificate`, by the
scheme the message names; a scheme this client did not offer, or one a leaf's
key cannot make, is a failure.

This is where the server is authenticated: only the holder of the leaf's private
key can have produced a signature over a transcript that includes this client's
own fresh ClientHello.
*/
certificate_verify :: proc(c: ^Conn, msg: []u8) -> bool {
	if c.state != .Wait_Flight {
		c.state = .Failed
		return false
	}
	r := reader(msg)
	msg_type, body, ok := read_handshake(&r)
	if !ok || msg_type != HS_CERTIFICATE_VERIFY {
		c.state = .Failed
		return false
	}
	br := reader(body)
	scheme := r_u16(&br)
	sig := r_vec16(&br)
	if br.err {
		c.state = .Failed
		return false
	}

	// The transcript through the Certificate, then the signed content built from
	// it. The snapshot is taken before this message joins the transcript.
	th: [HASH_LEN]u8
	transcript_snapshot(c, th[:])
	content: [64 + len(CV_CONTEXT_SERVER) + 1 + HASH_LEN]u8
	build_cert_verify_content(th[:], content[:])

	if !verify_signature(c, scheme, content[:], sig) {
		c.state = .Failed
		return false
	}

	transcript_update(c, msg)
	return true
}

// build_cert_verify_content lays out the octets a CertificateVerify signs, RFC
// 8446 section 4.4.3: 64 bytes of 0x20, the context string, a single 0x00, then
// the transcript hash. `out` must be exactly that length.
build_cert_verify_content :: proc(transcript_hash: []u8, out: []u8) {
	i := 0
	for i < 64 {
		out[i] = 0x20
		i += 1
	}
	i += copy(out[i:], CV_CONTEXT_SERVER)
	out[i] = 0x00
	i += 1
	copy(out[i:], transcript_hash)
}

// verify_signature checks `sig` over `content` with the captured leaf key, by
// the TLS SignatureScheme `scheme`. Only schemes a leaf's key can produce are
// accepted, and RSA PKCS#1 is rejected in a handshake signature as RFC 8446
// section 4.4.3 requires (it is a certificate-only scheme).
verify_signature :: proc(c: ^Conn, scheme: u16, content: []u8, sig: []u8) -> bool {
	switch scheme {
	case SIG_ECDSA_SECP256R1_SHA256:
		if c.leaf_algo != .ECDSA_P256 {
			return false
		}
		pub: ecdsa.Public_Key
		if !ecdsa.public_key_set_bytes(&pub, .SECP256R1, c.leaf_ec[:c.leaf_ec_len]) {
			return false
		}
		// The signature is ASN.1 DER SEQUENCE { r, s }, not raw r||s.
		return ecdsa.verify_asn1(&pub, .SHA256, content, sig)
	case SIG_RSA_PSS_RSAE_SHA256:
		return verify_rsa_pss(c, .SHA256, 32, content, sig)
	case SIG_RSA_PSS_RSAE_SHA384:
		return verify_rsa_pss(c, .SHA384, 48, content, sig)
	case SIG_ED25519:
		if c.leaf_algo != .Ed25519 {
			return false
		}
		pub: ed25519.Public_Key
		if !ed25519.public_key_set_bytes(&pub, c.leaf_ec[:c.leaf_ec_len]) {
			return false
		}
		return ed25519.verify(&pub, content, sig)
	case:
		return false
	}
}

verify_rsa_pss :: proc(c: ^Conn, hash_algo: hash.Algorithm, salt_len: int, content: []u8, sig: []u8) -> bool {
	if c.leaf_algo != .RSA {
		return false
	}
	pub: rsa.Public_Key
	if !rsa.public_key_set_bytes(&pub, c.leaf_rsa_n[:c.leaf_rsa_n_len], c.leaf_rsa_e[:c.leaf_rsa_e_len]) {
		return false
	}
	// TLS 1.3 fixes the PSS salt length at the hash length (RFC 8446 s 4.2.3).
	return rsa.verify_pss(&pub, hash_algo, salt_len, content, sig)
}

/*
finished takes the server's Finished message (RFC 8446 section 4.4.4) and checks
its MAC: HMAC over the transcript through the CertificateVerify, keyed by the
server's handshake "finished" key. A wrong MAC is a failure. Once it holds, the
handshake is authenticated end to end, and the application traffic secrets are
derived from the master secret and the transcript through this Finished. The
read direction is not switched here -- the caller still has its own Finished to
send under the handshake key -- but the secrets are kept for `enter_application`.
*/
finished :: proc(c: ^Conn, msg: []u8) -> bool {
	if c.state != .Wait_Flight {
		c.state = .Failed
		return false
	}
	r := reader(msg)
	msg_type, body, ok := read_handshake(&r)
	if !ok || msg_type != HS_FINISHED || len(body) != HASH_LEN {
		c.state = .Failed
		return false
	}

	// verify_data = HMAC(finished_key, Transcript-Hash(..CertificateVerify)).
	th: [HASH_LEN]u8
	transcript_snapshot(c, th[:])
	expected: [HASH_LEN]u8
	finished_mac(c.s_hs_secret[:], th[:], expected[:])
	if !slice_eq(expected[:], body) {
		c.state = .Failed
		return false
	}

	transcript_update(c, msg)

	// The application traffic secrets, over the transcript through the server's
	// Finished (RFC 8446 section 7.1). The record keys are switched later.
	th2: [HASH_LEN]u8
	transcript_snapshot(c, th2[:])
	derive_secret(c.secrets.master[:], "c ap traffic", th2[:], c.c_ap_secret[:])
	derive_secret(c.secrets.master[:], "s ap traffic", th2[:], c.s_ap_secret[:])

	c.state = .Send_Finished
	return true
}

/*
client_finished writes the client's Finished handshake message into `out` and
returns its length, or -1 if `out` is too small. Its verify_data is the MAC over
the transcript through the server's Finished, keyed by the client's handshake
"finished" key. The caller seals this under `c.write`, which is still the
handshake key, and then calls `enter_application`. The message is folded into
the transcript so a later resumption ticket binds to it.
*/
client_finished :: proc(c: ^Conn, out: []u8) -> int {
	if c.state != .Send_Finished {
		c.state = .Failed
		return -1
	}
	th: [HASH_LEN]u8
	transcript_snapshot(c, th[:])
	verify_data: [HASH_LEN]u8
	finished_mac(c.c_hs_secret[:], th[:], verify_data[:])

	w := writer(out)
	w_u8(&w, HS_FINISHED)
	m := w_open24(&w)
	w_bytes(&w, verify_data[:])
	w_close24(&w, m)
	if w.err {
		c.state = .Failed
		return -1
	}
	transcript_update(c, out[:w.pos])
	return w.pos
}

/*
enter_application switches both directions to the application traffic keys and
marks the connection connected. The caller calls it once it has sealed and sent
the client's Finished under the handshake key: after this, `c.write` seals
application data under the client key and `c.read` opens it under the server's.
*/
enter_application :: proc(c: ^Conn) {
	if c.state != .Send_Finished {
		c.state = .Failed
		return
	}
	record_keys(&c.read, c.s_ap_secret[:])
	record_keys(&c.write, c.c_ap_secret[:])
	c.state = .Connected
}

// finished_mac writes a Finished verify_data into `out`: the "finished" key is
// HKDF-Expand-Label of the base traffic secret with an empty context, and the
// MAC is HMAC-SHA-256 of that key over the transcript hash (RFC 8446 s 4.4.4).
finished_mac :: proc(base_secret: []u8, transcript_hash: []u8, out: []u8) {
	finished_key: [HASH_LEN]u8
	hkdf_expand_label(base_secret, "finished", {}, finished_key[:])
	hmac.sum(HASH, out, transcript_hash, finished_key[:])
}
