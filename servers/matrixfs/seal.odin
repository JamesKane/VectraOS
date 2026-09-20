/*
The seal: `docs/WEB.md` section 8's Olm and Megolm, which every Matrix
client speaks. This device has a Curve25519 identity key, an Ed25519
signing key, and one-time keys, made from /dev/random at login and
uploaded signed, the way the protocol wants them. A room that is
encrypted takes a message out as a Megolm event: this device's outbound
session for the room seals it, and the session's key first goes to each
member's devices as an m.room_key inside an Olm message, sent to each
device from an Olm session made on a one-time key claimed for it. A
Megolm event that comes in opens with the session its key named, which
came the same way, in a to-device event; a session kept is exported
into the store under `keys/matrix/<session_id>`, so it opens history
after a restart. A message whose session this device never had is
served with a body that says so.
*/
package matrixfs

import "core:encoding/json"
import "vsys:abi"
import "vsys:libmsg"
import "vsys:libolm"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

MAX_ONE_TIME :: 8
MAX_OLM :: 8
MAX_MEGOLM_IN :: 16
MAX_MEMBERS :: 16

// This device's keys.
Device :: struct {
	set:        bool,
	identity:   [32]u8, // Curve25519, private
	identity_pub: [32]u8,
	sign:       [32]u8, // Ed25519 seed
	sign_pub:   [32]u8,
	one_time:   [MAX_ONE_TIME][32]u8,
	one_time_pub: [MAX_ONE_TIME][32]u8,
	none_time:  int,
	identity_b64: [48]u8,
	ib64:       int,
	sign_b64:   [48]u8,
	sb64:       int,
}

// An Olm session with one far device, by its identity key.
Olm_Peer :: struct {
	used:    bool,
	curve:   [32]u8, // The far device's Curve25519 key
	session: libolm.Session,
}

// A Megolm session that came in, by its id.
Megolm_In :: struct {
	used:    bool,
	id:      [48]u8, // The session id, the signing key base64
	ilen:    int,
	session: libolm.Inbound,
}

// A room's outbound Megolm session, made when the first message goes.
Megolm_Out :: struct {
	set:     bool,
	session: libolm.Outbound,
	id:      [48]u8,
	ilen:    int,
	shared:  bool, // Its key has gone to the members
}

device: Device
peers: [MAX_OLM]Olm_Peer
megolm_in: [MAX_MEGOLM_IN]Megolm_In
megolm_out: [MAX_ROOMS]Megolm_Out

// -- The device's keys ------------------------------------------------------------

// make_device draws the keys from /dev/random.
make_device :: proc() -> bool {
	if !fill_random(device.identity[:]) || !fill_random(device.sign[:]) {
		return false
	}
	libolm.basepoint(device.identity_pub[:], device.identity[:])
	sk: ed25519_key
	if !ed25519_from_seed(&sk, device.sign[:]) {
		return false
	}
	ed25519_pub(&sk, device.sign_pub[:])
	device.none_time = 0
	for i in 0 ..< MAX_ONE_TIME {
		if !fill_random(device.one_time[i][:]) {
			return false
		}
		libolm.basepoint(device.one_time_pub[i][:], device.one_time[i][:])
		device.none_time += 1
	}
	device.ib64 = libolm.b64_encode(device.identity_pub[:], device.identity_b64[:])
	device.sb64 = libolm.b64_encode(device.sign_pub[:], device.sign_b64[:])
	device.set = true
	return true
}

