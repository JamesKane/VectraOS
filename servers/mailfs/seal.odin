/*
The seal in mail: Autocrypt, `docs/WEB.md` section 6.

Every message out carries the person's public key in an `Autocrypt:`
header. Every message in with one updates `contacts/`, a directory an
address with its name, key, fingerprint and whether it was verified. A
message to contacts that all have a key is sealed: the content goes as a
literal inside version 2 sealed data, the outer message is
`multipart/encrypted` with a placeholder subject, and the real subject
is inside. The person's own key is sealed to as well, so `sent/` reads.
A sealed message in is opened with the session key `factotum` hands
back, and the private key never comes here. The content is signed inside
the seal, by factotum's key, and a sealed message in whose signature does
not verify against the sender's contact key is refused. `seal on` refuses
a message to a contact without a key.
*/
package mailfs

import "vsys:abi"
import "vsys:libcrypto"
import "vsys:libmime"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libpgp"
import "vsys:libuser"

// The person's identity: the key factotum holds, by user and domain, and
// its certificate as fetched.
Identity :: struct {
	set:  bool,
	dom:  [NAME_MAX]u8,
	dlen: int,
	cert: [1024]u8,
	clen: int,
	fpr:  [64]u8, // The primary's fingerprint, hex
}

identity: Identity

// Whether an unsealed message out is refused.
seal_only: bool

// identity_set fetches the certificate factotum holds for the account's
// user in `dom`, and keeps it. False when factotum has no such key.
identity_set :: proc(dom: string) -> bool {
	user := string(account.user[:account.ulen])
	rpc := open_factotum()
	if rpc < 0 {
		return false
	}
	defer _ = libuser.close(rpc)
	ask_buf: [256]u8
	reply := make([]u8, 4096)
	defer delete(reply)
	if rpc_ask(rpc, libuser.cat_into(ask_buf[:], "start openpgp user=", user, " dom=", dom), reply) != "ok" {
		return false
	}
	line := rpc_ask(rpc, "cert", reply)
	if !libodin.has_prefix(line, "cert ") {
		return false
	}
	n := libcrypto.hex_decode(identity.cert[:], line[5:])
	c, ok := libpgp.parse_cert(identity.cert[:max(n, 0)])
	if n <= 0 || !ok {
		return false
	}
	identity.clen = n
	identity.dlen = copy(identity.dom[:], dom)
	libmsg.hex_of(c.primary.fingerprint[:32], identity.fpr[:])
	identity.set = true
	return true
}

// -- Contacts ----------------------------------------------------------------------------

/*
note_autocrypt reads a message's `Autocrypt:` header and keeps the key
it carries under `contacts/<addr>/`: the name the sender gave, the key
armored, its fingerprint, and `verified` as `no`. A key that does not
parse and verify is not kept.
*/
note_autocrypt :: proc(p: ^libmime.Part) {
	value, has := libmime.header(&p.headers, "autocrypt")
	if !has {
		return
	}
	addr_buf: [256]u8
	// `param` reads after a first semicolon, so one is put before the value.
	with_semi := make([]u8, len(value) + 2)
	defer delete(with_semi)
	addr, has_addr := libmime.param(libuser.cat_into(with_semi, "; ", value), "addr", addr_buf[:])
	if !has_addr || len(addr) == 0 {
		return
	}
	key := make([]u8, 4096)
	defer delete(key)
	kd_start := libodin_index(value, "keydata=")
	if kd_start < 0 {
		return
	}
	kd := value[kd_start + len("keydata="):]
	for i in 0 ..< len(kd) {
		if kd[i] == ';' {
			kd = kd[:i]
			break
		}
	}
	n := libpgp.armor_decode(kd, key)
	if n <= 0 {
		return
	}
	c, ok := libpgp.parse_cert(key[:n])
	if !ok || !libpgp.verify_cert(&c) || libpgp.find_subkey(&c, libpgp.ALGO_X25519) == nil {
		return
	}
	name_buf: [256]u8
	name := ""
	if from, has_from := libmime.header(&p.headers, "from"); has_from {
		name, _ = libmime.address(from, name_buf[:])
	}
	armored := make([]u8, 8192)
	defer delete(armored)
	an := libpgp.armor("PGP PUBLIC KEY BLOCK", key[:n], armored)
	fpr: [64]u8
	libmsg.hex_of(c.primary.fingerprint[:32], fpr[:])
	contacts := libmsg.extra(&net, "contacts")
	d := libmsg.xsub(contacts, addr)
	libmsg.xset(d, "name", name)
	libmsg.xset(d, "key", string(armored[:max(an, 0)]))
	libmsg.xset(d, "fingerprint", string(fpr[:]))
	if _, had := libmsg.xget(d, "verified"); !had {
		libmsg.xset(d, "verified", "no")
	}
}

