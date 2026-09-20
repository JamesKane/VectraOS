/*
olmtest -- `sys/libolm` proven on the machine: docs/WEB.md section 8's
"Olm's and Megolm's published test vectors seal and open through
libolm". Megolm's ratchet is checked against the reference's own known
answers, one step, a jump of 2^24, a jump to 0x1041506, and the wraps
at 2^32. Then a Megolm session seals and opens, in order, out of order,
and not with a byte bent; and an Olm session runs both ways from fixed
keys, a pre-key message first, chains each way, a message out of order
opened with its kept key, and a bent one refused. The word is `ok` or
the first check that did not hold.
*/
package olmtest

import "vsys:abi"
import "vsys:libolm"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.eprint("olmtest: ", what, "\n")
	libuser.exits(what)
}

SEED :: "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"

EXPECTED1 := [128]u8{
	0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,
	0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,
	0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,
	0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,
	0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,
	0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46,
	0xba, 0x9c, 0xd9, 0x55, 0x74, 0x1d, 0x1c, 0x16, 0x23, 0x23, 0xec, 0x82, 0x5e, 0x7c, 0x5c, 0xe8,
	0x89, 0xbb, 0xb4, 0x23, 0xa1, 0x8f, 0x23, 0x82, 0x8f, 0xb2, 0x09, 0x0d, 0x6e, 0x2a, 0xf8, 0x6a,
}
EXPECTED2 := [128]u8{
	0x54, 0x02, 0x2d, 0x7d, 0xc0, 0x29, 0x8e, 0x16, 0x37, 0xe2, 0x1c, 0x97, 0x15, 0x30, 0x92, 0xf9,
	0x33, 0xc0, 0x56, 0xff, 0x74, 0xfe, 0x1b, 0x92, 0x2d, 0x97, 0x1f, 0x24, 0x82, 0xc2, 0x85, 0x9c,
	0x70, 0x04, 0xc0, 0x1e, 0xe4, 0x9b, 0xd6, 0xef, 0xe0, 0x07, 0x35, 0x25, 0xaf, 0x9b, 0x16, 0x32,
	0xc5, 0xbe, 0x72, 0x6d, 0x12, 0x34, 0x9c, 0xc5, 0xbd, 0x47, 0x2b, 0xdc, 0x2d, 0xf6, 0x54, 0x0f,
	0x31, 0x12, 0x59, 0x11, 0x94, 0xfd, 0xa6, 0x17, 0xe5, 0x68, 0xc6, 0x83, 0x10, 0x1e, 0xae, 0xcd,
	0x7e, 0xdd, 0xd6, 0xde, 0x1f, 0xbc, 0x07, 0x67, 0xae, 0x34, 0xda, 0x1a, 0x09, 0xa5, 0x4e, 0xab,
	0xba, 0x9c, 0xd9, 0x55, 0x74, 0x1d, 0x1c, 0x16, 0x23, 0x23, 0xec, 0x82, 0x5e, 0x7c, 0x5c, 0xe8,
	0x89, 0xbb, 0xb4, 0x23, 0xa1, 0x8f, 0x23, 0x82, 0x8f, 0xb2, 0x09, 0x0d, 0x6e, 0x2a, 0xf8, 0x6a,
}
EXPECTED3 := [128]u8{
	0x54, 0x02, 0x2d, 0x7d, 0xc0, 0x29, 0x8e, 0x16, 0x37, 0xe2, 0x1c, 0x97, 0x15, 0x30, 0x92, 0xf9,
	0x33, 0xc0, 0x56, 0xff, 0x74, 0xfe, 0x1b, 0x92, 0x2d, 0x97, 0x1f, 0x24, 0x82, 0xc2, 0x85, 0x9c,
	0x55, 0x58, 0x8d, 0xf5, 0xb7, 0xa4, 0x88, 0x78, 0x42, 0x89, 0x27, 0x86, 0x81, 0x64, 0x58, 0x9f,
	0x36, 0x63, 0x44, 0x7b, 0x51, 0xed, 0xc3, 0x59, 0x5b, 0x03, 0x6c, 0xa6, 0x04, 0xc4, 0x6d, 0xcd,
	0x5c, 0x54, 0x85, 0x0b, 0xfa, 0x98, 0xa1, 0xfd, 0x79, 0xa9, 0xdf, 0x1c, 0xbe, 0x8f, 0xc5, 0x68,
	0x19, 0x37, 0xd3, 0x0c, 0x85, 0xc8, 0xc3, 0x1f, 0x7b, 0xb8, 0x28, 0x81, 0x6c, 0xf9, 0xff, 0x3b,
	0x95, 0x6c, 0xbf, 0x80, 0x7e, 0x65, 0x12, 0x6a, 0x49, 0x55, 0x8d, 0x45, 0xc8, 0x4a, 0x2e, 0x4c,
	0xd5, 0x6f, 0x03, 0xe2, 0x44, 0x16, 0xb9, 0x8e, 0x1c, 0xfd, 0x97, 0xc2, 0x06, 0xaa, 0x90, 0x7a,
}