/*
upload_keys sends the device's keys to the homeserver, signed: the
device keys as one signed object, and each one-time key as another. The
signature is Ed25519 over the object's canonical JSON, its keys in
order and no space between, which is what is built here.
*/
upload_keys :: proc(io: ^libthread.Ioproc) -> bool {
	user := string(account.user[:account.ulen])
	dev := string(account.device[:account.dlen])
	body := make([dynamic]u8, 0, 4096)
	defer delete(body)
	// The device keys, canonical, then signed.
	canon := make([dynamic]u8, 0, 512)
	defer delete(canon)
	put(&canon, "{\"algorithms\":[\"m.olm.v1.curve25519-aes-sha2\",\"m.megolm.v1.aes-sha2\"],\"device_id\":")
	put_json_string(&canon, dev)
	put(&canon, ",\"keys\":{\"curve25519:")
	put(&canon, dev)
	put(&canon, "\":\"")
	put(&canon, string(device.identity_b64[:device.ib64]))
	put(&canon, "\",\"ed25519:")
	put(&canon, dev)
	put(&canon, "\":\"")
	put(&canon, string(device.sign_b64[:device.sb64]))
	put(&canon, "\"},\"user_id\":")
	put_json_string(&canon, user)
	put(&canon, "}")
	sig: [88]u8
	sn := sign_canonical(canon[:], sig[:])
	put(&body, "{\"device_keys\":")
	append(&body, ..canon[:len(canon) - 1])
	put(&body, ",\"signatures\":{")
	put_json_string(&body, user)
	put(&body, ":{\"ed25519:")
	put(&body, dev)
	put(&body, "\":\"")
	put(&body, string(sig[:sn]))
	put(&body, "\"}}},\"one_time_keys\":{")
	for i in 0 ..< device.none_time {
		if i > 0 {
			put(&body, ",")
		}
		kb64: [48]u8
		kn := libolm.b64_encode(device.one_time_pub[i][:], kb64[:])
		clear(&canon)
		put(&canon, "{\"key\":\"")
		put(&canon, string(kb64[:kn]))
		put(&canon, "\"}")
		sn = sign_canonical(canon[:], sig[:])
		put(&body, "\"signed_curve25519:")
		put(&body, one_time_id(i))
		put(&body, "\":{\"key\":\"")
		put(&body, string(kb64[:kn]))
		put(&body, "\",\"signatures\":{")
		put_json_string(&body, user)
		put(&body, ":{\"ed25519:")
		put(&body, dev)
		put(&body, "\":\"")
		put(&body, string(sig[:sn]))
		put(&body, "\"}}}")
	}
	put(&body, "}}")
	url: [BASE_MAX + 64]u8
	text, status, ok := as_account(io, "POST", libuser.cat_into(url[:], string(account.base[:account.blen]), "/_matrix/client/v3/keys/upload"), "Content-Type: application/json\n", string(body[:]))
	delete(text)
	return ok && status == 200
}

// one_time_id names a one-time key: the letters AAAAAA and its number.
one_time_id :: proc "contextless" (i: int) -> string {
	@(static) buf: [8]u8
	copy(buf[:], "AAAAAA")
	buf[5] = u8('A' + i)
	return string(buf[:6])
}

// sign_canonical signs canonical JSON with the device's key, base64.
sign_canonical :: proc(canon: []u8, into: []u8) -> int {
	sk: ed25519_key
	if !ed25519_from_seed(&sk, device.sign[:]) {
		return 0
	}
	sig: [64]u8
	ed25519_sign(&sk, canon, sig[:])
	return libolm.b64_encode(sig[:], into)
}

// -- A message out, sealed --------------------------------------------------------

/*
seal_out seals a room message as a Megolm event's content. The room's
outbound session is made on first use, and its key shared with the
members' devices first, by Olm. Answers the content JSON into `into`.
*/
seal_out :: proc(io: ^libthread.Ioproc, r: ^Room, ri: int, content_json: string, into: ^[dynamic]u8) -> bool {
	mo := &megolm_out[ri]
	if !mo.set {
		seed: [128]u8
		sign_seed: [32]u8
		if !fill_random(seed[:]) || !fill_random(sign_seed[:]) {
			return false
		}
		if !libolm.outbound_init(&mo.session, seed[:], sign_seed[:]) {
			return false
		}
		mo.ilen = libolm.b64_encode(mo.session.pub[:], mo.id[:])
		mo.set = true
		mo.shared = false
	}
	if !mo.shared {
		if !share_room_key(io, r, mo) {
			return false
		}
		mo.shared = true
	}
	// The plaintext: the event, and the room it is for.
	plain := make([dynamic]u8, 0, len(content_json) + 128)
	defer delete(plain)
	put(&plain, "{\"content\":")
	put(&plain, content_json)
	put(&plain, ",\"room_id\":")
	put_json_string(&plain, string(r.id[:r.ilen]))
	put(&plain, ",\"type\":\"m.room.message\"}")
	sealed := make([]u8, len(plain) + 128)
	defer delete(sealed)
	n := libolm.group_encrypt(&mo.session, plain[:], sealed)
	if n <= 0 {
		return false
	}
	b64 := make([]u8, n * 4 / 3 + 8)
	defer delete(b64)
	bn := libolm.b64_encode(sealed[:n], b64)
	put(into, "{\"algorithm\": \"m.megolm.v1.aes-sha2\", \"sender_key\": \"")
	put(into, string(device.identity_b64[:device.ib64]))
	put(into, "\", \"device_id\": ")
	put_json_string(into, string(account.device[:account.dlen]))
	put(into, ", \"session_id\": \"")
	put(into, string(mo.id[:mo.ilen]))
	put(into, "\", \"ciphertext\": \"")
	put(into, string(b64[:bn]))
	put(into, "\"}")
	return true
}

