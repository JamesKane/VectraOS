/*
factotum -- the keys a session holds, and the handshakes it runs with them.

`docs/FLEET.md` section 4: a user types a passphrase once, into factotum,
and the private key it becomes lives here and nowhere else. A program that
needs to prove who it is runs the handshake *through* factotum, feeding it
what arrived and sending what it answers, so the program holds no key and the
passphrase never crosses the network. Two files, mounted at `/mnt/factotum`:

    ctl   write: key proto=noise user=glenda dom=home !passphrase=...
          read:  key proto=noise user=glenda dom=home pub=<hex>   (one line each)
    rpc   a conversation per open, the handshake a line at a time

The rpc conversation, hex for every byte string:

    start initiator user=U dom=D remote=<hex pub>   ->  msg <hex>
    msg <hex>                                       ->  done <peer> <send> <recv>

    start responder user=U dom=D                    ->  ok
    msg <hex>                                       ->  msg <hex>
    finish                                          ->  done <peer> <send> <recv>

`done` names the far side by its static public key and hands over the two
transport keys, the initiator's sending key first. Those go to `sys/libauth`,
which seals the stream with them; the static key stays. A write that cannot be
honoured fails with EINVAL and the reason is what the next read says.

Each is a message file, as `/net/cs` is: a write asks, the read that follows
answers, against the fid that asked. The ephemeral key each handshake needs
comes from `/dev/random`.
*/
package factotum

import "base:runtime"

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libauth"
import "vsys:libcrypto"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_CTL :: i32(1)
NODE_RPC :: i32(2)
FRAME :: 1200

MAX_KEYS :: 8
NAME_MAX :: 32

Key :: struct {
	used:  bool,
	user:  [NAME_MAX]u8,
	ulen:  int,
	dom:   [NAME_MAX]u8,
	dlen:  int,
	spriv: [32]u8,
	spub:  [32]u8,
}

keys: [MAX_KEYS]Key

// Why the last `key` line was refused, for the read that follows the write.
key_why: string

// Where a conversation on `rpc` stands.
Stage :: enum u8 {
	Idle,
	Msg1_Sent, // initiator: waiting for msg2
	Msg1_Wait, // responder: waiting for msg1
	Msg2_Sent, // responder: waiting for `finish`
	Done,
}

MAX_CONVS :: 8
REPLY_MAX :: 512

Conv :: struct {
	used:      bool,
	fid:       vectra9.Fid,
	stage:     Stage,
	hs:        libauth.Handshake,
	send:      libauth.Cipher,
	recv:      libauth.Cipher,
	reply:     [REPLY_MAX]u8,
	reply_len: int,
}

convs: [MAX_CONVS]Conv

// The reply to the last write on `ctl`, per fid; and the listing a read of
// `ctl` gives, which is every key's public half.
Ctl_Slot :: struct {
	used:      bool,
	fid:       vectra9.Fid,
	reply:     [REPLY_MAX]u8,
	reply_len: int,
}

ctl_slots: [MAX_CONVS]Ctl_Slot

fids: libuser.Fid_Table
srv: lib9p.Srv

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	fd, perr := libuser.post("/srv/factotum")
	if perr < 0 {
		libthread.threadexitsall("post")
	}
	srv = lib9p.Srv {
		fd      = fd,
		handler = handler,
		msize   = FRAME,
	}
	_, why := lib9p.serve(&srv)
	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

// -- Keys ------------------------------------------------------------------------

key_find :: proc "contextless" (user, dom: string) -> ^Key #no_bounds_check {
	for i in 0 ..< MAX_KEYS {
		k := &keys[i]
		if k.used && string(k.user[:k.ulen]) == user && string(k.dom[:k.dlen]) == dom {
			return k
		}
	}
	return nil
}

