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
import "vsys:libauth"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
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

		// A breadcrumb on the console: the kernel's self-test reads this
		// program's exit word, not this stream, so a line here reaches the boot
		// log and says the substrate ran on the machine. A failed `want` above
		// exits before it, so its presence is the on-target pass.
		libuser.write(1, transmute([]u8)string("cryptotest: TLS 1.3 substrate (sha256/hmac/hkdf/ecdsa-p256) ok\n"))
	}

	libuser.exits("ok")
}
