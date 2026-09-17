/*
cryptotest -- the fleet's cryptography, proven against known answers.

The kernel's self-test spawns this and reads the word it exits with: `ok`, or
the name of the first check that did not hold. `docs/FLEET.md` step 2 builds
its handshake on `sys/libcrypto`, and a handshake is only as trustworthy as the
primitives under it. So each is checked against a published test vector before
anything is built on it: the ChaCha20-Poly1305 AEAD against RFC 8439's own,
X25519 against RFC 7748's, and BLAKE2s and argon2id for a stable digest.
*/
package cryptotest

import "vsys:abi"
import "vsys:libcrypto"
import "vsys:libuser"
import "core:crypto/x25519"
import "core:crypto/blake2s"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:crypto/hkdf"
import "core:crypto/ecdsa"
import "core:crypto/x509"
import "core:time"
import "vsys:libauth"
import "vsys:libtls"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
}

// A synthetic ServerHello, so the handshake key exchange can be driven from
// both ends in one process and shown to reach the same keys.
tls_make_server_hello :: proc(server_pub: []u8, out: []u8) -> int {
	w := libtls.writer(out)
	libtls.w_u8(&w, libtls.HS_SERVER_HELLO)
	hs := libtls.w_open24(&w)
	libtls.w_u16(&w, libtls.VERSION_TLS12)
	srand: [32]u8
	for i in 0 ..< 32 {srand[i] = 0xaa}
	libtls.w_bytes(&w, srand[:])
	sid := libtls.w_open8(&w);libtls.w_close8(&w, sid)
	libtls.w_u16(&w, libtls.TLS_AES_128_GCM_SHA256)
	libtls.w_u8(&w, 0)
	exts := libtls.w_open16(&w)
	e := libtls.ext_open(&w, libtls.EXT_SUPPORTED_VERSIONS);libtls.w_u16(&w, libtls.VERSION_TLS13);libtls.ext_close(&w, e)
	e = libtls.ext_open(&w, libtls.EXT_KEY_SHARE);libtls.w_u16(&w, libtls.GROUP_X25519)
	k := libtls.w_open16(&w);libtls.w_bytes(&w, server_pub);libtls.w_close16(&w, k)
	libtls.ext_close(&w, e)
	libtls.w_close16(&w, exts)
	libtls.w_close24(&w, hs)
	return w.pos
}

// The client's X25519 public value out of a ClientHello body's key_share.
tls_ch_pub :: proc(body: []u8) -> []u8 {
	r := libtls.reader(body)
	_ = libtls.r_u16(&r);_ = libtls.r_bytes(&r, 32);_ = libtls.r_vec8(&r)
	_ = libtls.r_vec16(&r);_ = libtls.r_vec8(&r)
	exts := libtls.r_vec16(&r)
	er := libtls.reader(exts)
	for libtls.r_remaining(&er) > 0 && !er.err {
		et := libtls.r_u16(&er)
		ed := libtls.r_vec16(&er)
		if et == libtls.EXT_KEY_SHARE {
			kr := libtls.reader(ed)
			shares := libtls.r_vec16(&kr)
			sr := libtls.reader(shares)
			_ = libtls.r_u16(&sr)
			return libtls.r_vec16(&sr)
		}
	}
	return nil
}

// A real ECDSA P-256 self-signed certificate (DER) and its private scalar,
// generated with openssl (CN=vectra.test, valid 2020-2040). The flight test
// stands a server up with it: it signs a real CertificateVerify the client
// checks through x509 + ecdsa, exactly as a `tlsclient` will against the wire.
CERT_DER :: [436]u8{
	0x30, 0x82, 0x01, 0xb0, 0x30, 0x82, 0x01, 0x56, 0xa0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x14, 0x2d,
	0x31, 0x8e, 0xd9, 0x3c, 0xb6, 0x43, 0x8a, 0x37, 0xd5, 0x2e, 0xcd, 0xcd, 0xe9, 0x08, 0x3a, 0x4f,
	0x2e, 0x22, 0x7a, 0x30, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x30,
	0x16, 0x31, 0x14, 0x30, 0x12, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x0b, 0x76, 0x65, 0x63, 0x74,
	0x72, 0x61, 0x2e, 0x74, 0x65, 0x73, 0x74, 0x30, 0x1e, 0x17, 0x0d, 0x32, 0x30, 0x30, 0x31, 0x30,
	0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5a, 0x17, 0x0d, 0x34, 0x30, 0x30, 0x31, 0x30, 0x31,
	0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5a, 0x30, 0x16, 0x31, 0x14, 0x30, 0x12, 0x06, 0x03, 0x55,
	0x04, 0x03, 0x0c, 0x0b, 0x76, 0x65, 0x63, 0x74, 0x72, 0x61, 0x2e, 0x74, 0x65, 0x73, 0x74, 0x30,
	0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86,
	0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04, 0xb9, 0x58, 0x70, 0xc4, 0x2e, 0xaf,
	0x42, 0xc2, 0x16, 0x94, 0xa6, 0xd5, 0x62, 0x32, 0x2c, 0x66, 0x94, 0x88, 0x85, 0x05, 0x87, 0x73,
	0x03, 0x3c, 0x77, 0x26, 0xa4, 0xdb, 0xb8, 0x45, 0xf8, 0xa4, 0x7b, 0x8f, 0xa6, 0x56, 0xf4, 0xd7,
	0x1a, 0xd2, 0x8c, 0x8c, 0x5d, 0x1b, 0x75, 0xf0, 0xb6, 0xc3, 0x8b, 0xfb, 0xdf, 0xc1, 0x54, 0x49,
	0x86, 0xdb, 0x44, 0xf5, 0xf8, 0xf5, 0xc6, 0xc3, 0x9b, 0x00, 0xa3, 0x81, 0x81, 0x30, 0x7f, 0x30,
	0x1d, 0x06, 0x03, 0x55, 0x1d, 0x0e, 0x04, 0x16, 0x04, 0x14, 0x00, 0xc7, 0xb6, 0xab, 0xb3, 0x5c,
	0xa3, 0xe2, 0xfb, 0xde, 0x37, 0x89, 0x74, 0x81, 0x34, 0x05, 0x57, 0x9b, 0x4f, 0xdc, 0x30, 0x1f,
	0x06, 0x03, 0x55, 0x1d, 0x23, 0x04, 0x18, 0x30, 0x16, 0x80, 0x14, 0x00, 0xc7, 0xb6, 0xab, 0xb3,
	0x5c, 0xa3, 0xe2, 0xfb, 0xde, 0x37, 0x89, 0x74, 0x81, 0x34, 0x05, 0x57, 0x9b, 0x4f, 0xdc, 0x30,
	0x0f, 0x06, 0x03, 0x55, 0x1d, 0x13, 0x01, 0x01, 0xff, 0x04, 0x05, 0x30, 0x03, 0x01, 0x01, 0xff,
	0x30, 0x2c, 0x06, 0x03, 0x55, 0x1d, 0x11, 0x04, 0x25, 0x30, 0x23, 0x82, 0x0b, 0x76, 0x65, 0x63,
	0x74, 0x72, 0x61, 0x2e, 0x74, 0x65, 0x73, 0x74, 0x82, 0x06, 0x76, 0x65, 0x63, 0x74, 0x72, 0x61,
	0x82, 0x03, 0x6f, 0x6e, 0x65, 0x82, 0x03, 0x74, 0x77, 0x6f, 0x82, 0x02, 0x66, 0x73, 0x30, 0x0a,
	0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02, 0x03, 0x48, 0x00, 0x30, 0x45, 0x02,
	0x20, 0x4d, 0xc7, 0x2f, 0x66, 0x6b, 0xab, 0x2a, 0xfd, 0x80, 0xe5, 0xcb, 0x8d, 0xe7, 0xbf, 0x4f,
	0x6b, 0x31, 0x28, 0x88, 0x4c, 0x04, 0x4d, 0xec, 0xa3, 0x37, 0x28, 0xd9, 0x8f, 0x94, 0x96, 0xfb,
	0xbd, 0x02, 0x21, 0x00, 0xba, 0xdc, 0xb7, 0x32, 0x98, 0xdb, 0x35, 0x2c, 0x65, 0xf6, 0x1e, 0xc4,
	0x38, 0x47, 0x2f, 0x68, 0xbc, 0xe6, 0x9b, 0x4c, 0xdf, 0xb9, 0xbd, 0x3c, 0x5b, 0x49, 0xc0, 0xf0,
	0xf2, 0xea, 0xb4, 0x7b,
}

