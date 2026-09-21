/*
The key store, sealed under the passphrase: `docs/WEB.md` section 8's
"$home/lib/keys/matrix, sealed under a key derived from the passphrase".
A Megolm session that came in is exported and kept under `keys/matrix/`
in the store, so history opens after a restart. Each file is sealed with
AES-256-GCM under a key `factotum` derives for this identity and a fixed
label, from the noise static key the passphrase became, so a key at rest
is the person's and lives nowhere. A file is a twelve-byte nonce, the
sealed export, and the sixteen-byte tag.

`-i user dom` names the fleet identity the store key is derived for.
Without it, or without `-s`, nothing is written and nothing is loaded,
and the session lives only as long as the server does.
*/
package matrixfs

import "core:crypto/aes"
import "vsys:abi"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libolm"
import "vsys:libuser"

STORE_NONCE :: 12
STORE_TAG :: 16
STORE_SEALED :: STORE_NONCE + libolm.EXPORT_BYTES + STORE_TAG

ident_user: [NAME_MAX]u8
ident_ulen: int
ident_dom: [NAME_MAX]u8
ident_dlen: int
store_key: [32]u8
store_key_set: bool
loaded: int // Sessions loaded from the store at startup

// store_secret asks factotum for the store's key: a labelled secret
// derived from the passphrase, held only while the server runs.
store_secret :: proc() -> bool {
	if store_key_set {
		return true
	}
	if ident_ulen == 0 || ident_dlen == 0 {
		return false
	}
	ask: [256]u8
	hexbuf: [80]u8
	hexs, has := libmsg.factotum_ask(libuser.cat_into(ask[:], "start secret user=", string(ident_user[:ident_ulen]), " dom=", string(ident_dom[:ident_dlen]), " label=matrix"), "secret ", hexbuf[:])
	if !has || len(hexs) != 64 {
		return false
	}
	for i in 0 ..< 32 {
		hi := hex_val(hexs[i * 2])
		lo := hex_val(hexs[i * 2 + 1])
		if hi < 0 || lo < 0 {
			return false
		}
		store_key[i] = u8(hi << 4 | lo)
	}
	store_key_set = true
	return true
}

hex_val :: proc "contextless" (c: u8) -> int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c - 'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

// keep_session writes an inbound session to the store, sealed. `-s` names
// the store; the key must be set, else nothing is kept.
keep_session :: proc(session_id: string, s: ^libolm.Inbound) {
	if store_len == 0 || (!store_key_set && !store_secret()) {
		return
	}
	exported: [libolm.EXPORT_BYTES]u8
	if libolm.session_export(s, exported[:]) != libolm.EXPORT_BYTES {
		return
	}
	sealed: [STORE_SEALED]u8
	if !libuser.read_random(sealed[:STORE_NONCE]) {
		return
	}
	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, store_key[:])
	aes.seal_gcm(&ctx, sealed[STORE_NONCE:STORE_NONCE + libolm.EXPORT_BYTES], sealed[STORE_NONCE + libolm.EXPORT_BYTES:], sealed[:STORE_NONCE], nil, exported[:])
	_ = libmsg.keep_under(string(store[:store_len]), "keys/matrix", safe_name(session_id), sealed[:], 0o600)
}

/*
load_store reads the store's sealed sessions into inbound sessions, so
history opens after a restart. Each is opened with the store key and
imported under its file name, which is the session id. Answers how many.
*/
load_store :: proc() -> int {
	if store_len == 0 || !store_key_set {
		return 0
	}
	dir: [512]u8
	path := libuser.cat_into(dir[:], string(store[:store_len]), "/keys/matrix")
	names, ok := libuser.read_dir(path)
	if !ok {
		return 0
	}
	defer delete(names)
	n := 0
	for name in names {
		if name == "." || name == ".." {
			continue
		}
		full: [640]u8
		fp := libuser.cat_into(full[:], path, "/", name)
		sealed: [STORE_SEALED + 16]u8
		fd := libuser.open(fp, abi.O_RDONLY)
		if fd < 0 {
			continue
		}
		got := libuser.read(int(fd), sealed[:])
		_ = libuser.close(int(fd))
		if int(got) != STORE_SEALED {
			continue
		}
		exported: [libolm.EXPORT_BYTES]u8
		ctx: aes.Context_GCM
		aes.init_gcm(&ctx, store_key[:])
		if !aes.open_gcm(&ctx, exported[:], sealed[:STORE_NONCE], nil, sealed[STORE_NONCE:STORE_NONCE + libolm.EXPORT_BYTES], sealed[STORE_NONCE + libolm.EXPORT_BYTES:STORE_SEALED]) {
			libuser.eprint("matrixfs: a stored session would not open under the key\n")
			continue
		}
		session: libolm.Inbound
		if !libolm.session_import(&session, exported[:]) {
			continue
		}
		// The session's real id is its signing key, the file name made
		// safe having lost the base64 punctuation. Recover it from the key.
		idbuf: [48]u8
		idn := libodin.b64_encode(session.pub_bytes[:], idbuf[:])
		id := string(idbuf[:max(idn, 0)])
		if megolm_by_id(id) != nil {
			continue
		}
		slot: ^Megolm_In
		for &m in megolm_in {
			if !m.used {
				slot = &m
				break
			}
		}
		if slot == nil {
			break
		}
		slot.session = session
		slot.used = true
		slot.ilen = copy(slot.id[:], id)
		n += 1
	}
	return n
}

