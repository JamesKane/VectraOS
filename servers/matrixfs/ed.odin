// The Ed25519 the device signs with, over core:crypto.
package matrixfs

import "core:crypto/ed25519"

ed25519_key :: ed25519.Private_Key

ed25519_from_seed :: proc(k: ^ed25519_key, seed: []u8) -> bool {
	return ed25519.private_key_set_bytes(k, seed)
}

ed25519_pub :: proc(k: ^ed25519_key, into: []u8) {
	ed25519.private_key_public_bytes(k, into)
}

ed25519_sign :: proc(k: ^ed25519_key, msg: []u8, sig: []u8) {
	ed25519.sign(k, msg, sig)
}