// contact_key answers a contact's X25519 subkey, parsed out of its armored
// key into `cert`, or false when the address has no key here.
contact_key :: proc(addr: string, cert: []u8) -> (c: libpgp.Cert, ok: bool) {
	contacts := libmsg.extra(&net, "contacts")
	d := libmsg.xfind(contacts, addr)
	if d == nil {
		return c, false
	}
	armored, has := libmsg.xget(d, "key")
	if !has {
		return c, false
	}
	n := libpgp.armor_decode(armored, cert)
	if n <= 0 {
		return c, false
	}
	c, ok = libpgp.parse_cert(cert[:n])
	return c, ok && libpgp.find_subkey(&c, libpgp.ALGO_X25519) != nil
}

// -- Sealing out ---------------------------------------------------------------------------

SEAL_BOUNDARY :: "=_vectra_sealed_"

/*
put_autocrypt writes the person's key as an `Autocrypt:` header, folded
at seventy-six columns.
*/
put_autocrypt :: proc(s: ^Send) {
	if !identity.set {
		return
	}
	put(s, "Autocrypt: addr=")
	put(s, string(account.user[:account.ulen]))
	put(s, "@")
	put(s, string(account.server[:account.slen]))
	put(s, "; prefer-encrypt=mutual;\r\n keydata=")
	b64 := make([]u8, identity.clen * 2 + 64)
	defer delete(b64)
	n := libmime.encode_base64(identity.cert[:identity.clen], b64)
	// The encoder breaks lines with CRLF; a header continuation wants a
	// space after each.
	at := 0
	for at < n {
		e := at
		for e < n && b64[e] != '\r' {
			e += 1
		}
		if at > 0 {
			put(s, "\r\n ")
		}
		append(&s.text, ..b64[at:e])
		at = e + 2
	}
	put(s, "\r\n")
}

