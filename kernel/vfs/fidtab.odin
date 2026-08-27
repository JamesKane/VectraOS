/*
A server's fid table.

A fid is a number a client picks and a server binds to a file. Every server
therefore keeps the same map: fid to whatever it calls a file. `static.odin`
opens by saying a second server should not mean a second fid table, and this is
that promise kept. `kernel/devfs` is the second server, and it uses this one.

The table is one allocation. A slot chains to the next by index rather than by
pointer. A slot on the free list and a slot in a bucket are then the same type
in the same array. `next` is that chain in both roles.

What a server binds to a fid is an `i32` and nothing more. A node index in a
table is what both servers presently store. A server with a different idea of a
file stores an index into whatever it keeps instead. The table has no opinion,
which is what lets it be shared.

**Nothing here locks.** A fid table is server state, and the server already has
a lock for the rest of its state. A lock in here would be a second one, taken
in the same place. The caller would still need its own for the fields beside
the table.
*/
package vfs

import "vsys:vectra9"

FID_BUCKETS :: 32

/*
One client fid, bound to one file.

`inuse` is redundant against the bucket chains and is kept because it makes a
slot self-describing. A table walked in a debugger reads without cross-checking
it against four bucket heads.
*/
@(private)
Fid_Slot :: struct {
	fid:   vectra9.Fid,
	node:  i32,
	next:  i32, // Bucket chain when in use, free list when not; -1 ends both
	inuse: bool,

	/*
	Whether the client opened this fid.

	9P draws a hard line here. A fid before Tlopen may be walked and may not be
	read. A fid after it is the reverse. Neither server in this tree enforces
	that yet, and this flag is what a server would enforce it with.

	What uses it today is narrower and is the reason it exists. Some servers hold
	state for as long as a file stays open. At Tclunk, such a server has to know
	whether the fid it releases was one of the open ones. `kernel/devfs` does,
	for `/dev/consctl`.
	*/
	open:  bool,
}

Fid_Table :: struct {
	slots:   []Fid_Slot,
	buckets: [FID_BUCKETS]i32,
	free:    i32,
	live:    int,
}

/*
fidtab_init sizes the table and returns whether the heap had room.

`max_fids` is a real limit, and is meant to be. A fid is a server resource. A
server that grows its table on demand is a server a client can exhaust the
machine's memory through. A server that runs out answers ENFILE, which is the
truth.
*/
fidtab_init :: proc(t: ^Fid_Table, max_fids: int) -> bool #no_bounds_check {
	if t == nil || max_fids <= 0 {
		return false
	}
	t.slots = make([]Fid_Slot, max_fids)
	if t.slots == nil {
		return false
	}

	for i in 0 ..< max_fids {
		t.slots[i].next = i32(i) + 1
	}
	t.slots[max_fids - 1].next = -1
	t.free = 0
	t.live = 0
	for i in 0 ..< FID_BUCKETS {
		t.buckets[i] = -1
	}
	return true
}

fidtab_destroy :: proc(t: ^Fid_Table) {
	if t == nil {
		return
	}
	if t.slots != nil {
		delete(t.slots)
		t.slots = nil
	}
	t.live = 0
	t.free = -1
}

@(private = "file")
fid_hash :: proc "contextless" (fid: vectra9.Fid) -> int {
	return int(u32(fid) % FID_BUCKETS)
}

@(private = "file")
fid_find :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid) -> i32 #no_bounds_check {
	for i := t.buckets[fid_hash(fid)]; i >= 0; i = t.slots[i].next {
		if t.slots[i].fid == fid {
			return i
		}
	}
	return -1
}

/*
fidtab_bind attaches a fid to a node, and rebinds one that already exists.

The rebind is not an edge case. A Twalk whose `newfid` equals its `fid` asks
for exactly that. It is how a client walks a handle forward without spending a
second fid.
*/
fidtab_bind :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid, node: i32) -> bool #no_bounds_check {
	if i := fid_find(t, fid); i >= 0 {
		// A rebind is a fresh binding, so whatever the fid was open on, it is
		// not open on this. 9P forbids the walk that gets here on an open fid.
		// Clearing the flag is what stops a server from believing otherwise if
		// a client ever sends one.
		t.slots[i].node = node
		t.slots[i].open = false
		return true
	}
	if t.free < 0 {
		return false
	}

	i := t.free
	t.free = t.slots[i].next

	b := fid_hash(fid)
	t.slots[i] = Fid_Slot {
		fid   = fid,
		node  = node,
		next  = t.buckets[b],
		inuse = true,
	}
	t.buckets[b] = i
	t.live += 1
	return true
}

// fidtab_node is what a fid is bound to, or -1 when the server never bound it.
// Every handler starts a request with this, and answers EBADF on -1.
fidtab_node :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid) -> i32 #no_bounds_check {
	i := fid_find(t, fid)
	if i < 0 {
		return -1
	}
	return t.slots[i].node
}

// fidtab_set_open records that the client opened this fid, or closed it.
// Reports whether the fid was there to record it against.
fidtab_set_open :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid, open: bool) -> bool #no_bounds_check {
	i := fid_find(t, fid)
	if i < 0 {
		return false
	}
	t.slots[i].open = open
	return true
}

// fidtab_is_open reports whether the client opened this fid. False for a fid
// this table never bound, which is the answer a caller wants either way.
fidtab_is_open :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid) -> bool #no_bounds_check {
	i := fid_find(t, fid)
	return i >= 0 && t.slots[i].open
}

// fidtab_release drops a fid and reports whether it was there. A caller that
// answers Tclunk ignores the answer: the client wanted the fid gone, and it is
// gone either way. Refusing would only ever break a cleanup path.
fidtab_release :: proc "contextless" (t: ^Fid_Table, fid: vectra9.Fid) -> bool #no_bounds_check {
	b := fid_hash(fid)
	prev := i32(-1)
	for i := t.buckets[b]; i >= 0; i = t.slots[i].next {
		if t.slots[i].fid == fid {
			if prev < 0 {
				t.buckets[b] = t.slots[i].next
			} else {
				t.slots[prev].next = t.slots[i].next
			}
			t.slots[i].inuse = false
			t.slots[i].open = false
			t.slots[i].next = t.free
			t.free = i
			t.live -= 1
			return true
		}
		prev = i
	}
	return false
}

// fidtab_live counts the fids a server has out. A self-test that opens and
// closes in balance checks this. A fid the client released and the server kept
// is a leak nothing else reports.
fidtab_live :: proc "contextless" (t: ^Fid_Table) -> int {
	return t == nil ? 0 : t.live
}