/*
share_room_key sends the room's session key to every member's devices:
their device keys are asked of the server, a one-time key claimed for
each device, an Olm session made on it, and an m.room_key sealed in it
and sent to the device.
*/
share_room_key :: proc(io: ^libthread.Ioproc, r: ^Room, mo: ^Megolm_Out) -> bool {
	base := string(account.base[:account.blen])
	me := string(account.user[:account.ulen])
	// Who to ask for: every member but this user.
	query := make([dynamic]u8, 0, 512)
	defer delete(query)
	put(&query, "{\"device_keys\":{")
	first := true
	for i in 0 ..< r.nmembers {
		member := string(r.members[i][:r.mlen[i]])
		if member == me {
			continue
		}
		if !first {
			put(&query, ",")
		}
		first = false
		put_json_string(&query, member)
		put(&query, ":[]")
	}
	put(&query, "}}")
	if first {
		return true // Nobody else: nothing to share
	}
	url: [BASE_MAX + 64]u8
	text, status, ok := as_account(io, "POST", libuser.cat_into(url[:], base, "/_matrix/client/v3/keys/query"), "Content-Type: application/json\n", string(query[:]))
	defer delete(text)
	if !ok || status != 200 {
		return false
	}
	v, err := json.parse_string(string(text), .JSON)
	defer json.destroy_value(v)
	top, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return false
	}
	users, has_users := libmsg.obj_of(top, "device_keys")
	if !has_users {
		return false
	}
	// The session key, shared as the plaintext of an m.room_key.
	share: [libolm.SHARE_BYTES]u8
	if libolm.session_share(&mo.session, share[:]) != libolm.SHARE_BYTES {
		return false
	}
	share_b64: [320]u8
	shn := libolm.b64_encode(share[:], share_b64[:])
	for user_id, dv in (map[string]json.Value)(users) {
		devices, is_devs := dv.(json.Object)
		if !is_devs {
			continue
		}
		for dev_id, kv in (map[string]json.Value)(devices) {
			keys_obj, is_keys := kv.(json.Object)
			if !is_keys {
				continue
			}
			keys, has_keys := libmsg.obj_of(keys_obj, "keys")
			if !has_keys {
				continue
			}
			curve_b64 := ""
			ed_b64 := ""
			for kname, kval in (map[string]json.Value)(keys) {
				if s, is := kval.(json.String); is {
					if len(kname) > 11 && kname[:11] == "curve25519:" {
						curve_b64 = string(s)
					} else if len(kname) > 8 && kname[:8] == "ed25519:" {
						ed_b64 = string(s)
					}
				}
			}
			if curve_b64 == "" || ed_b64 == "" {
				continue
			}
			if !send_room_key(io, user_id, dev_id, curve_b64, ed_b64, r, mo, string(share_b64[:shn])) {
				return false
			}
		}
	}
	return true
}

