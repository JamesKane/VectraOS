/*
The key a passphrase becomes.

`docs/FLEET.md` section 4: a user's private key is derived from a passphrase
with argon2id, salted with the user's name and the fleet's domain, so it lives
nowhere. The same passphrase, name and domain give the same key on any machine
and any day, which is what lets a user sit down at a terminal that has never
seen them. That makes the parameters below a contract: change them and every
key changes. They are modest, because a terminal may be an emulated board.
*/
package libauth

import "core:crypto/argon2id"

KDF_PASSES :: 3
KDF_MEMORY_KIB :: 4096
KDF_LANES :: 1

/*
derive_static writes the X25519 private key for `user` in `dom` from
`passphrase` into `key`, thirty-two bytes. The salt is `user@dom`. It needs an
allocator for argon2id's memory, a few megabytes, and answers false if that
was refused.
*/
derive_static :: proc(key: []u8, passphrase, user, dom: string) -> bool {
	if len(key) != KEY_SIZE || len(user) == 0 || len(dom) == 0 || len(user) + 1 + len(dom) > 128 {
		return false
	}
	salt: [128]u8
	n := copy(salt[:], user)
	salt[n] = '@'
	n += 1
	n += copy(salt[n:], dom)
	params := argon2id.Parameters {
		parallelism = KDF_LANES,
		passes      = KDF_PASSES,
		memory_size = KDF_MEMORY_KIB,
	}
	return argon2id.derive(&params, transmute([]u8)passphrase, salt[:n], key) == nil
}
