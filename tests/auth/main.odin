/*
authtest -- factotum, driven the way a program drives it.

The kernel's self-test starts `factotum`, mounts it at `/mnt/factotum`, and
runs this. Two keys go in through `ctl`: one derived from a passphrase, the
way a user's is, and one given as hex, the way a host's is. The listing that
`ctl` reads back carries each one's public half. Then a handshake runs through
two conversations on `rpc`, one the initiator and one the responder, this
program carrying each message from the one to the other as `sys/libauth` will
carry it across a wire. Both ends come out of it naming the other by its
public key and holding the same two transport keys, the one's sending key the
other's receiving. The word it exits with is `ok`, or the first check that did
not hold.
*/
package authtest

import "vsys:abi"
import "vsys:libcrypto"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
}

// ask writes a line to a message file and reads the reply on the same
// descriptor, as `cs` and `dns` and factotum's files are used.
ask :: proc "contextless" (fd: int, line: string, into: []u8) -> string {
	// A refused write still leaves its reason for the read to find.
	_ = libuser.write(fd, transmute([]u8)line)
	n := libuser.read(fd, into)
	if n <= 0 {
		return ""
	}
	return string(into[:n])
}

// word answers the n-th space-separated word of a line, or "".
word :: proc "contextless" (line: string, n: int) -> string #no_bounds_check {
	at := 0
	i := 0
	for at < len(line) {
		for at < len(line) && line[at] == ' ' {at += 1}
		end := at
		for end < len(line) && line[end] != ' ' && line[end] != '\n' {end += 1}
		if i == n {
			return line[at:end]
		}
		i += 1
		at = end
	}
	return ""
}

// pub_of finds `pub=<hex>` on the listing line for `user` and answers the hex.
pub_of :: proc "contextless" (listing: string, user: string) -> string #no_bounds_check {
	at := 0
	for at < len(listing) {
		end := at
		for end < len(listing) && listing[end] != '\n' {end += 1}
		line := listing[at:end]
		if len(line) > 0 {
			u := word(line, 2)
			if len(u) > 5 && u[5:] == user {
				p := word(line, 4)
				if len(p) > 4 && p[:4] == "pub=" {
					return p[4:]
				}
			}
		}
		at = end + 1
	}
	return ""
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()
	buf: [1024]u8

	// -- Two keys in, and their public halves out --------------------------
	ctl := libuser.open("/mnt/factotum/ctl", abi.O_RDWR)
	want(ctl >= 0, "factotum's ctl opens")
	r := ask(int(ctl), "key proto=noise user=alice dom=test !passphrase=correct horse", buf[:])
	if r != "ok\n" {
		fail(len(r) > 0 ? r : "a key derives from a passphrase: no reply")
	}
	// Bob's private key is given, as a host's is from its key file.
	bobpriv :: "1111111111111111111111111111111111111111111111111111111111111111"
	r = ask(int(ctl), "key proto=noise user=bob dom=test !private=" + bobpriv, buf[:])
	want(r == "ok\n", "and a key is taken as hex")
	want(libuser.write(int(ctl), transmute([]u8)string("key proto=noise user=eve dom=test")) < 0, "a key line with no secret is refused")
	_ = libuser.close(int(ctl))

	lst := libuser.open("/mnt/factotum/ctl", abi.O_RDONLY)
	want(lst >= 0, "ctl opens again to be read")
	n := libuser.read(int(lst), buf[:])
	_ = libuser.close(int(lst))
	want(n > 0, "and lists the keys")
	listing := string(buf[:n])
	alicepub_buf: [64]u8
	bobpub_buf: [64]u8
	alicepub := string(alicepub_buf[:copy(alicepub_buf[:], pub_of(listing, "alice"))])
	bobpub := string(bobpub_buf[:copy(bobpub_buf[:], pub_of(listing, "bob"))])
	want(len(alicepub) == 64 && len(bobpub) == 64, "each with a public key and no secret")
	for i in 0 ..< len(listing) - 10 {
		want(listing[i:i + 10] != "passphrase" && listing[i:i + 7] != "private", "the listing carries no secret")
	}

	// -- A handshake, alice to bob, through two conversations -------------
	a := libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	b := libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	want(a >= 0 && b >= 0, "two rpc conversations open")
	abuf: [1024]u8
	bbuf: [1024]u8
	startline_buf: [256]u8
	sl := libuser.cat_into(startline_buf[:], "start initiator user=alice dom=test remote=", bobpub)
	m1 := ask(int(a), sl, abuf[:])
	want(len(m1) > 4 && m1[:4] == "msg ", "the initiator starts with a first message")
	want(ask(int(b), "start responder user=bob dom=test", bbuf[:]) == "ok", "the responder starts and waits")
	m2 := ask(int(b), m1, bbuf[:])
	want(len(m2) > 4 && m2[:4] == "msg ", "the responder takes it and answers a second")
	da := ask(int(a), m2, abuf[:])
	want(len(da) > 5 && da[:5] == "done ", "the initiator takes that and is done")
	db := ask(int(b), "finish", bbuf[:])
	want(len(db) > 5 && db[:5] == "done ", "and the responder finishes")

	// done <peer> <send> <recv>
	want(word(da, 1) == bobpub, "the initiator names bob by his key")
	want(word(db, 1) == alicepub, "and the responder names alice by hers")
	want(word(da, 2) == word(db, 3) && word(da, 3) == word(db, 2), "and both hold the same transport keys, crossed")
	want(word(da, 2) != word(da, 3), "which are two different keys")
	_ = libuser.close(int(a))
	_ = libuser.close(int(b))

	// -- The wrong far key is refused ---------------------------------------
	c := libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	d := libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	want(c >= 0 && d >= 0, "two more conversations open")
	wrong := libuser.cat_into(startline_buf[:], "start initiator user=alice dom=test remote=", alicepub)
	w1 := ask(int(c), wrong, abuf[:])
	want(len(w1) > 4 && w1[:4] == "msg ", "an initiator aimed at the wrong key still speaks")
	want(ask(int(d), "start responder user=bob dom=test", bbuf[:]) == "ok", "the responder waits")
	want(libuser.write(int(d), transmute([]u8)w1) < 0, "and refuses a first message not meant for it")
	_ = libcrypto.TAG_SIZE
	libuser.exits("ok")
}