// send_room_key claims a one-time key for one device, makes an Olm session
// on it, and sends the room key sealed to the device.
send_room_key :: proc(io: ^libthread.Ioproc, user_id: string, dev_id: string, curve_b64: string, ed_b64: string, r: ^Room, mo: ^Megolm_Out, share_b64: string) -> bool {
	base := string(account.base[:account.blen])
	claim := make([dynamic]u8, 0, 256)
	defer delete(claim)
	put(&claim, "{\"one_time_keys\":{")
	put_json_string(&claim, user_id)
	put(&claim, ":{")
	put_json_string(&claim, dev_id)
	put(&claim, ":\"signed_curve25519\"}}}")
	url: [BASE_MAX + 64]u8
	text, status, ok := as_account(io, "POST", libuser.cat_into(url[:], base, "/_matrix/client/v3/keys/claim"), "Content-Type: application/json\n", string(claim[:]))
	defer delete(text)
	if !ok || status != 200 {
		return false
	}
	// The one-time key: the first key object under the user and device.
	one_time_b64 := ""
	{
		v, err := json.parse_string(string(text), .JSON)
		defer json.destroy_value(v)
		top, is_obj := v.(json.Object)
		if err != .None || !is_obj {
			return false
		}
		otk, has := libmsg.obj_of(top, "one_time_keys")
		if !has {
			return false
		}
		u, has_u := libmsg.obj_of(otk, user_id)
		if !has_u {
			return false
		}
		d, has_d := libmsg.obj_of(u, dev_id)
		if !has_d {
			return false
		}
		for _, kv in (map[string]json.Value)(d) {
			if ko, is := kv.(json.Object); is {
				one_time_b64 = libmsg.str_of(ko, "key")
			}
		}
		if one_time_b64 == "" {
			return false
		}
		@(static) keep: [64]u8
		kn := copy(keep[:], one_time_b64)
		one_time_b64 = string(keep[:kn])
	}
	their_curve: [32]u8
	their_one_time: [32]u8
	if libolm.b64_decode(curve_b64, their_curve[:]) != 32 || libolm.b64_decode(one_time_b64, their_one_time[:]) != 32 {
		return false
	}
	// An Olm session to the device, on fresh keys of our own.
	p := peer_for(their_curve[:])
	if p == nil {
		return false
	}
	base_priv: [32]u8
	ratchet_priv: [32]u8
	if !fill_random(base_priv[:]) || !fill_random(ratchet_priv[:]) {
		return false
	}
	if !libolm.outbound(&p.session, device.identity[:], their_curve[:], their_one_time[:], base_priv[:], ratchet_priv[:]) {
		return false
	}
	p.used = true
	copy(p.curve[:], their_curve[:])
	// The m.room_key, as the Olm plaintext.
	plain := make([dynamic]u8, 0, 1024)
	defer delete(plain)
	put(&plain, "{\"content\":{\"algorithm\":\"m.megolm.v1.aes-sha2\",\"room_id\":")
	put_json_string(&plain, string(r.id[:r.ilen]))
	put(&plain, ",\"session_id\":\"")
	put(&plain, string(mo.id[:mo.ilen]))
	put(&plain, "\",\"session_key\":\"")
	put(&plain, share_b64)
	put(&plain, "\"},\"keys\":{\"ed25519\":\"")
	put(&plain, string(device.sign_b64[:device.sb64]))
	put(&plain, "\"},\"recipient\":")
	put_json_string(&plain, user_id)
	put(&plain, ",\"recipient_keys\":{\"ed25519\":\"")
	put(&plain, ed_b64)
	put(&plain, "\"},\"sender\":")
	put_json_string(&plain, string(account.user[:account.ulen]))
	put(&plain, ",\"sender_device\":")
	put_json_string(&plain, string(account.device[:account.dlen]))
	put(&plain, ",\"type\":\"m.room_key\"}")
	sealed := make([]u8, len(plain) + 512)
	defer delete(sealed)
	n := libolm.encrypt(&p.session, plain[:], sealed, nil)
	if n <= 0 {
		return false
	}
	b64 := make([]u8, n * 4 / 3 + 8)
	defer delete(b64)
	bn := libolm.b64_encode(sealed[:n], b64)
	msg := make([dynamic]u8, 0, bn + 512)
	defer delete(msg)
	put(&msg, "{\"messages\":{")
	put_json_string(&msg, user_id)
	put(&msg, ":{")
	put_json_string(&msg, dev_id)
	put(&msg, ":{\"algorithm\":\"m.olm.v1.curve25519-aes-sha2\",\"sender_key\":\"")
	put(&msg, string(device.identity_b64[:device.ib64]))
	put(&msg, "\",\"ciphertext\":{\"")
	put(&msg, curve_b64)
	put(&msg, "\":{\"type\":0,\"body\":\"")
	put(&msg, string(b64[:bn]))
	put(&msg, "\"}}}}}}")
	account.txn += 1
	num: [24]u8
	text2, status2, ok2 := as_account(io, "PUT", libuser.cat_into(url[:], base, "/_matrix/client/v3/sendToDevice/m.room.encrypted/vectra", libuser.itoa(num[:], i64(account.txn))), "Content-Type: application/json\n", string(msg[:]))
	delete(text2)
	return ok2 && status2 == 200
}