CERT_PRIV :: [32]u8{
	0x92, 0xf2, 0x9e, 0x14, 0x1a, 0x76, 0xb7, 0xa3, 0x24, 0x15, 0x22, 0x91, 0x8e, 0x97, 0x45, 0x9f,
	0xce, 0xcf, 0xb3, 0xa8, 0x8d, 0x01, 0xb7, 0x43, 0xda, 0x72, 0x23, 0x9b, 0xa3, 0x6b, 0xaa, 0x3c,
}

// -- A scripted TLS 1.3 server, in memory, to drive the client transport ------
//
// libtls.Client is the record demultiplexer and handshake driver. To prove it
// end to end without a network, this stands a minimal server on the other end
// of an in-memory pipe and answers the client's ClientHello with a full flight
// -- deliberately fragmented the way a real peer's might be: the ServerHello in
// the clear, a change_cipher_spec to ignore, the Certificate split across two
// records, and the CertificateVerify and Finished packed into one. That is
// exactly the reassembly and demux the driver must get right.
Mock :: struct {
	srv:           libtls.Server,
	cert:          [512]u8, // the server's leaf, the store's one certificate
	cert_len:      int,
	msg:           [1024]u8, // the handshake message being built
	c2s:           [1024]u8, // records the client wrote
	c2s_len:       int,
	c2s_pos:       int,
	s2c:           [2048]u8, // records the server has staged for the client
	s2c_len:       int,
	s2c_pos:       int,
	phase:         int,
	request:       [128]u8, // the client's application request, captured
	request_len:   int,
	client_fin_ok: bool,
}

mock_write :: proc(ctx: rawptr, buf: []u8) -> int {
	m := (^Mock)(ctx)
	copy(m.c2s[m.c2s_len:], buf)
	m.c2s_len += len(buf)
	return len(buf)
}

mock_read :: proc(ctx: rawptr, buf: []u8) -> int {
	m := (^Mock)(ctx)
	for m.s2c_pos >= m.s2c_len {
		if !mock_advance(m) {
			return 0
		}
	}
	n := copy(buf, m.s2c[m.s2c_pos:m.s2c_len])
	m.s2c_pos += n
	return n
}

mock_advance :: proc(m: ^Mock) -> bool {
	switch m.phase {
	case 0:
		mock_flight(m)
		m.phase = 1
		return true
	case 1:
		mock_response(m)
		m.phase = 2
		return true
	case:
		return false
	}
}

mock_emit_plain :: proc(m: ^Mock, wire: u8, payload: []u8) {
	m.s2c_len += libtls.write_plaintext_record(wire, payload, m.s2c[m.s2c_len:])
}

mock_emit_sealed :: proc(m: ^Mock, inner: u8, payload: []u8) {
	m.s2c_len += libtls.seal_record(&m.srv.conn.write, inner, payload, m.s2c[m.s2c_len:])
}

mock_next_c2s :: proc(m: ^Mock) -> (full: []u8, ok: bool) {
	if m.c2s_pos + libtls.RECORD_HEADER > m.c2s_len {
		return nil, false
	}
	length := int(m.c2s[m.c2s_pos + 3]) << 8 | int(m.c2s[m.c2s_pos + 4])
	if m.c2s_pos + libtls.RECORD_HEADER + length > m.c2s_len {
		return nil, false
	}
	full = m.c2s[m.c2s_pos:][:libtls.RECORD_HEADER + length]
	m.c2s_pos += libtls.RECORD_HEADER + length
	return full, true
}