/*
seal_content replaces the content built for a message with the sealed
form: the content becomes the literal inside sealed data to every
recipient's key and the person's own, and the outer part is
`multipart/encrypted`. False when a recipient has no key, and the
content stays as it was.
*/
seal_content :: proc(s: ^Send, subject: string, content: []u8) -> bool {
	if !identity.set {
		return false
	}
	certs := make([][2048]u8, s.nrcpt + 1)
	defer delete(certs)
	parsed := make([]libpgp.Cert, s.nrcpt + 1)
	defer delete(parsed)
	keys := make([dynamic]^libpgp.Key, 0, s.nrcpt + 1)
	defer delete(keys)
	for i in 0 ..< s.nrcpt {
		c, ok := contact_key(string(s.rcpts[i][:s.rlen[i]]), certs[i][:])
		if !ok {
			return false
		}
		parsed[i] = c
		append(&keys, libpgp.find_subkey(&parsed[i], libpgp.ALGO_X25519))
	}
	own, oown := libpgp.parse_cert(identity.cert[:identity.clen])
	if !oown {
		return false
	}
	parsed[s.nrcpt] = own
	append(&keys, libpgp.find_subkey(&parsed[s.nrcpt], libpgp.ALGO_X25519))

	// The inner message: the subject and the content.
	inner := make([]u8, len(content) + len(subject) + 64)
	defer delete(inner)
	n := 0
	if len(subject) > 0 {
		n += copy(inner[n:], "Subject: ")
		n += copy(inner[n:], subject)
		n += copy(inner[n:], "\r\n")
	}
	n += copy(inner[n:], content)

	rnd: [160]u8
	if !fill_random(rnd[:]) {
		return false
	}
	// Signed inside, by the key factotum holds: the one-pass packet, the
	// literal, and the signature factotum makes over the digest.
	packets := make([]u8, n + 512)
	defer delete(packets)
	salt: [32]u8
	copy(salt[:], rnd[128:160])
	pn := libpgp.put_one_pass(packets, 0, &own.primary, 0, salt[:])
	if pn < 0 {
		return false
	}
	pn = libpgp.put_literal(packets, pn, 'b', inner[:n])
	if pn < 0 {
		return false
	}
	job: libpgp.Sign_Job
	gp: libpgp.Sign_Params
	gp.created = u32(now_seconds())
	gp.salt = salt
	if !libpgp.sign_begin(&job, &own.primary, libpgp.Sign_Input{type = 0, data = inner[:n]}, nil, gp) {
		return false
	}
	sig: [64]u8
	if !factotum_sign(job.digest[:job.dn], sig[:]) {
		return false
	}
	gn := libpgp.sign_finish(&job, sig[:], packets[pn:])
	if gn < 0 {
		return false
	}
	pn += gn
	sp: libpgp.Seal_Params
	copy(sp.ephemeral[:], rnd[:32])
	sp.session = rnd[32:64]
	copy(sp.salt[:], rnd[64:96])
	sp.padding = rnd[96:96 + int(rnd[127] % 24) + 8]
	sp.chunk = 6
	sealed := make([]u8, pn + 256 + 128 * len(keys))
	defer delete(sealed)
	sn := libpgp.seal_packets(keys[:], packets[:pn], sp, sealed)
	if sn < 0 {
		return false
	}
	armored := make([]u8, sn * 2 + 256)
	defer delete(armored)
	an := libpgp.armor("PGP MESSAGE", sealed[:sn], armored)
	if an < 0 {
		return false
	}
	put(s, "Content-Type: multipart/encrypted; protocol=\"application/pgp-encrypted\"; boundary=\"")
	put(s, SEAL_BOUNDARY)
	put(s, "\"\r\n\r\n--")
	put(s, SEAL_BOUNDARY)
	put(s, "\r\nContent-Type: application/pgp-encrypted\r\n\r\nVersion: 1\r\n--")
	put(s, SEAL_BOUNDARY)
	put(s, "\r\nContent-Type: application/octet-stream; name=\"encrypted.asc\"\r\n\r\n")
	append(&s.text, ..armored[:an])
	put(s, "--")
	put(s, SEAL_BOUNDARY)
	put(s, "--\r\n")
	return true
}

// -- Opening in -----------------------------------------------------------------------------

/*
unseal opens a `multipart/encrypted` message: the armored part's session
key packets go to factotum until one opens, the data opens here with the
session key, and the inner message's subject, body and type replace the
outer's. False when it did not open, and the message says so as its body.
*/
unseal :: proc(p: ^libmime.Part, m: ^libmsg.Msg, group: []u8, glen: ^int) -> bool {
	armored := ""
	for &sub in p.parts {
		if sub.type == "application/octet-stream" {
			armored = sub.body
			break
		}
	}
	if len(armored) == 0 {
		return false
	}
	packets := make([]u8, len(armored))
	defer delete(packets)
	n := libpgp.armor_decode(armored, packets)
	if n <= 0 {
		return false
	}
	session: [32]u8
	slen := 0
	rpc := open_factotum()
	if rpc < 0 {
		return false
	}
	ask_buf: [256]u8
	reply := make([]u8, 4096)
	defer delete(reply)
	hexbuf := make([]u8, 1024)
	defer delete(hexbuf)
	started := rpc_ask(rpc, libuser.cat_into(ask_buf[:], "start openpgp user=", string(account.user[:account.ulen]), " dom=", string(identity.dom[:identity.dlen])), reply) == "ok"
	at := 0
	for started {
		pk, after, ok := libpgp.next(packets[:n], at)
		if !ok {
			break
		}
		at = after
		if pk.tag != libpgp.PKESK {
			continue
		}
		if len(pk.body) * 2 + 16 > len(hexbuf) {
			continue
		}
		line := rpc_ask(rpc, libuser.cat_into(reply[:1024], "decrypt ", libcrypto.hex_encode(hexbuf, pk.body)), reply[1024:])
		if libodin.has_prefix(line, "session ") {
			slen = libcrypto.hex_decode(session[:], line[8:])
			if slen > 0 {
				break
			}
		}
	}
	_ = libuser.close(rpc)
	if slen <= 0 {
		return false
	}
	// The data, with the session key.
	at = 0
	for {
		dp, after, ok := libpgp.next(packets[:n], at)
		if !ok {
			return false
		}
		at = after
		if dp.tag != libpgp.SEIPD {
			continue
		}
		seipd, sok := libpgp.parse_seipd(dp)
		if !sok {
			return false
		}
		out := make([]u8, len(dp.body) + 64)
		defer delete(out)
		on := libpgp.open_seipd(&seipd, session[:slen], out)
		if on < 0 {
			return false
		}
		l, sig, signed, lok := libpgp.inner_message(out[:on])
		if !lok {
			return false
		}
		if signed && !signature_holds(&sig, l.data, m.from) {
			m.body = clone("(a sealed message whose signature did not verify)")
			return true
		}
		inner, iok := libmime.parse(string(l.data))
		if !iok {
			return false
		}
		defer libmime.part_free(&inner)
		buf: [512]u8
		if subject, has := libmime.header(&inner.headers, "subject"); has {
			delete(m.subject)
			m.subject = clone(libmime.decode_words(subject, buf[:]))
		}
		if gid, has := libmime.header(&inner.headers, "chat-group-id"); has {
			glen^ = copy(group, libmime.trim(gid))
		}
		body, btype := libmime.text_body(&inner)
		delete(m.body)
		delete(m.type)
		m.body = clone(body)
		m.type = clone(btype != "" ? btype : "text/plain")
		return true
	}
}