peer_for :: proc(curve: []u8) -> ^Olm_Peer {
	for &p in peers {
		if p.used && string(p.curve[:]) == string(curve) {
			return &p
		}
	}
	for &p in peers {
		if !p.used {
			return &p
		}
	}
	return nil
}

// -- What comes in, sealed ----------------------------------------------------------

/*
take_to_device takes a sync's to-device events: an m.room.encrypted
under Olm for this device's identity key opens with the session it
names, a pre-key message making a new session on the one-time key it
was made for, and an m.room_key inside becomes a Megolm session kept.
*/
take_to_device :: proc(top: json.Object) {
	td, has := libmsg.obj_of(top, "to_device")
	if !has {
		return
	}
	events, has_events := libmsg.arr_of(td, "events")
	if !has_events {
		return
	}
	for ev in events {
		e, is := ev.(json.Object)
		if !is || libmsg.str_of(e, "type") != "m.room.encrypted" {
			continue
		}
		content, has_content := libmsg.obj_of(e, "content")
		if !has_content || libmsg.str_of(content, "algorithm") != "m.olm.v1.curve25519-aes-sha2" {
			continue
		}
		sender_key := libmsg.str_of(content, "sender_key")
		ciphertexts, has_c := libmsg.obj_of(content, "ciphertext")
		if !has_c {
			continue
		}
		mine, for_me := libmsg.obj_of(ciphertexts, string(device.identity_b64[:device.ib64]))
		if !for_me {
			libuser.eprint("matrixfs: a to-device message not for this device's key ", string(device.identity_b64[:device.ib64]), "\n")
			continue
		}
		body := libmsg.str_of(mine, "body")
		kind: i64 = -1
		if tv, has_t := (map[string]json.Value)(mine)["type"]; has_t {
			#partial switch t in tv {
			case json.Integer:
				kind = i64(t)
			case json.Float:
				kind = i64(t)
			}
		}
		if body == "" || kind < 0 {
			continue
		}
		open_to_device(sender_key, body, kind == 0)
	}
}

