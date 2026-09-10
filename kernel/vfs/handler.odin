/*
What every in-kernel 9P server writes the same way.

Seven servers in this tree answer Twalk with the same loop. They answer Tread
on a rendered text with the same clamp. They open every read and write with
the same two questions about the fid. Each used to carry its own copy. These are the
copies, written once. A server keeps what is its own: how it steps one name,
what qid a node has, and what the text says.
*/
package vfs

import "vsys:vectra9"

/*
read_slice is the part of a Tread answer that does not depend on the file. It
is the window of `data` that a request at `offset` for `count` bytes sees.

Past the end is an empty read, which 9P uses for end of file. The result is a
view into `data`. A server whose text lives on its own stack copies the view
into the reply's buffer. One whose text is static answers with the view.
*/
read_slice :: proc "contextless" (data: []u8, offset: u64, count: u32) -> []u8 #no_bounds_check {
	if offset >= u64(len(data)) {
		return data[:0]
	}
	start := int(offset)
	end := min(len(data), start + int(count))
	return data[start:end]
}

/*
fidtab_open_node answers the two questions a read or a write asks of a fid.

A fid the table does not know is EBADF. One it knows but nobody opened is
EINVAL, which is what a read on an unopened fid earns under 9P2000.L. The
caller holds whatever lock covers the table.
*/
fidtab_open_node :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid) -> (node: i32, err: Errno) {
	node = fidtab_node(t, fid)
	if node < 0 {
		return -1, vectra9.EBADF
	}
	if !fidtab_is_open(t, fid) {
		return node, vectra9.EINVAL
	}
	return node, OK
}

// Walk_Step takes one name from a node and answers the node it names, or -1.
Walk_Step :: #type proc "contextless" (ctx: rawptr, from: i32, name: string) -> i32

// Walk_Qid names a node's qid, for the Rwalk.
Walk_Qid :: #type proc "contextless" (ctx: rawptr, node: i32) -> vectra9.Qid

/*
fidtab_walk answers a Twalk against a table of nodes.

Two rules, and both are silent when got wrong. A partial walk binds nothing,
so `newfid` is untouched when element three of five fails. A failure at element
zero is an error reply, and a failure later is a short Rwalk. That is how a
client tells `the first name is not there` from `the path runs out partway`.
A fid opened for I/O may not walk, which is EBUSY, Plan 9's `Ebadusefd`.

The server supplies `step` and `qid`, and `ctx` is whatever those two need.
The caller holds whatever lock covers the table.
*/
fidtab_walk :: proc "contextless" (
	t: ^Fid_Table,
	m: vectra9.Twalk,
	reply: ^vectra9.Msg,
	ctx: rawptr,
	step: Walk_Step,
	qid: Walk_Qid,
) #no_bounds_check {
	node := fidtab_node(t, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if fidtab_is_open(t, m.fid) {
		reply^ = vectra9.error_reply(vectra9.EBUSY)
		return
	}

	answer: vectra9.Rwalk
	cur := node
	for i in 0 ..< m.count {
		next := step(ctx, cur, m.names[i])
		if next < 0 {
			if i == 0 {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
			break
		}
		cur = next
		answer.qids[answer.count] = qid(ctx, cur)
		answer.count += 1
	}

	if answer.count == m.count {
		if !fidtab_bind(t, m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}