// mock_flight answers the ClientHello: it runs the server half of the exchange
// through `sys/libtls/server.odin`, one message at a time, and stages the
// flight into the server-to-client buffer fragmented on purpose.
mock_flight :: proc(m: ^Mock) {
	ch_len := int(m.c2s[3]) << 8 | int(m.c2s[4])
	ch_msg := m.c2s[libtls.RECORD_HEADER:][:ch_len]
	m.c2s_pos = libtls.RECORD_HEADER + ch_len

	spriv: [32]u8;for i in 0 ..< 32 {spriv[i] = u8(0x80 + i)}
	srand: [32]u8;for i in 0 ..< 32 {srand[i] = 0xaa}
	shn := libtls.answer_client_hello(&m.srv, ch_msg, spriv, srand, m.msg[:])
	want(shn > 0, "the scripted server answers the ClientHello")

	// ServerHello in the clear, then a change_cipher_spec to be ignored.
	mock_emit_plain(m, libtls.CONTENT_HANDSHAKE, m.msg[:shn])
	ccs := [1]u8{0x01}
	mock_emit_plain(m, libtls.CONTENT_CHANGE_CIPHER_SPEC, ccs[:])

	// EncryptedExtensions, in its own record.
	n := libtls.server_encrypted_extensions(&m.srv, m.msg[:])
	want(n > 0, "and writes EncryptedExtensions")
	mock_emit_sealed(m, libtls.CONTENT_HANDSHAKE, m.msg[:n])

	// Certificate, split across two records to exercise reassembly.
	n = libtls.server_certificate(&m.srv, m.msg[:])
	want(n > 0, "and the Certificate")
	half := n / 2
	mock_emit_sealed(m, libtls.CONTENT_HANDSHAKE, m.msg[:half])
	mock_emit_sealed(m, libtls.CONTENT_HANDSHAKE, m.msg[half:n])

	// CertificateVerify and Finished, packed into one record.
	cvn := libtls.server_certificate_verify(&m.srv, m.msg[:])
	want(cvn > 0, "and signs the CertificateVerify")
	fn := libtls.server_finished(&m.srv, m.msg[cvn:])
	want(fn > 0, "and its Finished")
	mock_emit_sealed(m, libtls.CONTENT_HANDSHAKE, m.msg[:cvn + fn])
}