open_to_device :: proc(sender_key_b64: string, body_b64: string, prekey: bool) {
	their_curve: [32]u8
	if libolm.b64_decode(sender_key_b64, their_curve[:]) != 32 {
		return
	}
	raw := make([]u8, len(body_b64))
	defer delete(raw)
	n := libolm.b64_decode(body_b64, raw)
	if n <= 0 {
		return
	}
	msg := raw[:n]
	p := peer_for(their_curve[:])
	if p == nil {
		return
	}
	if prekey {
		// The one-time key it was made for, by its public half.
		one_time, _, _, _, parsed := libolm.parse_prekey(msg)
		if !parsed {
			return
		}
		which := -1
		for i in 0 ..< device.none_time {
			if string(device.one_time_pub[i][:]) == string(one_time) {
				which = i
				break
			}
		}
		if which < 0 {
			libuser.eprint("matrixfs: a pre-key message on a one-time key this device did not make\n")
			return
		}
		if !libolm.inbound(&p.session, device.identity[:], device.one_time[which][:], msg) {
			libuser.eprint("matrixfs: an Olm session would not begin\n")
			return
		}
		p.used = true
		copy(p.curve[:], their_curve[:])
	} else if !p.used {
		return
	}
	plain := make([]u8, n)
	defer delete(plain)
	pn, ok := libolm.decrypt(&p.session, msg, plain, prekey)
	if !ok {
		libuser.eprint("matrixfs: an Olm message would not open\n")
		return
	}
	v, err := json.parse_string(string(plain[:pn]), .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj || libmsg.str_of(o, "type") != "m.room_key" {
		return
	}
	content, has_content := libmsg.obj_of(o, "content")
	if !has_content || libmsg.str_of(content, "algorithm") != "m.megolm.v1.aes-sha2" {
		return
	}
	keep_room_key(libmsg.str_of(content, "session_id"), libmsg.str_of(content, "session_key"))
	libuser.eprint("matrixfs: a room key came by Olm for session ", libmsg.str_of(content, "session_id"), "\n")
}

// keep_room_key makes an inbound Megolm session of a shared key, under
// its id, and exports it into the store.
keep_room_key :: proc(session_id: string, session_key_b64: string) {
	if session_id == "" || len(session_id) > 47 {
		return
	}
	share := make([]u8, len(session_key_b64))
	defer delete(share)
	n := libolm.b64_decode(session_key_b64, share)
	if n < libolm.EXPORT_BYTES {
		return
	}
	slot: ^Megolm_In
	for &m in megolm_in {
		if m.used && string(m.id[:m.ilen]) == session_id {
			slot = &m
			break
		}
	}
	if slot == nil {
		for &m in megolm_in {
			if !m.used {
				slot = &m
				break
			}
		}
	}
	if slot == nil {
		return
	}
	if !libolm.session_import(&slot.session, share[:n]) {
		libuser.eprint("matrixfs: a room key would not import\n")
		return
	}
	slot.used = true
	slot.ilen = copy(slot.id[:], session_id)
	if store_len > 0 {
		dir: [512]u8
		_ = libuser.mkdir(string(store[:store_len]))
		keys := libuser.cat_into(dir[:], string(store[:store_len]), "/keys")
		_ = libuser.mkdir(keys)
		mdir: [512]u8
		mpath := libuser.cat_into(mdir[:], keys, "/matrix")
		_ = libuser.mkdir(mpath)
		exported: [libolm.EXPORT_BYTES]u8
		_ = libolm.session_export(&slot.session, exported[:])
		path: [640]u8
		name := libuser.cat_into(path[:], mpath, "/", safe_name(session_id))
		_ = libuser.remove(name)
		fd := libuser.create(name, abi.O_WRONLY, 0o600)
		if fd >= 0 {
			_ = libuser.write_full(int(fd), exported[:])
			_ = libuser.close(int(fd))
		}
	}
}

// open_event opens a Megolm room event's content and answers the plain
// event JSON, owned by the caller, or "" with why.
open_event :: proc(content: json.Object) -> (plain: string, why: string) {
	session_id := libmsg.str_of(content, "session_id")
	ciphertext := libmsg.str_of(content, "ciphertext")
	if session_id == "" || ciphertext == "" {
		return "", "(a sealed message with no session named)"
	}
	var: ^Megolm_In
	for &m in megolm_in {
		if m.used && string(m.id[:m.ilen]) == session_id {
			var = &m
			break
		}
	}
	if var == nil {
		return "", "(a sealed message whose key this device never had)"
	}
	raw := make([]u8, len(ciphertext))
	defer delete(raw)
	n := libolm.b64_decode(ciphertext, raw)
	if n <= 0 {
		return "", "(a sealed message that is not base64)"
	}
	out := make([]u8, n)
	pn, _, ok := libolm.group_decrypt(&var.session, raw[:n], out)
	if !ok {
		delete(out)
		return "", "(a sealed message that would not open)"
	}
	return string(out[:pn]), ""
}

// -- Small things ------------------------------------------------------------------

fill_random :: proc(buf: []u8) -> bool {
	fd := libuser.open("/dev/random", abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	n := libuser.read(int(fd), buf)
	_ = libuser.close(int(fd))
	return int(n) == len(buf)
}

_ :: vectra9
