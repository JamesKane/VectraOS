/*
The TLS 1.3 handshake messages, RFC 8446 section 4.

Every handshake message is a one-byte type, a three-byte length, and a body.
This file names the types, the extensions and the code points a client needs,
writes the one message a client sends before it has keys -- the ClientHello --
and reads the one it gets back in the clear -- the ServerHello. The messages
that follow the ServerHello arrive sealed, and their readers sit with the
state machine that has the keys to open them.

A client offers one group and one suite here, because that is all this client
supports: X25519 and TLS_AES_128_GCM_SHA256. Offering one key share and no
others is the common 1-RTT path, and a server that wants a group not offered
answers with a HelloRetryRequest, which `Server_Hello.is_retry` names.
*/
package libtls

// HandshakeType, RFC 8446 section 4.
HS_CLIENT_HELLO :: u8(1)
HS_SERVER_HELLO :: u8(2)
HS_NEW_SESSION_TICKET :: u8(4)
HS_ENCRYPTED_EXTENSIONS :: u8(8)
HS_CERTIFICATE :: u8(11)
HS_CERTIFICATE_REQUEST :: u8(13)
HS_CERTIFICATE_VERIFY :: u8(15)
HS_FINISHED :: u8(20)

// ExtensionType, RFC 8446 section 4.2, and RFC 6066 for server_name.
EXT_SERVER_NAME :: u16(0)
EXT_SUPPORTED_GROUPS :: u16(10)
EXT_SIGNATURE_ALGORITHMS :: u16(13)
EXT_SUPPORTED_VERSIONS :: u16(43)
EXT_KEY_SHARE :: u16(51)

// NamedGroup, cipher suite, versions and the signature schemes a client vouches
// it will verify. X25519 is the one group offered; the suite is the mandatory
// one; the schemes are what a server certificate is signed with today.
GROUP_X25519 :: u16(0x001d)
GROUP_SECP256R1 :: u16(0x0017)

TLS_AES_128_GCM_SHA256 :: u16(0x1301)

VERSION_TLS12 :: u16(0x0303)
VERSION_TLS13 :: u16(0x0304)

SIG_ECDSA_SECP256R1_SHA256 :: u16(0x0403)
SIG_RSA_PSS_RSAE_SHA256 :: u16(0x0804)
SIG_RSA_PSS_RSAE_SHA384 :: u16(0x0805)
SIG_RSA_PKCS1_SHA256 :: u16(0x0401)
SIG_ED25519 :: u16(0x0807)

// HelloRetryRequest is a ServerHello whose random is this fixed value, the
// SHA-256 of "HelloRetryRequest" (RFC 8446 section 4.1.3).
HRR_RANDOM :: [32]u8 {
	0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
	0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c,
}

// read_handshake peels one handshake message off a reader: its type, and its
// body as a subslice. `ok` is false on a truncated message.
read_handshake :: proc(r: ^Reader) -> (msg_type: u8, body: []u8, ok: bool) {
	msg_type = r_u8(r)
	body = r_vec24(r)
	return msg_type, body, !r.err
}

/*
The parts of a ServerHello a client acts on, RFC 8446 section 4.1.3.

`version` is the negotiated version -- 1.3 lives in the supported_versions
extension, and the two legacy version bytes read 1.2 -- and `group`/`key_share`
are the server's half of the key exchange. `random` is kept for the transcript
and for the HelloRetryRequest test `is_retry` reports.
*/
Server_Hello :: struct {
	version:      u16,
	cipher_suite: u16,
	random:       []u8,
	group:        u16,
	key_share:    []u8,
	is_retry:     bool,
}

// parse_server_hello reads a ServerHello body (the bytes after the handshake
// header). `ok` is false on a malformed message.
parse_server_hello :: proc(body: []u8) -> (sh: Server_Hello, ok: bool) {
	r := reader(body)
	legacy_version := r_u16(&r)
	sh.version = legacy_version
	sh.random = r_bytes(&r, 32)
	_ = r_vec8(&r) // legacy_session_id_echo
	sh.cipher_suite = r_u16(&r)
	_ = r_u8(&r) // legacy_compression_method

	exts := r_vec16(&r)
	er := reader(exts)
	for r_remaining(&er) > 0 && !er.err {
		etype := r_u16(&er)
		edata := r_vec16(&er)
		switch etype {
		case EXT_SUPPORTED_VERSIONS:
			// In a ServerHello this carries the single selected version.
			vr := reader(edata)
			sh.version = r_u16(&vr)
		case EXT_KEY_SHARE:
			// KeyShareEntry: group, then a length-prefixed key.
			kr := reader(edata)
			sh.group = r_u16(&kr)
			sh.key_share = r_vec16(&kr)
		}
	}

	if r.err || er.err {
		return sh, false
	}
	if len(sh.random) == 32 {
		hrr := HRR_RANDOM
		sh.is_retry = ([^]u8)(raw_data(sh.random))[0] == hrr[0] && slice_eq(sh.random, hrr[:])
	}
	return sh, true
}