/*
key_add takes a `key` line: `proto=noise`, a `user=`, a `dom=`, and either
`!passphrase=` to derive the private key from or `!private=` giving it in
hex, which is how a host's key file is loaded. A key for the same user and
domain replaces the old one. Answers false for a line it cannot make a key of.
*/
key_add :: proc(line: string) -> bool #no_bounds_check {
	user, has_user := attr(line, "user=")
	dom, has_dom := attr(line, "dom=")
	proto, has_proto := attr(line, "proto=")
	if !has_user || !has_dom || !has_proto || proto != "noise" || len(user) > NAME_MAX || len(dom) > NAME_MAX {
		key_why = "error a key wants proto=noise user= dom=\n"
		return false
	}
	spriv: [32]u8
	if pass, has := attr(line, "!passphrase="); has {
		if !libauth.derive_static(spriv[:], pass, user, dom) {
			key_why = "error the key would not derive: no memory for it\n"
			return false
		}
	} else if priv, hasp := attr(line, "!private="); hasp {
		if libcrypto.hex_decode(spriv[:], priv) != 32 {
			key_why = "error !private= wants 64 hex digits\n"
			return false
		}
	} else {
		key_why = "error a key wants !passphrase= or !private=\n"
		return false
	}
	k := key_find(user, dom)
	if k == nil {
		for i in 0 ..< MAX_KEYS {
			if !keys[i].used {
				k = &keys[i]
				break
			}
		}
	}
	if k == nil {
		return false
	}
	k^ = Key{used = true}
	k.ulen = copy(k.user[:], user)
	k.dlen = copy(k.dom[:], dom)
	k.spriv = spriv
	libauth.public_of(k.spub[:], k.spriv[:])
	return true
}

// attr finds `name=value` in a line and answers the value, up to the next
// space or the end.
attr :: proc "contextless" (line: string, name: string) -> (string, bool) #no_bounds_check {
	at := 0
	for at < len(line) {
		// Spaces and newlines both separate words. A line from `echo` ends
		// in a newline, and a scan that stopped at one without stepping
		// over it would never move again.
		for at < len(line) && (line[at] == ' ' || line[at] == '\n' || line[at] == '\t') {at += 1}
		end := at
		for end < len(line) && line[end] != ' ' && line[end] != '\n' && line[end] != '\t' {end += 1}
		if end == at {
			break
		}
		word := line[at:end]
		if len(word) >= len(name) && word[:len(name)] == name {
			return word[len(name):], true
		}
		at = end
	}
	return "", false
}

// key_list writes every key's public line into `into` and answers the text.
key_list :: proc "contextless" (into: []u8) -> string #no_bounds_check {
	sink := libodin.sink_from(into)
	hex: [64]u8
	for i in 0 ..< MAX_KEYS {
		k := &keys[i]
		if !k.used {
			continue
		}
		libodin.put_str(&sink, "key proto=noise user=")
		libodin.put_str(&sink, string(k.user[:k.ulen]))
		libodin.put_str(&sink, " dom=")
		libodin.put_str(&sink, string(k.dom[:k.dlen]))
		libodin.put_str(&sink, " pub=")
		libodin.put_str(&sink, libcrypto.hex_encode(hex[:], k.spub[:]))
		libodin.put_str(&sink, "\n")
	}
	return libodin.str(&sink)
}

// -- The handshake, a line at a time ------------------------------------------------

conv_find :: proc "contextless" (fid: vectra9.Fid) -> ^Conv #no_bounds_check {
	for i in 0 ..< MAX_CONVS {
		if convs[i].used && convs[i].fid == fid {
			return &convs[i]
		}
	}
	return nil
}

conv_new :: proc "contextless" (fid: vectra9.Fid) -> ^Conv #no_bounds_check {
	if c := conv_find(fid); c != nil {
		return c
	}
	for i in 0 ..< MAX_CONVS {
		if !convs[i].used {
			c := &convs[i]
			c^ = Conv{used = true, fid = fid}
			return c
		}
	}
	return nil
}

conv_drop :: proc "contextless" (fid: vectra9.Fid) #no_bounds_check {
	for i in 0 ..< MAX_CONVS {
		if convs[i].used && convs[i].fid == fid {
			convs[i] = Conv{}
		}
	}
}

set_reply :: proc "contextless" (c: ^Conv, text: string) {
	c.reply_len = copy(c.reply[:], text)
}

// fresh_ephemeral draws a private key from `/dev/random`.
fresh_ephemeral :: proc "contextless" (out: []u8) -> bool {
	fd := libuser.open("/dev/random", abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	got := 0
	for got < len(out) {
		n := libuser.read(int(fd), out[got:])
		if n <= 0 {
			break
		}
		got += int(n)
	}
	_ = libuser.close(int(fd))
	return got == len(out)
}

/*
rpc_write takes one line of the conversation and sets what the next read
answers. False is a line the conversation cannot take where it stands, and the
reply then says why.
*/
rpc_write :: proc(c: ^Conv, line: string) -> bool #no_bounds_check {
	l := line
	for len(l) > 0 && (l[len(l) - 1] == '\n' || l[len(l) - 1] == '\r') {
		l = l[:len(l) - 1]
	}
	switch {
	case len(l) > 6 && l[:6] == "start ":
		return rpc_start(c, l[6:])
	case len(l) > 4 && l[:4] == "msg ":
		return rpc_msg(c, l[4:])
	case l == "finish":
		if c.stage != .Msg2_Sent {
			set_reply(c, "error not there yet")
			return false
		}
		finish(c)
		return true
	}
	set_reply(c, "error unknown verb")
	return false
}