// mock_response reads the client's Finished and its application request, checks
// the Finished MAC, keeps the request, and stages a reply.
mock_response :: proc(m: ^Mock) {
	scratch: [256]u8
	if fin_full, ok := mock_next_c2s(m); ok {
		fn, ftype, fok := libtls.open_record(&m.srv.conn.read, fin_full, scratch[:])
		if fok && ftype == libtls.CONTENT_HANDSHAKE {
			m.client_fin_ok = libtls.server_client_finished(&m.srv, scratch[:fn])
		}
	}
	if req_full, ok := mock_next_c2s(m); ok {
		rn, rtype, rok := libtls.open_record(&m.srv.conn.read, req_full, scratch[:])
		if rok && rtype == libtls.CONTENT_APPLICATION_DATA {
			m.request_len = copy(m.request[:], scratch[:rn])
		}
	}
	reply := transmute([]u8)string("hello from the mock server")
	mock_emit_sealed(m, libtls.CONTENT_APPLICATION_DATA, reply)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()

	// -- RFC 8439 section 2.8.2: the AEAD's own test vector -----------------
	{
		key: [32]u8
		for i in 0 ..< 32 {key[i] = u8(0x80 + i)}
		nonce := [12]u8{0x07, 0, 0, 0, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47}
		aad := [12]u8{0x50, 0x51, 0x52, 0x53, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7}
		pt := "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
		ct: [114]u8
		tag: [16]u8
		libcrypto.seal(ct[:], tag[:], key[:], nonce[:], aad[:], transmute([]u8)pt)

		// The tag RFC 8439 gives for this input.
		want_tag := [16]u8{0x1a, 0xe1, 0x0b, 0x59, 0x4f, 0x09, 0xe2, 0x6a, 0x7e, 0x90, 0x2e, 0xcb, 0xd0, 0x60, 0x06, 0x91}
		want(ct[0] == 0xd3 && ct[1] == 0x1a && ct[112] == 0x61 && ct[113] == 0x16, "the AEAD ciphertext is RFC 8439's")
		want(tag == want_tag, "and the tag is RFC 8439's")

		// And it round-trips: open recovers the plaintext and checks the tag.
		back: [114]u8
		want(libcrypto.open(back[:], key[:], nonce[:], aad[:], ct[:], tag[:]), "the tag verifies on open")
		want(string(back[:]) == pt, "and the plaintext comes back")
		// A flipped tag byte is refused.
		bad := tag
		bad[0] ~= 1
		want(!libcrypto.open(back[:], key[:], nonce[:], aad[:], ct[:], bad[:]), "a tampered tag is refused")
	}

	// -- RFC 7748 section 5.2: X25519 with the vector's scalar and point ----
	{
		scalar := [32]u8{0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d, 0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd, 0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18, 0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4}
		point := [32]u8{0xe6, 0xdb, 0x68, 0x67, 0x58, 0x30, 0x30, 0xdb, 0x35, 0x94, 0xc1, 0xa4, 0x24, 0xb1, 0x5f, 0x7c, 0x72, 0x66, 0x24, 0xec, 0x26, 0xb3, 0x35, 0x3b, 0x10, 0xa9, 0x03, 0xa6, 0xd0, 0xab, 0x1c, 0x4c}
		out: [32]u8
		x25519.scalarmult(out[:], scalar[:], point[:])
		want(out[0] == 0xc3 && out[1] == 0xda && out[31] == 0x52, "X25519 matches RFC 7748")
	}

	// -- BLAKE2s: a known digest of the empty input -------------------------
	{
		h: [32]u8
		ctx: blake2s.Context
		blake2s.init(&ctx)
		blake2s.final(&ctx, h[:])
		// BLAKE2s-256 of "" begins 69:21:7a:30 ...
		want(h[0] == 0x69 && h[1] == 0x21 && h[2] == 0x7a && h[3] == 0x30, "BLAKE2s of the empty input is known")
	}

	// -- /dev/random: the entropy a handshake's ephemeral key comes from ----
	{
		fd := libuser.open("/dev/random", abi.O_RDONLY)
		want(fd >= 0, "/dev/random opens")
		a: [32]u8
		b: [32]u8
		want(libuser.read(int(fd), a[:]) == 32, "and fills a request")
		want(libuser.read(int(fd), b[:]) == 32, "twice")
		_ = libuser.close(int(fd))
		zero := true
		for x in a {
			if x != 0 {zero = false}
		}
		want(!zero, "with bytes that are not all zero")
		want(a != b, "and a second read differs from the first")
	}

	// -- A Noise IK handshake, end to end ----------------------------------
	{
		// Static keys for the two ends, and an ephemeral each. Any 32 bytes
		// are a valid X25519 private key; X25519 clamps them.
		istatic: [32]u8; for i in 0 ..< 32 {istatic[i] = u8(i + 1)}
		rstatic: [32]u8; for i in 0 ..< 32 {rstatic[i] = u8(0x40 + i)}
		ieph: [32]u8; for i in 0 ..< 32 {ieph[i] = u8(0x80 + i)}
		reph: [32]u8; for i in 0 ..< 32 {reph[i] = u8(0xc0 + i)}
		rpub: [32]u8
		libauth.public_of(rpub[:], rstatic[:])
		ipub: [32]u8
		libauth.public_of(ipub[:], istatic[:])

		hi: libauth.Handshake
		hr: libauth.Handshake
		libauth.init_initiator(&hi, istatic[:], rpub[:], ieph[:])
		libauth.init_responder(&hr, rstatic[:], reph[:])

		msg1: [256]u8
		n1 := libauth.write_msg1(&hi, msg1[:], transmute([]u8)string("hello"))
		got1: [64]u8
		gn1, ok1 := libauth.read_msg1(&hr, msg1[:n1], got1[:])
		want(ok1 && string(got1[:gn1]) == "hello", "the responder reads the first message")
		want(hr.rs == ipub, "and learns the initiator's static key, its name for it")

		msg2: [256]u8
		n2 := libauth.write_msg2(&hr, msg2[:], transmute([]u8)string("world"))
		got2: [64]u8
		gn2, ok2 := libauth.read_msg2(&hi, msg2[:n2], got2[:])
		want(ok2 && string(got2[:gn2]) == "world", "the initiator reads the second message")

		isend, irecv := libauth.split(&hi)
		rsend, rrecv := libauth.split(&hr)
		want(isend.k == rrecv.k && irecv.k == rsend.k, "both ends hold the same transport keys")

		// A sealed frame each way, under the direction's key.
		frame: [64]u8
		libauth.transport_seal(&isend, frame[:5 + libauth.TAG_SIZE], transmute([]u8)string("first"))
		out: [64]u8
		want(libauth.transport_open(&rrecv, out[:], frame[:5 + libauth.TAG_SIZE]) && string(out[:5]) == "first", "a frame from the initiator opens on the responder")
		libauth.transport_seal(&rsend, frame[:4 + libauth.TAG_SIZE], transmute([]u8)string("back"))
		want(libauth.transport_open(&irecv, out[:], frame[:4 + libauth.TAG_SIZE]) && string(out[:4]) == "back", "and a frame the other way opens too")

		// A handshake to the wrong responder key fails: the initiator that
		// thinks the responder is someone else cannot complete es.
		hw: libauth.Handshake
		wrong: [32]u8; for i in 0 ..< 32 {wrong[i] = u8(0x11)}
		wpub: [32]u8; libauth.public_of(wpub[:], wrong[:])
		libauth.init_initiator(&hw, istatic[:], wpub[:], ieph[:])
		hr2: libauth.Handshake
		libauth.init_responder(&hr2, rstatic[:], reph[:])
		mw: [256]u8
		nw := libauth.write_msg1(&hw, mw[:], transmute([]u8)string("x"))
		gw: [64]u8
		_, okw := libauth.read_msg1(&hr2, mw[:nw], gw[:])
		want(!okw, "a handshake aimed at the wrong key is refused")
	}

	// -- The TLS 1.3 substrate, run on this machine -------------------------
	//
	// `docs/WEB.md` step 0 builds TLS 1.3 on Odin's `core:crypto`, whose hash,
	// MAC, key-derivation and signature packages have no freestanding build of
	// their own -- `build.odin` installs the backend that lets them compile,
	// and every one selects its portable software path here. So this is where
	// that path is proven to run and to agree with the RFCs on the real target,
	// not only on the host that built it. The key schedule stands on HKDF,
	// HKDF on HMAC, HMAC on SHA-256, and the certificate on ECDSA.
	{
		// SHA-256 of "abc" (FIPS 180-4's own example).
		sum: [32]u8
		hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)string("abc"), sum[:])
		want(sum[0] == 0xba && sum[1] == 0x78 && sum[31] == 0xad, "SHA-256 matches FIPS 180-4")

		// HMAC-SHA-256, RFC 4231 test case 2.
		tag: [32]u8
		hmac.sum(.SHA256, tag[:], transmute([]u8)string("what do ya want for nothing?"), transmute([]u8)string("Jefe"))
		want(tag[0] == 0x5b && tag[1] == 0xdc && tag[31] == 0x43, "HMAC-SHA-256 matches RFC 4231")

		// HKDF-SHA-256, RFC 5869 test case 1: extract then expand to 42 bytes.
		ikm: [22]u8; for i in 0 ..< 22 {ikm[i] = 0x0b}
		salt: [13]u8; for i in 0 ..< 13 {salt[i] = u8(i)}
		info: [10]u8; for i in 0 ..< 10 {info[i] = u8(0xf0 + i)}
		okm: [42]u8
		hkdf.extract_and_expand(.SHA256, salt[:], ikm[:], info[:], okm[:])
		want(okm[0] == 0x3c && okm[1] == 0xb2 && okm[41] == 0x65, "HKDF-SHA-256 matches RFC 5869")

		// ECDSA over P-256: a fixed key, a deterministic (RFC 6979) signature,
		// and the verify that a certificate chain will lean on. No entropy is
		// drawn, so the check is stable and needs no RNG on the target.
		kb: [32]u8; for i in 0 ..< 32 {kb[i] = u8(i + 1)}
		priv: ecdsa.Private_Key
		pub: ecdsa.Public_Key
		want(ecdsa.private_key_set_bytes(&priv, .SECP256R1, kb[:]), "a P-256 private key sets")
		ecdsa.public_key_set_priv(&pub, &priv)
		msg := transmute([]u8)string("the reader keeps the other direction itself")
		sig: [64]u8
		want(ecdsa.sign_raw(&priv, .SHA256, msg, sig[:], true), "P-256 signs")
		want(ecdsa.verify_raw(&pub, .SHA256, msg, sig[:]), "and the signature verifies")
		sig[10] ~= 0xff
		want(!ecdsa.verify_raw(&pub, .SHA256, msg, sig[:]), "a tampered P-256 signature is refused")

		// The TLS 1.3 key schedule, against RFC 8448's Simple 1-RTT trace.
		// `sys/libtls`'s ladder walks the three extracts from the trace's
		// (EC)DHE secret and must reach the trace's early, handshake and master
		// secrets; then a traffic secret from the trace derives the trace's own
		// write key and IV. No handshake message is parsed -- these are the
		// schedule's published intermediate values, which is the point.
		ecdhe := [32]u8{0x8b, 0xd4, 0x05, 0x4f, 0xb5, 0x5b, 0x9d, 0x63, 0xfd, 0xfb, 0xac, 0xf9, 0xf0, 0x4b, 0x9f, 0x0d, 0x35, 0xe6, 0xd6, 0x3f, 0x53, 0x75, 0x63, 0xef, 0xd4, 0x62, 0x72, 0x90, 0x0f, 0x89, 0x49, 0x2d}
		sec: libtls.Secrets
		libtls.ladder(&sec, ecdhe[:])
		want(sec.early == [32]u8{0x33, 0xad, 0x0a, 0x1c, 0x60, 0x7e, 0xc0, 0x3b, 0x09, 0xe6, 0xcd, 0x98, 0x93, 0x68, 0x0c, 0xe2, 0x10, 0xad, 0xf3, 0x00, 0xaa, 0x1f, 0x26, 0x60, 0xe1, 0xb2, 0x2e, 0x10, 0xf1, 0x70, 0xf9, 0x2a}, "TLS 1.3 early secret matches RFC 8448")
		want(sec.handshake == [32]u8{0x1d, 0xc8, 0x26, 0xe9, 0x36, 0x06, 0xaa, 0x6f, 0xdc, 0x0a, 0xad, 0xc1, 0x2f, 0x74, 0x1b, 0x01, 0x04, 0x6a, 0xa6, 0xb9, 0x9f, 0x69, 0x1e, 0xd2, 0x21, 0xa9, 0xf0, 0xca, 0x04, 0x3f, 0xbe, 0xac}, "TLS 1.3 handshake secret matches RFC 8448")
		want(sec.master == [32]u8{0x18, 0xdf, 0x06, 0x84, 0x3d, 0x13, 0xa0, 0x8b, 0xf2, 0xa4, 0x49, 0x84, 0x4c, 0x5f, 0x8a, 0x47, 0x80, 0x01, 0xbc, 0x4d, 0x4c, 0x62, 0x79, 0x84, 0xd5, 0xa4, 0x1d, 0xa8, 0xd0, 0x40, 0x29, 0x19}, "TLS 1.3 master secret matches RFC 8448")

		// A traffic secret from the trace, to the write key and IV it names.
		s_hs := [32]u8{0xb6, 0x7b, 0x7d, 0x69, 0x0c, 0xc1, 0x6c, 0x4e, 0x75, 0xe5, 0x42, 0x13, 0xcb, 0x2d, 0x37, 0xb4, 0xe9, 0xc9, 0x12, 0xbc, 0xde, 0xd9, 0x10, 0x5d, 0x42, 0xbe, 0xfd, 0x59, 0xd3, 0x91, 0xad, 0x38}
		ki: libtls.Key_Iv
		libtls.traffic_key_iv(s_hs[:], &ki)
		want(ki.key == [16]u8{0x3f, 0xce, 0x51, 0x60, 0x09, 0xc2, 0x17, 0x27, 0xd0, 0xf2, 0xe4, 0xe8, 0x6e, 0xe4, 0x03, 0xbc}, "TLS 1.3 write key matches RFC 8448")
		want(ki.iv == [12]u8{0x5d, 0x31, 0x3e, 0xb2, 0x67, 0x12, 0x76, 0xee, 0x13, 0x00, 0x0b, 0x30}, "TLS 1.3 write iv matches RFC 8448")

		// The TLS 1.3 record layer, over those verified keys: seal one record,
		// open it back to its content and type, and refuse a tampered header
		// and a wrong sequence -- the AAD binding and the nonce's count, which
		// a seal/open roundtrip on its own cannot show.
		send := libtls.Record_Keys{key = ki.key, iv = ki.iv, seq = 0}
		recv := libtls.Record_Keys{key = ki.key, iv = ki.iv, seq = 0}
		rec_content := transmute([]u8)string("a sealed handshake record")
		rbuf: [128]u8
		rn := libtls.seal_record(&send, libtls.CONTENT_HANDSHAKE, rec_content, rbuf[:], 5)
		want(rn > 0 && send.seq == 1, "a TLS 1.3 record seals and counts up")
		robuf: [128]u8
		rm, rtype, rok := libtls.open_record(&recv, rbuf[:rn], robuf[:])
		want(rok && rtype == libtls.CONTENT_HANDSHAKE && string(robuf[:rm]) == string(rec_content), "and opens back to its content and type")
		want(recv.seq == 1, "and the read sequence counts up too")
		bad := rbuf
		bad[4] ~= 1
		recv2 := libtls.Record_Keys{key = ki.key, iv = ki.iv, seq = 0}
		_, _, bok := libtls.open_record(&recv2, bad[:rn], robuf[:])
		want(!bok, "a tampered TLS record header is refused")
		recv3 := libtls.Record_Keys{key = ki.key, iv = ki.iv, seq = 1}
		_, _, sok := libtls.open_record(&recv3, rbuf[:rn], robuf[:])
		want(!sok, "a TLS record opened at the wrong sequence is refused")

		// TLS 1.3 message parsing: RFC 8448's own ServerHello, to its fields.
		sh_msg := [?]u8{
			0x02, 0x00, 0x00, 0x56, 0x03, 0x03, 0xa6, 0xaf, 0x06, 0xa4, 0x12, 0x18, 0x60, 0xdc, 0x5e, 0x6e,
			0x60, 0x24, 0x9c, 0xd3, 0x4c, 0x95, 0x93, 0x0c, 0x8a, 0xc5, 0xcb, 0x14, 0x34, 0xda, 0xc1, 0x55,
			0x77, 0x2e, 0xd3, 0xe2, 0x69, 0x28, 0x00, 0x13, 0x01, 0x00, 0x00, 0x2e, 0x00, 0x33, 0x00, 0x24,
			0x00, 0x1d, 0x00, 0x20, 0xc9, 0x82, 0x88, 0x76, 0x11, 0x20, 0x95, 0xfe, 0x66, 0x76, 0x2b, 0xdb,
			0xf7, 0xc6, 0x72, 0xe1, 0x56, 0xd6, 0xcc, 0x25, 0x3b, 0x83, 0x3d, 0xf1, 0xdd, 0x69, 0xb1, 0xb0,
			0x4e, 0x75, 0x1f, 0x0f, 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04,
		}
		mr := libtls.reader(sh_msg[:])
		mt, sh_body, hok := libtls.read_handshake(&mr)
		want(hok && mt == libtls.HS_SERVER_HELLO && len(sh_body) == 86, "a TLS handshake header frames RFC 8448's ServerHello")
		sh, shok := libtls.parse_server_hello(sh_body)
		want(shok && sh.cipher_suite == libtls.TLS_AES_128_GCM_SHA256 && sh.version == libtls.VERSION_TLS13, "and its suite and version parse to RFC 8448's")
		want(sh.group == libtls.GROUP_X25519 && len(sh.key_share) == 32 && sh.key_share[0] == 0xc9 && sh.key_share[31] == 0x0f && !sh.is_retry, "and its X25519 key share is the trace's")

		// And a ClientHello this client writes frames back as one.
		chrnd: [32]u8; for i in 0 ..< 32 {chrnd[i] = u8(i)}
		chpub: [32]u8; for i in 0 ..< 32 {chpub[i] = u8(0x40 + i)}
		chbuf: [512]u8
		cw := libtls.writer(chbuf[:])
		libtls.write_client_hello(&cw, {random = chrnd[:], key_share = chpub[:], server_name = "vectra.test", session_id = {}})
		crd := libtls.reader(chbuf[:cw.pos])
		cmt, _, cok := libtls.read_handshake(&crd)
		want(!cw.err && cok && cmt == libtls.HS_CLIENT_HELLO, "and a ClientHello this client writes frames as one")

		// The handshake's key exchange, both ends in one process. First the
		// interop anchor: RFC 8448's client private times the trace's server
		// public is the trace's shared secret, so this X25519 agrees with a
		// real peer's. Then a loopback: a client and a synthetic server drive
		// client_hello / server_hello to the same handshake keys, shown by a
		// record one seals opening under the key the other derived.
		rfc_priv := [32]u8{0x49, 0xaf, 0x42, 0xba, 0x7f, 0x79, 0x94, 0x85, 0x2d, 0x71, 0x3e, 0xf2, 0x78, 0x4b, 0xcb, 0xca, 0xa7, 0x91, 0x1d, 0xe2, 0x6a, 0xdc, 0x56, 0x42, 0xcb, 0x63, 0x45, 0x40, 0xe7, 0xea, 0x50, 0x05}
		rfc_spub := [32]u8{0xc9, 0x82, 0x88, 0x76, 0x11, 0x20, 0x95, 0xfe, 0x66, 0x76, 0x2b, 0xdb, 0xf7, 0xc6, 0x72, 0xe1, 0x56, 0xd6, 0xcc, 0x25, 0x3b, 0x83, 0x3d, 0xf1, 0xdd, 0x69, 0xb1, 0xb0, 0x4e, 0x75, 0x1f, 0x0f}
		shared: [32]u8
		x25519.scalarmult(shared[:], rfc_priv[:], rfc_spub[:])
		want(shared == [32]u8{0x8b, 0xd4, 0x05, 0x4f, 0xb5, 0x5b, 0x9d, 0x63, 0xfd, 0xfb, 0xac, 0xf9, 0xf0, 0x4b, 0x9f, 0x0d, 0x35, 0xe6, 0xd6, 0x3f, 0x53, 0x75, 0x63, 0xef, 0xd4, 0x62, 0x72, 0x90, 0x0f, 0x89, 0x49, 0x2d}, "TLS 1.3 X25519 agrees with RFC 8448's peer")

		c: libtls.Conn
		cpriv: [32]u8; for i in 0 ..< 32 {cpriv[i] = u8(i + 1)}
		crand: [32]u8; for i in 0 ..< 32 {crand[i] = u8(0x10 + i)}
		chb: [512]u8
		chn := libtls.client_hello(&c, cpriv, crand, "vectra.test", chb[:])
		want(chn > 0, "the client writes a ClientHello and holds its transcript")
		ch_msg := chb[:chn]

		spriv: [32]u8; for i in 0 ..< 32 {spriv[i] = u8(0x80 + i)}
		spub: [32]u8; x25519.scalarmult_basepoint(spub[:], spriv[:])
		chr := libtls.reader(ch_msg)
		_, ch_body, _ := libtls.read_handshake(&chr)
		cpub := tls_ch_pub(ch_body)
		shb: [256]u8
		shn := tls_make_server_hello(spub[:], shb[:])
		lsh_msg := shb[:shn]
		want(libtls.server_hello(&c, lsh_msg) && c.state == .Wait_Flight, "the client reads the ServerHello and holds handshake keys")

		srv: libtls.Conn
		hash.init(&srv.transcript, libtls.HASH)
		libtls.transcript_update(&srv, ch_msg)
		libtls.transcript_update(&srv, lsh_msg)
		sshared: [32]u8; x25519.scalarmult(sshared[:], spriv[:], cpub)
		libtls.install_handshake_keys(&srv, sshared[:], false)
		want(c.c_hs_secret == srv.c_hs_secret && c.s_hs_secret == srv.s_hs_secret, "and both ends reach the same handshake traffic secrets")

		flight := transmute([]u8)string("the server's first sealed flight")
		frec: [128]u8
		fn := libtls.seal_record(&srv.write, libtls.CONTENT_HANDSHAKE, flight, frec[:])
		fout: [128]u8
		fm, fct, fok := libtls.open_record(&c.read, frec[:fn], fout[:])
		want(fok && fct == libtls.CONTENT_HANDSHAKE && string(fout[:fm]) == string(flight), "and a record the server seals opens on the client")

		// -- The TLS 1.3 encrypted flight: the half that authenticates the server.
		//
		// The synthetic server holds a real ECDSA P-256 certificate. It sends the
		// sealed flight -- EncryptedExtensions, the Certificate, a
		// CertificateVerify it signs over the live transcript, and its Finished.
		// The client opens each record under the server's handshake key and runs
		// the flight parsers, which verify the chain to a trust root, the
		// signature, and the MAC. Then the client's own Finished crosses and
		// application data flows under the application keys. This is the first
		// on-target proof of the authentication path -- x509.verify_chain and
		// ecdsa.verify_asn1 over a real certificate and a real, live signature.

		// The trust store: the leaf is its own root (self-signed), so a parse of
		// the same DER is the one anchor; a `tlsclient` reads /lib/tls/roots.
		cert_der := CERT_DER
		rootc, root_perr := x509.parse(cert_der[:])
		want(root_perr == .None, "the test certificate parses as a trust root")
		roots := []^x509.Certificate{&rootc}
		now := time.unix(1893456000, 0) // 2030-01-01, inside the cert's 2020-2040 window

		// The server's signing key.
		priv_bytes := CERT_PRIV
		skey: ecdsa.Private_Key
		want(ecdsa.private_key_set_bytes(&skey, .SECP256R1, priv_bytes[:]), "the certificate's private key sets")

		srec: [1024]u8
		sout: [1024]u8

		// 1) EncryptedExtensions: an empty extension block.
		ee := [?]u8{libtls.HS_ENCRYPTED_EXTENSIONS, 0x00, 0x00, 0x02, 0x00, 0x00}
		libtls.transcript_update(&srv, ee[:])
		sn := libtls.seal_record(&srv.write, libtls.CONTENT_HANDSHAKE, ee[:], srec[:])
		on, _, ook := libtls.open_record(&c.read, srec[:sn], sout[:])
		want(ook && libtls.encrypted_extensions(&c, sout[:on]), "the client opens and accepts EncryptedExtensions")

		// 2) Certificate: one entry, the leaf DER, no per-entry extensions.
		cmsgbuf: [512]u8
		certw := libtls.writer(cmsgbuf[:])
		libtls.w_u8(&certw, libtls.HS_CERTIFICATE)
		cm := libtls.w_open24(&certw)
		libtls.w_u8(&certw, 0) // certificate_request_context, empty
		cl := libtls.w_open24(&certw)
		ce := libtls.w_open24(&certw);libtls.w_bytes(&certw, cert_der[:]);libtls.w_close24(&certw, ce)
		cx := libtls.w_open16(&certw);libtls.w_close16(&certw, cx)
		libtls.w_close24(&certw, cl)
		libtls.w_close24(&certw, cm)
		cert_msg := cmsgbuf[:certw.pos]
		libtls.transcript_update(&srv, cert_msg)
		sn = libtls.seal_record(&srv.write, libtls.CONTENT_HANDSHAKE, cert_msg, srec[:])
		on, _, ook = libtls.open_record(&c.read, srec[:sn], sout[:])
		want(ook && libtls.certificate(&c, sout[:on], roots, now, "", context.allocator), "the client opens the Certificate and verifies the chain to the root")

		// 3) CertificateVerify: the server signs the transcript through Certificate.
		th_cert: [32]u8
		libtls.transcript_snapshot(&srv, th_cert[:])
		cv_content: [64 + len(libtls.CV_CONTEXT_SERVER) + 1 + 32]u8
		libtls.build_cert_verify_content(th_cert[:], cv_content[:])
		cvsig, cvsok := ecdsa.sign_asn1(&skey, .SHA256, cv_content[:], context.allocator, true)
		want(cvsok, "the server signs its CertificateVerify")
		cvbuf: [256]u8
		cvw := libtls.writer(cvbuf[:])
		libtls.w_u8(&cvw, libtls.HS_CERTIFICATE_VERIFY)
		cvm := libtls.w_open24(&cvw)
		libtls.w_u16(&cvw, libtls.SIG_ECDSA_SECP256R1_SHA256)
		cvs := libtls.w_open16(&cvw);libtls.w_bytes(&cvw, cvsig);libtls.w_close16(&cvw, cvs)
		libtls.w_close24(&cvw, cvm)
		cv_msg := cvbuf[:cvw.pos]

		// The mutation check: a second, identically driven client must reject a
		// CertificateVerify whose signature is flipped by a single bit. It stands
		// in for a forged proof of possession -- the guard that makes the whole
		// handshake mean something.
		{
			cn: libtls.Conn
			cnb: [512]u8
			_ = libtls.client_hello(&cn, cpriv, crand, "vectra.test", cnb[:])
			_ = libtls.server_hello(&cn, lsh_msg)
			_ = libtls.encrypted_extensions(&cn, ee[:])
			_ = libtls.certificate(&cn, cert_msg, roots, now, "", context.allocator)
			badcv := cvbuf
			badcv[cvw.pos - 1] ~= 0x01
			want(!libtls.certificate_verify(&cn, badcv[:cvw.pos]) && cn.state == .Failed, "a tampered CertificateVerify signature is refused")
		}

		libtls.transcript_update(&srv, cv_msg)
		sn = libtls.seal_record(&srv.write, libtls.CONTENT_HANDSHAKE, cv_msg, srec[:])
		on, _, ook = libtls.open_record(&c.read, srec[:sn], sout[:])
		want(ook && libtls.certificate_verify(&c, sout[:on]), "the client opens CertificateVerify and the server signature verifies over the live transcript")

		// 4) Server Finished: MAC over the transcript through CertificateVerify.
		th_cv: [32]u8
		libtls.transcript_snapshot(&srv, th_cv[:])
		svd: [32]u8
		libtls.finished_mac(srv.s_hs_secret[:], th_cv[:], svd[:])
		finbuf: [64]u8
		fw := libtls.writer(finbuf[:])
		libtls.w_u8(&fw, libtls.HS_FINISHED)
		fmk := libtls.w_open24(&fw);libtls.w_bytes(&fw, svd[:]);libtls.w_close24(&fw, fmk)
		fin_msg := finbuf[:fw.pos]
		libtls.transcript_update(&srv, fin_msg)
		sn = libtls.seal_record(&srv.write, libtls.CONTENT_HANDSHAKE, fin_msg, srec[:])
		on, _, ook = libtls.open_record(&c.read, srec[:sn], sout[:])
		want(ook && libtls.finished(&c, sout[:on]) && c.state == .Send_Finished, "the client opens the server Finished and its MAC verifies")

		// 5) The client's Finished, sealed under the handshake key and checked by
		// the server, then both ends switch to the application keys.
		cfinbuf: [64]u8
		cfn := libtls.client_finished(&c, cfinbuf[:])
		want(cfn > 0, "the client writes its Finished")
		th_sf: [32]u8
		libtls.transcript_snapshot(&srv, th_sf[:])
		cvd: [32]u8
		libtls.finished_mac(srv.c_hs_secret[:], th_sf[:], cvd[:])
		cfr := libtls.reader(cfinbuf[:cfn])
		_, cfbody, _ := libtls.read_handshake(&cfr)
		want(len(cfbody) == 32 && libtls.slice_eq(cfbody, cvd[:]), "and the server accepts the client Finished MAC")

		libtls.enter_application(&c)
		want(c.state == .Connected, "the client reaches the connected state")

		// The server derives the same application secrets, over the same transcript.
		srv_c_ap: [32]u8
		srv_s_ap: [32]u8
		libtls.derive_secret(srv.secrets.master[:], "c ap traffic", th_sf[:], srv_c_ap[:])
		libtls.derive_secret(srv.secrets.master[:], "s ap traffic", th_sf[:], srv_s_ap[:])
		want(srv_c_ap == c.c_ap_secret && srv_s_ap == c.s_ap_secret, "both ends reach the same application traffic secrets")

		// Application data each way, under the application keys.
		srv_ap_write: libtls.Record_Keys
		libtls.record_keys(&srv_ap_write, srv_s_ap[:])
		srv_ap_read: libtls.Record_Keys
		libtls.record_keys(&srv_ap_read, srv_c_ap[:])
		appmsg := transmute([]u8)string("GET / HTTP/1.1")
		arec: [128]u8
		aout: [128]u8
		an := libtls.seal_record(&srv_ap_write, libtls.CONTENT_APPLICATION_DATA, appmsg, arec[:])
		am, act, aok := libtls.open_record(&c.read, arec[:an], aout[:])
		want(aok && act == libtls.CONTENT_APPLICATION_DATA && string(aout[:am]) == string(appmsg), "server application data opens on the client")
		reply := transmute([]u8)string("HTTP/1.1 200 OK")
		an = libtls.seal_record(&c.write, libtls.CONTENT_APPLICATION_DATA, reply, arec[:])
		am, act, aok = libtls.open_record(&srv_ap_read, arec[:an], aout[:])
		want(aok && act == libtls.CONTENT_APPLICATION_DATA && string(aout[:am]) == string(reply), "and the client's application data opens on the server")

		// A breadcrumb on the console: the kernel's self-test reads this
		// program's exit word, not this stream, so a line here reaches the boot
		// log and says the substrate ran on the machine. A failed `want` above
		// exits before it, so its presence is the on-target pass.
		libuser.write(1, transmute([]u8)string("cryptotest: TLS 1.3 client handshake -- schedule, records, messages, keys, and the authenticated flight ok\n"))
	}

	// -- The TLS 1.3 client transport, against a scripted server ------------
	//
	// The flight test drove the engine's message procs by hand; this drives the
	// whole `libtls.Client` -- the record demultiplexer and handshake state
	// machine -- over an in-memory pipe to a minimal server that fragments its
	// flight the way a real peer's might. It proves the reassembler (a
	// Certificate split across two records), the demux (a change_cipher_spec
	// ignored, one record holding two messages), the key transitions, and
	// application data crossing in both directions. This is the code path
	// `cmd/tlsclient` runs over `/net/tcp`.
	{
		m := new(Mock)
		cert_der := CERT_DER
		priv2 := CERT_PRIV
		m.cert_len = copy(m.cert[:], cert_der[:])
		want(libtls.server_init(&m.srv, m.cert[:m.cert_len], priv2[:]), "the scripted server takes its certificate and key")

		rootc, root_perr := x509.parse(cert_der[:])
		want(root_perr == .None, "the client's trust root parses")
		roots := []^x509.Certificate{&rootc}
		now := time.unix(1893456000, 0)

		cl := new(libtls.Client)
		io := libtls.IO{ctx = m, read = mock_read, write = mock_write}
		libtls.client_init(cl, io, roots, now, "vectra.test")

		dpriv: [32]u8;for i in 0 ..< 32 {dpriv[i] = u8(i + 3)}
		drand: [32]u8;for i in 0 ..< 32 {drand[i] = u8(0x20 + i)}
		want(libtls.client_handshake(cl, dpriv, drand) && cl.conn.state == .Connected, "the client transport completes the handshake against the scripted server")

		req := transmute([]u8)string("GET / HTTP/1.1\r\n\r\n")
		want(libtls.client_write(cl, req), "the client sends application data")
		rbuf: [128]u8
		rn := libtls.client_read(cl, rbuf[:])
		want(rn > 0 && string(rbuf[:rn]) == "hello from the mock server", "and reads the server's application reply")
		want(m.client_fin_ok, "the server accepted the client's Finished MAC")
		want(m.request_len == len(req) && libtls.slice_eq(m.request[:m.request_len], req), "and received the client's request intact")

		libuser.write(1, transmute([]u8)string("cryptotest: TLS 1.3 client transport -- reassembly, demux, and app data over a pipe ok\n"))
	}

	libuser.exits("ok")
}
