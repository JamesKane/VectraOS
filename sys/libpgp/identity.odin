/*
An identity from thirty-two octets: the OpenPGP keys `factotum` derives
from a passphrase and a label, `docs/WEB.md` section 6, so they live
nowhere and a second machine has the same. HKDF takes the material to an
Ed25519 seed and an X25519 scalar, and to the salts the self-signatures
hash, so the certificate is the same octets wherever it is made. The
creation time is derived too, since it is in the fingerprint.
*/
package libpgp

import "core:crypto/ed25519"
import "core:crypto/hkdf"
import "core:crypto/x25519"

Identity :: struct {
	primary:      Key,
	subkey:       Key,
	primary_body: [48]u8, // The public key packets' bodies the keys point into
	subkey_body:  [48]u8,
	ed_seed:      [32]u8,
	x_scalar:     [32]u8,
	cert:         [1024]u8, // The transferable public key
	cert_len:     int,
}

// Between 2020 and 2025 for a creation time: plausible, and derived.
@(private = "file")
EPOCH_2020 :: u32(1577836800)

/*
derive_identity fills `id` from `material`, thirty-two octets a passphrase
became, and writes its certificate: the Ed25519 primary with a direct-key
signature, the X25519 subkey with its binding, both by the primary.
*/
derive_identity :: proc(id: ^Identity, material: []u8) -> bool {
	if len(material) != 32 {
		return false
	}
	hkdf.extract_and_expand(.SHA256, nil, material, transmute([]u8)string("OpenPGP Ed25519 seed"), id.ed_seed[:])
	hkdf.extract_and_expand(.SHA256, nil, material, transmute([]u8)string("OpenPGP X25519 scalar"), id.x_scalar[:])
	id.x_scalar[0] &= 248
	id.x_scalar[31] &= 127
	id.x_scalar[31] |= 64
	when_: [4]u8
	hkdf.extract_and_expand(.SHA256, nil, material, transmute([]u8)string("OpenPGP creation time"), when_[:])
	created := EPOCH_2020 + (u32(when_[0]) << 24 | u32(when_[1]) << 16 | u32(when_[2]) << 8 | u32(when_[3])) % (5 * 365 * 86400)
	salts: [64]u8
	hkdf.extract_and_expand(.SHA256, nil, material, transmute([]u8)string("OpenPGP signature salts"), salts[:])

	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, id.ed_seed[:]) {
		return false
	}
	ed_pub: [32]u8
	ed25519.private_key_public_bytes(&priv, ed_pub[:])
	x_pub: [32]u8
	x25519.scalarmult_basepoint(x_pub[:], id.x_scalar[:])

	put_key_body(id.primary_body[:], created, ALGO_ED25519, ed_pub[:])
	put_key_body(id.subkey_body[:], created, ALGO_X25519, x_pub[:])
	pok, sok: bool
	id.primary, pok = parse_key(Packet{tag = PUBLIC_KEY, body = id.primary_body[:42]})
	id.subkey, sok = parse_key(Packet{tag = PUBLIC_SUBKEY, body = id.subkey_body[:42]})
	if !pok || !sok {
		return false
	}
	id.primary.secret = id.ed_seed[:]
	id.subkey.secret = id.x_scalar[:]

	// The certificate: primary, direct-key signature, subkey, binding.
	at := put_packet(id.cert[:], 0, PUBLIC_KEY, id.primary_body[:42])
	p := Sign_Params{created = created}
	copy(p.salt[:], salts[:32])
	// Key flags certify and sign, the features this reads, and OCB first.
	direct_extra := [?]u8{2, SUB_KEY_FLAGS, 0x03, 2, 30, 0x09, 5, 39, 9, 2, 7, 2}
	job: Sign_Job
	sig: [64]u8
	if !sign_begin(&job, &id.primary, Sign_Input{type = 0x1F, primary = &id.primary}, direct_extra[:], p) || !sign_digest(&job, &id.primary, sig[:]) {
		return false
	}
	sn := sign_finish(&job, sig[:], id.cert[at:])
	if sn < 0 {
		return false
	}
	at += sn
	at = put_packet(id.cert[:], at, PUBLIC_SUBKEY, id.subkey_body[:42])
	copy(p.salt[:], salts[32:])
	bind_extra := [?]u8{2, SUB_KEY_FLAGS, 0x0C}
	if !sign_begin(&job, &id.primary, Sign_Input{type = 0x18, primary = &id.primary, subkey = &id.subkey}, bind_extra[:], p) || !sign_digest(&job, &id.primary, sig[:]) {
		return false
	}
	sn = sign_finish(&job, sig[:], id.cert[at:])
	if sn < 0 {
		return false
	}
	id.cert_len = at + sn
	return true
}

// put_key_body writes a version 6 public key packet's body: forty-two
// octets for a curve key.
@(private = "file")
put_key_body :: proc(out: []u8, created: u32, algo: int, pub: []u8) {
	out[0] = 6
	out[1], out[2], out[3], out[4] = u8(created >> 24), u8(created >> 16), u8(created >> 8), u8(created)
	out[5] = u8(algo)
	out[6], out[7], out[8], out[9] = 0, 0, 0, 32
	copy(out[10:42], pub)
}