flat :: proc(m: ^libolm.Ratchet, into: []u8) -> []u8 {
	for j in 0 ..< 4 {
		copy(into[j * 32:], m.data[j][:])
	}
	return into[:128]
}

same :: proc(a, b: []u8) -> bool {
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

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	_ = libuser.args(block)
	seed := transmute([]u8)string(SEED)
	buf: [128]u8

	// -- Megolm's ratchet against the reference's known answers --------------------
	m: libolm.Ratchet
	_ = libolm.ratchet_init(&m, seed, 0)
	libolm.ratchet_advance(&m)
	if m.counter != 1 || !same(flat(&m, buf[:]), EXPECTED1[:]) {
		fail("megolm advance one step")
	}
	_ = libolm.ratchet_init(&m, seed, 0)
	libolm.ratchet_advance_to(&m, 1)
	if m.counter != 1 || !same(flat(&m, buf[:]), EXPECTED1[:]) {
		fail("megolm advance_to one")
	}
	libolm.ratchet_advance_to(&m, 0x1000000)
	if m.counter != 0x1000000 || !same(flat(&m, buf[:]), EXPECTED2[:]) {
		fail("megolm advance_to 2^24")
	}
	libolm.ratchet_advance_to(&m, 0x1041506)
	if m.counter != 0x1041506 || !same(flat(&m, buf[:]), EXPECTED3[:]) {
		fail("megolm advance_to 0x1041506")
	}
	m1, m2: libolm.Ratchet
	_ = libolm.ratchet_init(&m1, seed, 0xffffffff)
	libolm.ratchet_advance_to(&m1, 0x1000000)
	_ = libolm.ratchet_init(&m2, seed, 0)
	libolm.ratchet_advance_to(&m2, 0x2000000)
	buf2: [128]u8
	if m1.counter != 0x1000000 || !same(flat(&m1, buf[:]), flat(&m2, buf2[:])) {
		fail("megolm wraparound")
	}
	_ = libolm.ratchet_init(&m1, seed, 0xffffffff)
	libolm.ratchet_advance_to(&m1, 0)
	_ = libolm.ratchet_init(&m2, seed, 0xffffffff)
	libolm.ratchet_advance(&m2)
	if m1.counter != 0 || m2.counter != 0 || !same(flat(&m1, buf[:]), flat(&m2, buf2[:])) {
		fail("megolm overflow by one")
	}
	_ = libolm.ratchet_init(&m1, seed, 1)
	libolm.ratchet_advance_to(&m1, 0x80000000)
	libolm.ratchet_advance_to(&m1, 0)
	_ = libolm.ratchet_init(&m2, seed, 1)
	libolm.ratchet_advance_to(&m2, 0)
	if m1.counter != 0 || !same(flat(&m1, buf[:]), flat(&m2, buf2[:])) {
		fail("megolm overflow")
	}

	// -- A Megolm session seals and opens ---------------------------------------------
	sign_seed: [32]u8
	for i in 0 ..< 32 {
		sign_seed[i] = u8(i * 7 + 1)
	}
	out: libolm.Outbound
	if !libolm.outbound_init(&out, seed, sign_seed[:]) {
		fail("megolm outbound init")
	}
	shared: [libolm.SHARE_BYTES]u8
	if libolm.session_share(&out, shared[:]) != libolm.SHARE_BYTES {
		fail("megolm session share")
	}
	inb: libolm.Inbound
	if !libolm.session_import(&inb, shared[:]) {
		fail("megolm session import")
	}
	bent := shared
	bent[10] ~= 1
	inb2: libolm.Inbound
	if libolm.session_import(&inb2, bent[:]) {
		fail("megolm a bent share imports")
	}
	msgs: [3][256]u8
	lens: [3]int
	texts := [3]string{"the first", "the second, longer than a block of sixteen", "third"}
	for i in 0 ..< 3 {
		lens[i] = libolm.group_encrypt(&out, transmute([]u8)texts[i], msgs[i][:])
		if lens[i] <= 0 {
			fail("megolm encrypt")
		}
	}
	plain: [256]u8
	n, idx, ok := libolm.group_decrypt(&inb, msgs[2][:lens[2]], plain[:])
	if !ok || idx != 2 || string(plain[:n]) != texts[2] {
		fail("megolm decrypt the third first")
	}
	n, idx, ok = libolm.group_decrypt(&inb, msgs[0][:lens[0]], plain[:])
	if !ok || idx != 0 || string(plain[:n]) != texts[0] {
		fail("megolm decrypt the first after, from the earliest ratchet")
	}
	n, idx, ok = libolm.group_decrypt(&inb, msgs[1][:lens[1]], plain[:])
	if !ok || idx != 1 || string(plain[:n]) != texts[1] {
		fail("megolm decrypt the second")
	}
	msgs[1][lens[1] / 2] ~= 1
	if _, _, bad := libolm.group_decrypt(&inb, msgs[1][:lens[1]], plain[:]); bad {
		fail("megolm a bent message opens")
	}
	exported: [libolm.EXPORT_BYTES]u8
	if libolm.session_export(&inb, exported[:]) != libolm.EXPORT_BYTES || exported[0] != 1 {
		fail("megolm session export")
	}
	inb3: libolm.Inbound
	if !libolm.session_import(&inb3, exported[:]) {
		fail("megolm an export imports")
	}

	// -- An Olm session, both ways ------------------------------------------------------
	alice_id, alice_base, alice_ratchet, bob_id, bob_one_time, bob_ratchet, alice_ratchet2: [32]u8
	for i in 0 ..< 32 {
		alice_id[i] = u8(i + 11)
		alice_base[i] = u8(i * 3 + 5)
		alice_ratchet[i] = u8(i * 5 + 9)
		bob_id[i] = u8(200 - i)
		bob_one_time[i] = u8(i * 13 + 2)
		bob_ratchet[i] = u8(i * 17 + 4)
		alice_ratchet2[i] = u8(i * 19 + 8)
	}
	bob_id_pub, bob_one_time_pub: [32]u8
	libolm_basepoint(bob_id_pub[:], bob_id[:])
	libolm_basepoint(bob_one_time_pub[:], bob_one_time[:])
	alice: libolm.Session
	if !libolm.outbound(&alice, alice_id[:], bob_id_pub[:], bob_one_time_pub[:], alice_base[:], alice_ratchet[:]) {
		fail("olm outbound")
	}
	pre: [512]u8
	pn := libolm.encrypt(&alice, transmute([]u8)string("hello bob"), pre[:], nil)
	if pn <= 0 || pre[0] != 3 || pre[1] != 0x0A {
		fail("olm a pre-key message out")
	}
	bob: libolm.Session
	if !libolm.inbound(&bob, bob_id[:], bob_one_time[:], pre[:pn]) {
		fail("olm inbound from the pre-key message")
	}
	n, ok = libolm.decrypt(&bob, pre[:pn], plain[:], true)
	if !ok || string(plain[:n]) != "hello bob" {
		fail("olm bob opens the pre-key message")
	}
	reply: [512]u8
	rn := libolm.encrypt(&bob, transmute([]u8)string("hello alice"), reply[:], bob_ratchet[:])
	if rn <= 0 || reply[1] != 0x0A || reply[35] == 0x12 {
		fail("olm bob's reply is a compact message on a new chain")
	}
	n, ok = libolm.decrypt(&alice, reply[:rn], plain[:], false)
	if !ok || string(plain[:n]) != "hello alice" {
		fail("olm alice opens the reply, a new receiving chain")
	}
	// Alice sends twice on a new chain of her own; Bob opens them out of order.
	a1, a2: [512]u8
	a1n := libolm.encrypt(&alice, transmute([]u8)string("one"), a1[:], alice_ratchet2[:])
	a2n := libolm.encrypt(&alice, transmute([]u8)string("two"), a2[:], nil)
	if a1n <= 0 || a2n <= 0 || a1[0] != 3 {
		fail("olm alice's compact messages")
	}
	n, ok = libolm.decrypt(&bob, a2[:a2n], plain[:], false)
	if !ok || string(plain[:n]) != "two" {
		fail("olm bob opens the second first")
	}
	n, ok = libolm.decrypt(&bob, a1[:a1n], plain[:], false)
	if !ok || string(plain[:n]) != "one" {
		fail("olm bob opens the first after, with the key kept for it")
	}
	if _, again := libolm.decrypt(&bob, a1[:a1n], plain[:], false); again {
		fail("olm a message opens twice")
	}
	a2[a2n - 3] ~= 1
	if _, bad := libolm.decrypt(&bob, a2[:a2n], plain[:], false); bad {
		fail("olm a bent message opens")
	}
	libuser.eprint("olmtest: Megolm's ratchet matches the reference's answers, a session seals and opens in any order, and Olm runs both ways ok\n")
	libuser.exits("ok")
}

libolm_basepoint :: proc(dst: []u8, scalar: []u8) {
	libolm.basepoint(dst, scalar)
}