rpc_start :: proc(c: ^Conv, rest: string) -> bool #no_bounds_check {
	role := rest
	for i in 0 ..< len(rest) {
		if rest[i] == ' ' {
			role = rest[:i]
			break
		}
	}
	user, has_user := attr(rest, "user=")
	dom, has_dom := attr(rest, "dom=")
	if !has_user || !has_dom {
		set_reply(c, "error user= and dom= wanted")
		return false
	}
	k := key_find(user, dom)
	if k == nil {
		set_reply(c, "error no key for that user")
		return false
	}
	eph: [32]u8
	if !fresh_ephemeral(eph[:]) {
		set_reply(c, "error no entropy")
		return false
	}
	switch role {
	case "initiator":
		remote_hex, has := attr(rest, "remote=")
		remote: [32]u8
		if !has || libcrypto.hex_decode(remote[:], remote_hex) != 32 {
			set_reply(c, "error remote= wanted, 64 hex digits")
			return false
		}
		libauth.init_initiator(&c.hs, k.spriv[:], remote[:], eph[:])
		msg: [libauth.MSG1_MAX]u8
		n := libauth.write_msg1(&c.hs, msg[:], nil)
		hex: [2 * libauth.MSG1_MAX]u8
		sink := libodin.sink_from(c.reply[:])
		libodin.put_str(&sink, "msg ")
		libodin.put_str(&sink, libcrypto.hex_encode(hex[:], msg[:n]))
		c.reply_len = len(libodin.str(&sink))
		c.stage = .Msg1_Sent
		return true
	case "responder":
		libauth.init_responder(&c.hs, k.spriv[:], eph[:])
		set_reply(c, "ok")
		c.stage = .Msg1_Wait
		return true
	}
	set_reply(c, "error role is initiator or responder")
	return false
}

rpc_msg :: proc(c: ^Conv, hex: string) -> bool #no_bounds_check {
	raw: [libauth.MSG1_MAX]u8
	n := libcrypto.hex_decode(raw[:], hex)
	if n < 0 {
		set_reply(c, "error not hex")
		return false
	}
	payload: [64]u8
	switch c.stage {
	case .Msg1_Sent:
		if _, ok := libauth.read_msg2(&c.hs, raw[:n], payload[:]); !ok {
			set_reply(c, "error the reply did not verify")
			return false
		}
		finish(c)
		return true
	case .Msg1_Wait:
		if _, ok := libauth.read_msg1(&c.hs, raw[:n], payload[:]); !ok {
			set_reply(c, "error the first message did not verify")
			return false
		}
		out: [libauth.MSG2_MAX]u8
		m := libauth.write_msg2(&c.hs, out[:], nil)
		ohex: [2 * libauth.MSG2_MAX]u8
		sink := libodin.sink_from(c.reply[:])
		libodin.put_str(&sink, "msg ")
		libodin.put_str(&sink, libcrypto.hex_encode(ohex[:], out[:m]))
		c.reply_len = len(libodin.str(&sink))
		c.stage = .Msg2_Sent
		return true
	case .Idle, .Msg2_Sent, .Done:
	}
	set_reply(c, "error no message is wanted now")
	return false
}

// finish splits the handshake and writes the `done` line: the far static key
// and the two transport keys, initiator's sending key first.
finish :: proc(c: ^Conv) #no_bounds_check {
	c.send, c.recv = libauth.split(&c.hs)
	hex: [64]u8
	sink := libodin.sink_from(c.reply[:])
	libodin.put_str(&sink, "done ")
	libodin.put_str(&sink, libcrypto.hex_encode(hex[:], c.hs.rs[:]))
	libodin.put_str(&sink, " ")
	libodin.put_str(&sink, libcrypto.hex_encode(hex[:], c.send.k[:]))
	libodin.put_str(&sink, " ")
	libodin.put_str(&sink, libcrypto.hex_encode(hex[:], c.recv.k[:]))
	c.reply_len = len(libodin.str(&sink))
	c.stage = .Done
	// The handshake state, with the static key it was seeded from, is done with.
	c.hs = {}
}