// slice_eq is a constant-length byte compare, kept here so the package needs no
// import for one use.
slice_eq :: proc(a, b: []u8) -> bool #no_bounds_check {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

/*
What a ClientHello carries that this client varies, RFC 8446 section 4.1.2.
`random` is 32 fresh bytes, `key_share` is the client's X25519 public value,
`server_name` is the host for SNI (empty to omit it), and `session_id` is the
legacy session id -- 32 bytes of middlebox-compatibility noise, or empty.
*/
Client_Hello :: struct {
	random:      []u8,
	key_share:   []u8,
	server_name: string,
	session_id:  []u8,
}

// write_client_hello writes a complete ClientHello handshake message (type,
// length and body) into `w`. `w.err` reports a buffer too small.
write_client_hello :: proc(w: ^Writer, ch: Client_Hello) {
	w_u8(w, HS_CLIENT_HELLO)
	hs := w_open24(w)

	w_u16(w, VERSION_TLS12) // legacy_version
	w_bytes(w, ch.random)

	sid := w_open8(w)
	w_bytes(w, ch.session_id)
	w_close8(w, sid)

	// cipher_suites: the one suite this client speaks.
	cs := w_open16(w)
	w_u16(w, TLS_AES_128_GCM_SHA256)
	w_close16(w, cs)

	// legacy_compression_methods: the single null method.
	w_u8(w, 1)
	w_u8(w, 0)

	exts := w_open16(w)
	{
		// supported_versions: the one version, 1.3.
		e := ext_open(w, EXT_SUPPORTED_VERSIONS)
		v := w_open8(w)
		w_u16(w, VERSION_TLS13)
		w_close8(w, v)
		ext_close(w, e)

		// supported_groups: the one group, X25519.
		e = ext_open(w, EXT_SUPPORTED_GROUPS)
		g := w_open16(w)
		w_u16(w, GROUP_X25519)
		w_close16(w, g)
		ext_close(w, e)

		// signature_algorithms: what a certificate may be signed with.
		e = ext_open(w, EXT_SIGNATURE_ALGORITHMS)
		s := w_open16(w)
		w_u16(w, SIG_ECDSA_SECP256R1_SHA256)
		w_u16(w, SIG_RSA_PSS_RSAE_SHA256)
		w_u16(w, SIG_RSA_PSS_RSAE_SHA384)
		w_u16(w, SIG_RSA_PKCS1_SHA256)
		w_u16(w, SIG_ED25519)
		w_close16(w, s)
		ext_close(w, e)

		// key_share: one entry, the client's X25519 public value.
		e = ext_open(w, EXT_KEY_SHARE)
		ks := w_open16(w)
		w_u16(w, GROUP_X25519)
		k := w_open16(w)
		w_bytes(w, ch.key_share)
		w_close16(w, k)
		w_close16(w, ks)
		ext_close(w, e)

		// server_name (SNI), only when a host was given.
		if len(ch.server_name) > 0 {
			e = ext_open(w, EXT_SERVER_NAME)
			list := w_open16(w)
			w_u8(w, 0) // name_type = host_name
			name := w_open16(w)
			w_bytes(w, transmute([]u8)ch.server_name)
			w_close16(w, name)
			w_close16(w, list)
			ext_close(w, e)
		}
	}
	w_close16(w, exts)

	w_close24(w, hs)
}

// ext_open writes an extension type and reserves its data length; ext_close
// back-patches it. The body between is the extension_data.
ext_open :: proc(w: ^Writer, etype: u16) -> int {
	w_u16(w, etype)
	return w_open16(w)
}

ext_close :: proc(w: ^Writer, mark: int) {
	w_close16(w, mark)
}
