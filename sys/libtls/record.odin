/*
The TLS 1.3 record layer, RFC 8446 sections 5.2 and 5.3.

Once the handshake has keys, every byte either way is an AEAD-sealed record. A
record carries a five-byte header -- a content type the wire always writes as
`application_data`, a legacy version, and a length -- and then the sealed
`TLSInnerPlaintext`: the real content, the real content type as one byte, and
any zero padding. The header is the additional data the seal binds, so a peer
that rewrites a length or a type breaks the tag.

The nonce is the write IV exclusive-ored with the record sequence number, and
the sequence counts up one per record from the moment a key is installed. That
is the whole of the anti-replay: no record number on the wire, because both
ends keep the same count.

This layer holds the direction's keys and its count, and seals or opens one
record at a time. It is `TLS_AES_128_GCM_SHA256`'s AEAD, AES-128-GCM, the
mandatory suite's; a suite with a different one names it in `RECORD_AEAD` and
widens `Record_Keys.key`.
*/
package libtls

import "core:crypto/aead"

// The content types the record layer names, RFC 8446 section 5.
CONTENT_ALERT :: u8(21)
CONTENT_HANDSHAKE :: u8(22)
CONTENT_APPLICATION_DATA :: u8(23)

RECORD_HEADER :: 5
TAG_SIZE :: 16
// TLSInnerPlaintext is at most 2^14 content bytes, one type byte, then padding;
// a record on the wire is at most 2^14 + 256. This bounds a `seal`/`open` call.
MAX_FRAGMENT :: 1 << 14
MAX_INNER :: MAX_FRAGMENT + 256

// TLS_AES_128_GCM_SHA256's AEAD.
RECORD_AEAD :: aead.Algorithm.AES_GCM_128

/*
The write state of one direction, RFC 8446 section 5.3: the key and IV a
traffic secret derives, and the sequence number the nonce counts. A key change
installs a new key and IV and resets the count, which is what `record_keys`
does from a fresh traffic secret.
*/
Record_Keys :: struct {
	key: [16]u8,
	iv:  [12]u8,
	seq: u64,
}

record_keys :: proc(rk: ^Record_Keys, secret: []u8) {
	ki: Key_Iv
	traffic_key_iv(secret, &ki)
	rk.key = ki.key
	rk.iv = ki.iv
	rk.seq = 0
}

// record_nonce is the write IV exclusive-ored with the sequence number, the
// number big-endian in the low eight bytes of the twelve (RFC 8446 s 5.3).
record_nonce :: proc(iv: [12]u8, seq: u64) -> [12]u8 #no_bounds_check {
	nonce := iv
	for i in 0 ..< 8 {
		nonce[11 - i] ~= u8(seq >> uint(8 * i))
	}
	return nonce
}

/*
seal_record writes `content` of type `ctype` into `dst` as one sealed record,
and advances `rk.seq`. `dst` must hold `RECORD_HEADER + len(content) + 1 + pad
+ TAG_SIZE` bytes. Returns the record's length, or -1 when `dst` is too small
or the fragment too large.

The inner plaintext is built in place in `dst`'s payload, then sealed over
itself -- AES-GCM's counter mode reads each byte before it writes the same
position, so the plaintext and ciphertext may be one buffer.
*/
seal_record :: proc(rk: ^Record_Keys, ctype: u8, content: []u8, dst: []u8, pad := 0) -> int #no_bounds_check {
	inner_len := len(content) + 1 + pad
	if inner_len > MAX_INNER {
		return -1
	}
	encrypted_len := inner_len + TAG_SIZE
	if len(dst) < RECORD_HEADER + encrypted_len {
		return -1
	}

	// The header, which is also the additional data the seal binds.
	dst[0] = CONTENT_APPLICATION_DATA
	dst[1] = 0x03
	dst[2] = 0x03
	dst[3] = u8(encrypted_len >> 8)
	dst[4] = u8(encrypted_len)

	// TLSInnerPlaintext = content || real type || zeros(pad), in place.
	payload := dst[RECORD_HEADER:][:inner_len]
	copy(payload, content)
	payload[len(content)] = ctype
	for i in len(content) + 1 ..< inner_len {
		payload[i] = 0
	}

	nonce := record_nonce(rk.iv, rk.seq)
	tag := dst[RECORD_HEADER + inner_len:][:TAG_SIZE]
	aead.seal_oneshot(RECORD_AEAD, payload, tag, rk.key[:], nonce[:], dst[:RECORD_HEADER], payload)
	rk.seq += 1
	return RECORD_HEADER + encrypted_len
}

/*
open_record decrypts one whole record -- header and all -- into `dst`, and
advances `rk.seq`. It returns the real content's length, the real content type,
and whether the tag held. A record whose inner plaintext is all zeros has no
type byte and is refused, as RFC 8446 section 5.4 requires.

`dst` receives only the inner plaintext (at most `len(record) - RECORD_HEADER
- TAG_SIZE` bytes) and may not alias `record`.
*/
open_record :: proc(rk: ^Record_Keys, record: []u8, dst: []u8) -> (n: int, ctype: u8, ok: bool) #no_bounds_check {
	if len(record) < RECORD_HEADER + TAG_SIZE {
		return 0, 0, false
	}
	length := int(record[3]) << 8 | int(record[4])
	if length < TAG_SIZE || len(record) < RECORD_HEADER + length {
		return 0, 0, false
	}
	inner_len := length - TAG_SIZE
	if len(dst) < inner_len {
		return 0, 0, false
	}

	aad := record[:RECORD_HEADER]
	ciphertext := record[RECORD_HEADER:][:inner_len]
	tag := record[RECORD_HEADER + inner_len:][:TAG_SIZE]
	nonce := record_nonce(rk.iv, rk.seq)
	if !aead.open_oneshot(RECORD_AEAD, dst[:inner_len], rk.key[:], nonce[:], aad, ciphertext, tag) {
		return 0, 0, false
	}
	rk.seq += 1

	// Strip the trailing zero padding; the last non-zero byte is the type.
	i := inner_len - 1
	for i >= 0 && dst[i] == 0 {
		i -= 1
	}
	if i < 0 {
		return 0, 0, false
	}
	return i, dst[i], true
}