/*
signature_holds checks a sealed message's inner signature against its
sender's key: the contact's under `from`'s address, or the person's own
when the sender is the person. A sender with no key here cannot be
checked, and the signature is let stand, unverified.
*/
signature_holds :: proc(sig: ^libpgp.Signature, data: []u8, from: string) -> bool {
	name_buf: [256]u8
	_, box := libmime.address(from, name_buf[:])
	me_buf: [256]u8
	me := libuser.cat_into(me_buf[:], string(account.user[:account.ulen]), "@", string(account.server[:account.slen]))
	cert: [2048]u8
	c: libpgp.Cert
	ok := false
	if box == me && identity.set {
		c, ok = libpgp.parse_cert(identity.cert[:identity.clen])
	} else {
		c, ok = contact_key(box, cert[:])
	}
	if !ok {
		return true
	}
	return libpgp.verify_data(&c.primary, sig, data)
}

// factotum_sign asks factotum for the signature over a digest.
factotum_sign :: proc(digest: []u8, sig: []u8) -> bool {
	rpc := open_factotum()
	if rpc < 0 {
		return false
	}
	defer _ = libuser.close(rpc)
	ask_buf: [256]u8
	reply := make([]u8, 2048)
	defer delete(reply)
	if rpc_ask(rpc, libuser.cat_into(ask_buf[:], "start openpgp user=", string(account.user[:account.ulen]), " dom=", string(identity.dom[:identity.dlen])), reply) != "ok" {
		return false
	}
	hexbuf: [160]u8
	line := rpc_ask(rpc, libuser.cat_into(reply[:512], "sign ", libcrypto.hex_encode(hexbuf[:], digest)), reply[512:])
	if !libodin.has_prefix(line, "sig ") {
		return false
	}
	return libcrypto.hex_decode(sig, line[4:]) == 64
}

// -- factotum -------------------------------------------------------------------------------

open_factotum :: proc() -> int {
	rpc := libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	if rpc < 0 {
		if libuser.mount("/srv/factotum", "/mnt/factotum", 0) < 0 {
			return -1
		}
		rpc = libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	}
	return int(rpc)
}

// rpc_ask writes a line and reads the answer on the same descriptor.
rpc_ask :: proc(rpc: int, line: string, into: []u8) -> string {
	if libuser.write(rpc, transmute([]u8)line) != i64(len(line)) {
		return ""
	}
	n := libuser.read(rpc, into)
	if n <= 0 {
		return ""
	}
	s := string(into[:n])
	for len(s) > 0 && s[len(s) - 1] == '\n' {
		s = s[:len(s) - 1]
	}
	return s
}

libodin_index :: proc "contextless" (s: string, want: string) -> int {
	if len(want) == 0 || len(s) < len(want) {
		return -1
	}
	for i in 0 ..= len(s) - len(want) {
		if s[i:i + len(want)] == want {
			return i
		}
	}
	return -1
}