// -- ctl replies, per fid ------------------------------------------------------

ctl_slot :: proc "contextless" (fid: vectra9.Fid) -> ^Ctl_Slot #no_bounds_check {
	for i in 0 ..< MAX_CONVS {
		if ctl_slots[i].used && ctl_slots[i].fid == fid {
			return &ctl_slots[i]
		}
	}
	for i in 0 ..< MAX_CONVS {
		if !ctl_slots[i].used {
			s := &ctl_slots[i]
			s^ = Ctl_Slot{used = true, fid = fid}
			return s
		}
	}
	return nil
}

ctl_drop :: proc "contextless" (fid: vectra9.Fid) #no_bounds_check {
	for i in 0 ..< MAX_CONVS {
		if ctl_slots[i].used && ctl_slots[i].fid == fid {
			ctl_slots[i] = Ctl_Slot{}
		}
	}
}

// -- 9P ---------------------------------------------------------------------------

is_dir :: proc "contextless" (node: i32) -> bool {
	return node == NODE_ROOT
}

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if is_dir(node) {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	if from != NODE_ROOT {
		return -1
	}
	switch name {
	case ".", "..":
		return NODE_ROOT
	case "ctl":
		return NODE_CTL
	case "rpc":
		return NODE_RPC
	}
	return -1
}

handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state
	_ = s
	_ = tag
	if !libuser.default_reply(request, reply) {
		return
	}
	context = libuser.heap_context()
	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)
	case vectra9.Tattach:
		libuser.attach(&fids, m, reply, NODE_ROOT, qid_of)
	case vectra9.Twalk:
		libuser.walk(&fids, m, reply, step, qid_of)
	case vectra9.Tlopen:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		libuser.fid_open(&fids, m.fid)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}
	case vectra9.Tread:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		text: string
		switch node {
		case NODE_CTL:
			// A write's reply if one is waiting, else the key listing. The
			// listing honours the offset, as a file does; a reply is whole.
			if sl := ctl_slot(m.fid); sl != nil && sl.reply_len > 0 {
				text = string(sl.reply[:sl.reply_len])
				sl.reply_len = 0
			} else {
				all := key_list(buf)
				if int(m.offset) >= len(all) {
					reply^ = vectra9.Rread{data = nil}
					return
				}
				text = all[m.offset:]
			}
		case NODE_RPC:
			c := conv_find(m.fid)
			if c == nil {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			text = string(c.reply[:c.reply_len])
			c.reply_len = 0
		case:
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		room := min(min(len(buf), int(m.count)), len(text))
		copy(buf[:room], text[:room])
		reply^ = vectra9.Rread{data = buf[:room]}
	case vectra9.Twrite:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		switch node {
		case NODE_CTL:
			line := string(m.data)
			key_why = "error a line here begins with `key`\n"
			ok2 := len(line) > 4 && line[:4] == "key " && key_add(line[4:])
			if sl := ctl_slot(m.fid); sl != nil {
				sl.reply_len = copy(sl.reply[:], ok2 ? "ok\n" : key_why)
			}
			if !ok2 {
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
		case NODE_RPC:
			c := conv_new(m.fid)
			if c == nil {
				reply^ = vectra9.error_reply(vectra9.ENFILE)
				return
			}
			if !rpc_write(c, string(m.data)) {
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
		case:
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}
	case vectra9.Treaddir:
		readdir(m, reply, buf)
	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := is_dir(node)
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100666,
			nlink   = dir ? 2 : 1,
			blksize = 512,
		}
	case vectra9.Tclunk:
		conv_drop(m.fid)
		ctl_drop(m.fid)
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rclunk{}
	case vectra9.Tremove:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}
	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	if !is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	names := [?]string{"ctl", "rpc"}
	nodes := [?]i32{NODE_CTL, NODE_RPC}
	for i in 0 ..< len(names) {
		if m.offset >= u64(i + 1) {
			continue
		}
		if vectra9.remaining(&c) < vectra9.dirent_size(names[i]) {
			break
		}
		vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(nodes[i]), offset = u64(i + 1), type = vectra9.DT_REG, name = names[i]})
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
