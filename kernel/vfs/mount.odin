/*
The mount table.

The key of a mount point is the file that something mounts **over**:

    key = (server identity, qid.path)

`qid.path` and not the whole qid, because `qid.version` changes whenever a
directory is modified. Keying on the version would unmount `/dev` the moment
somebody created a file in whatever `/dev` was mounted onto.

Each key holds an *ordered list* of members. One member is an ordinary mount.
Several are a union directory, searched in list order:

    bind -a /dev/usb /dev        # after:  /dev then /dev/usb
    bind -b /tmp/bin /bin        # before: /tmp/bin then /bin

    /bin  ---+--> [0] /tmp/bin      searched first
             +--> [1] /bin          searched second

The table lives in the `Namespace`, not in a global. That is the entire point:
two processes looking up the same key get different answers, and neither is
more real than the other.
*/
package vfs

import "kernel:sync"
import "vsys:vectra9"

/*
Thirty-two buckets, chained.

A namespace with more than a few dozen mounts is unusual. Plan 9's are
typically ten to thirty, and a chain of two costs one pointer chase per path
element. This is sized for the common case on purpose. The pathological case
degrades linearly rather than fails.
*/
MOUNT_BUCKETS :: 32

Mount_Order :: enum {
	Replace, // Clear the list and become its only member
	Before, // Push onto the front: searched first
	After, // Push onto the back: searched last
}

// Create marks the member new files are made in. Exactly one member should
// carry it. `union_create_target` says what happens when none does.
Mount_Flag :: enum {
	Create,
}

Mount_Flags :: bit_set[Mount_Flag]

Mount :: struct {
	chan:  ^Chan, // The root of the mounted tree
	flags: Mount_Flags,
	next:  ^Mount,
}

/*
Mount_Point is reference counted, and outlives the table it was filed in.

The table holds one reference. Every `Chan.union_head` holds another. That is
not bookkeeping for its own sake. A chan reached through a union keeps a
pointer to the mount point, so `readdir` can find the other members.

An `unmount` while that chan is alive would otherwise free the object it points
at. `unmount` therefore dissolves rather than deletes. The members go. The
struct stays until the last chan releases it. A chan that holds an empty mount
point behaves like one that was never in a union at all.

The mount point's own lock guards `members`, and the namespace's lock does
not, for the same reason. A chan whose namespace is already gone can still
reach a mount point. A lock reachable only through the namespace is no lock
at all by then.
*/
Mount_Point :: struct {
	server:  ^Server, // Identity half of the key: whose qid.path this is
	path:    u64,
	members: ^Mount,
	refs:    int,

	/*
	Guards `members`, and is Plan 9's `Mhead.lock`: a read/write lock that
	sleeps. A walker reads it for the whole of a union search, one message
	per member. A `bind` or `unmount` writes it, and waits for every search
	in flight.

	This is what `generation` used to stand in for. Vectra's only lock was the
	interrupt flag, so a search could not hold one across a message. A member
	removed from the front of the list mid-search shifted every later member
	under the walker. A counter said whether the list moved, and the walker
	searched again if it did. The mutex made a lock that sleeps
	ordinary, and `kernel/sync/rwlock.odin` made it Plan 9's. The search holds
	the lock now, which is the design the counter was an apology for.
	*/
	lock:    sync.RW_Lock,
	next:    ^Mount_Point, // Hash chain
}

mount_point_incref :: proc(mp: ^Mount_Point) -> ^Mount_Point {
	if mp == nil {
		return nil
	}
	g := sync.acquire(&object_lock)
	mp.refs += 1
	sync.release(&object_lock, g)
	return mp
}

/*
mount_point_release drops a reference and frees the last one.

Whatever drives the count to zero is already unlinked, because the table's own
reference is the one `mount_point_unlink` drops. `members` is therefore nil by
construction here, and there is nothing left to send a message about.
*/
mount_point_release :: proc(mp: ^Mount_Point) {
	if mp == nil {
		return
	}
	g := sync.acquire(&object_lock)
	mp.refs -= 1
	last := mp.refs <= 0
	sync.release(&object_lock, g)
	if last {
		free(mp)
	}
}

@(private)
mount_hash :: proc "contextless" (sv: ^Server, path: u64) -> int {
	// The server pointer is 16-byte aligned at best, so its low bits are dead.
	// Fold it down before the mix, so two servers with adjacent allocations do
	// not collide on every file they serve.
	h := u64(uintptr(rawptr(sv))) >> 4
	h ~= path * 0x9E37_79B9_7F4A_7C15
	h ~= h >> 29
	return int(h % MOUNT_BUCKETS)
}

/*
mount_head finds the mount point a chan is the key of, or nil.

`cross_mounts` calls it once per path element. That is what makes a walk
alternate between the servers it asks and the table it consults. It is also
what lets a single path element cross from one server to another.

**The caller must hold `ns.lock`**, for reading at least. It must not release
that lock before it either finishes with the result or takes a reference to
it. Returning a bare pointer out from under the lock is `mount_head_ref`'s
job.
*/
@(private)
mount_head :: proc "contextless" (ns: ^Namespace, c: ^Chan) -> ^Mount_Point #no_bounds_check {
	if ns == nil || c == nil {
		return nil
	}
	for mp := ns.mounts[mount_hash(c.server, c.qid.path)]; mp != nil; mp = mp.next {
		if mp.server == c.server && mp.path == c.qid.path {
			return mp
		}
	}
	return nil
}

/*
mount_head_ref is `mount_head` for a caller that does not hold the lock.

Returns a counted reference, or nil. The caller releases it with
`mount_point_release`. This is the only way out of the table for anything that
means to keep the pointer.
*/
mount_head_ref :: proc(ns: ^Namespace, c: ^Chan) -> ^Mount_Point {
	if ns == nil {
		return nil
	}
	sync.rlock(&ns.lock)
	defer sync.runlock(&ns.lock)
	return mount_point_incref(mount_head(ns, c))
}

// mount_head_create requires `ns.lock` for writing. The table's own
// reference is the one this hands out.
@(private)
mount_head_create :: proc(ns: ^Namespace, c: ^Chan) -> ^Mount_Point #no_bounds_check {
	if mp := mount_head(ns, c); mp != nil {
		return mp
	}
	mp := new(Mount_Point)
	if mp == nil {
		return nil
	}
	mp.server = c.server
	mp.path = c.qid.path
	mp.refs = 1

	bucket := mount_hash(c.server, c.qid.path)
	mp.next = ns.mounts[bucket]
	ns.mounts[bucket] = mp
	ns.mount_count += 1
	return mp
}

/*
bind makes `source` visible at the name `over` resolved to.

`mount` in Plan 9 is the same operation, and reaches a server through a posted
channel rather than an existing name. Once `/srv` exists it will be a wrapper
around this, and not a second implementation.

Both chans stay the caller's. The table takes its own handles. `source` is
cloned because walks start from the stored member independently.

`over` is cloned because it becomes the `mounted_over` that every chan inside
the mounted tree climbs through on `..`. That lasts as long as any of them
lives, which is longer than the caller's own reference.
*/
bind :: proc(
	ns: ^Namespace,
	source: ^Chan,
	over: ^Chan,
	order: Mount_Order = .Replace,
	flags: Mount_Flags = {},
) -> Errno {
	if ns == nil || source == nil || over == nil {
		return vectra9.EINVAL
	}

	// Mounting a file over a directory, or the reverse, would produce a
	// namespace where the type of a name depends on which member answered.
	if chan_is_dir(source) != chan_is_dir(over) {
		return chan_is_dir(over) ? vectra9.ENOTDIR : vectra9.EISDIR
	}

	member_chan, err := chan_clone(source)
	if err != OK {
		return err
	}

	parent: ^Chan
	parent, err = chan_clone(over)
	if err != OK {
		chan_close(member_chan)
		return err
	}

	// This is what makes `..` work out of the mounted tree. The member is the
	// root of its tree, and the chan something mounted it onto is what lies above
	// it.
	member_chan.tree_root = source.qid
	if member_chan.mounted_over != nil {
		chan_close(member_chan.mounted_over)
	}
	member_chan.mounted_over = parent

	// The member is the root of its own tree, not a member of whatever union
	// `source` was reached through. The clone inherited that reference. Drop it,
	// rather than overwrite the field and lose the count.
	if member_chan.union_head != nil {
		mount_point_release(member_chan.union_head)
		member_chan.union_head = nil
	}

	m := new(Mount)
	if m == nil {
		chan_close(member_chan)
		return vectra9.ENOMEM
	}
	m.chan = member_chan
	m.flags = flags

	/*
	Everything above this point sent messages. Nothing below it does.

	That split is the whole locking discipline in one procedure. The two clones
	are Twalks and cannot happen under a lock, so nothing touches the table until
	both land.

	`.Replace` hands the list it displaces back to the caller's stack, rather than
	frees it here. A member freed here clunks a fid, and that is another message.

	The two locks are `cmount`'s, in `cmount`'s order: the namespace for
	writing, then the mount point for writing. Both sleep, so a walker
	holding the mount point for reading across its search is waited for
	rather than raced.
	*/
	displaced: ^Mount

	sync.wlock(&ns.lock)
	mp := mount_head_create(ns, over)
	if mp == nil {
		sync.wunlock(&ns.lock)
		chan_close(member_chan)
		free(m)
		return vectra9.ENOMEM
	}

	sync.wlock(&mp.lock)
	switch order {
	case .Replace:
		displaced = mp.members
		mp.members = m
	case .Before:
		m.next = mp.members
		mp.members = m
	case .After:
		if mp.members == nil {
			mp.members = m
			break
		}
		tail := mp.members
		for tail.next != nil {
			tail = tail.next
		}
		tail.next = m
	}
	sync.wunlock(&mp.lock)
	sync.wunlock(&ns.lock)

	members_free(displaced)
	return OK
}

/*
unmount removes one member, or the whole mount point when `source` is nil.

The match is by (server, qid.path) rather than by chan identity. The caller
resolved `/dev/usb` again to name what to remove, and got a different `Chan`
than the one the table holds. The qid is the file's permanent identity. The
chan is just a handle on it.
*/
unmount :: proc(ns: ^Namespace, source: ^Chan, over: ^Chan) -> Errno #no_bounds_check {
	if ns == nil || over == nil {
		return vectra9.EINVAL
	}

	// Members leave the list under the lock, and are freed outside it, for the
	// same reason `bind` displaces rather than frees. A member chan closed clunks
	// a fid, and a fid is a message.
	removed: ^Mount
	err := OK

	sync.wlock(&ns.lock)

	mp := mount_head(ns, over)
	if mp != nil {
		sync.wlock(&mp.lock)
	}
	if mp == nil {
		err = vectra9.EINVAL
	} else if source == nil {
		removed = mp.members
		mp.members = nil
	} else {
		tail: ^Mount
		prev: ^Mount
		m := mp.members
		for m != nil {
			next := m.next
			if m.chan.server == source.server && m.chan.qid.path == source.qid.path {
				if prev == nil {
					mp.members = next
				} else {
					prev.next = next
				}
				m.next = nil
				if tail == nil {
					removed = m
				} else {
					tail.next = m
				}
				tail = m
			} else {
				prev = m
			}
			m = next
		}
		if removed == nil {
			err = vectra9.EINVAL
		}
	}

	// An empty mount point leaves the table. It does not necessarily leave
	// memory. A chan reached through it still holds a reference, and finds an
	// empty list. That is exactly what a dissolved union should look like from
	// inside.
	orphaned := false
	if err == OK && mp.members == nil {
		go := sync.acquire(&object_lock)
		orphaned = mount_point_unlink(ns, mp)
		sync.release(&object_lock, go)
	}

	if mp != nil {
		sync.wunlock(&mp.lock)
	}
	sync.wunlock(&ns.lock)

	if orphaned {
		free(mp)
	}
	members_free(removed)
	return err
}

/*
mount_point_unlink takes a mount point out of the table and drops the table's
reference to it. Requires `ns.lock` and `object_lock`.

The count drops inline rather than through `mount_point_release`, which would
take `object_lock` a second time. That is harmless, because it nests.

But the free has to happen outside both locks, and a free here would put a heap
call under the namespace lock for no reason.
*/
@(private)
mount_point_unlink :: proc(ns: ^Namespace, mp: ^Mount_Point) -> (orphaned: bool) #no_bounds_check {
	bucket := mount_hash(mp.server, mp.path)
	prev: ^Mount_Point
	for cur := ns.mounts[bucket]; cur != nil; cur = cur.next {
		if cur == mp {
			if prev == nil {
				ns.mounts[bucket] = cur.next
			} else {
				prev.next = cur.next
			}
			cur.next = nil
			ns.mount_count -= 1
			mp.refs -= 1
			return mp.refs <= 0
		}
		prev = cur
	}
	return false
}

/*
member_ref_at returns a counted reference to the member at `idx`.

**The caller holds `mp.lock` for reading**, across every call and the
message between them. So the list holds still, and an index means the same
member each time. The two callers that walk a union are `walk1_ex` and
`readdir_union`, and both hold it for the whole search. The count is more
than the lock needs. The list cannot lose a member while a reader holds it.
The reference is what lets the walker close the chan after it let go.

`ok` is false past the end. The caller closes what it gets.
*/
@(private)
member_ref_at :: proc(mp: ^Mount_Point, idx: int) -> (c: ^Chan, flags: Mount_Flags, ok: bool) {
	if mp == nil || idx < 0 {
		return nil, {}, false
	}

	i := 0
	for m := mp.members; m != nil; m = m.next {
		if i == idx {
			return chan_incref(m.chan), m.flags, true
		}
		i += 1
	}
	return nil, {}, false
}

/*
members_free closes a list of members that is no longer in any table.

Never called with a lock held: every `chan_close` here may clunk a fid, and a
fid is a message. `bind` and `unmount` both detach first and call this after.
*/
@(private)
members_free :: proc(head: ^Mount) {
	m := head
	for m != nil {
		next := m.next
		chan_close(m.chan)
		free(m)
		m = next
	}
}

/*
mount_point_refs reports how many holders a mount point has.

Introspection for the self-test, and the only direct view of the invariant that
matters. A mount point in a table, with one chan reached through it, has
exactly two references. A dissolve must leave exactly one. The alternative is
to infer it from behaviour after the fact, and that does not work. A
`Mount_Point` freed one reference early still reads as a valid empty one, until
something else claims the block.
*/
mount_point_refs :: proc "contextless" (mp: ^Mount_Point) -> int {
	if mp == nil {
		return 0
	}
	g := sync.acquire(&object_lock)
	defer sync.release(&object_lock, g)
	return mp.refs
}

// member_count reports how many trees a mount point presents as one. One is an
// ordinary mount. More is a union. Zero is a mount point something dissolved
// while a reference remained. See `Mount_Point`.
member_count :: proc "contextless" (mp: ^Mount_Point) -> int {
	if mp == nil {
		return 0
	}
	// The caller holds `mp.lock` for reading, like `member_ref_at`'s.
	n := 0
	for m := mp.members; m != nil; m = m.next {
		n += 1
	}
	return n
}

/*
union_create_target picks the member a new file is made in.

Plan 9's rule, and it has two halves: take the first member flagged `Create`,
and *do not fall through* if creating there fails. The second half is the one
that matters. A fallthrough would put a new file in `/bin` in whichever tree
happened to be writable that day. The caller would have no way to know which.

A create that fails where the namespace chose is a comprehensible error. One
that silently lands elsewhere surfaces weeks later as a file nobody can find.

Nil means no member is flagged, which is EPERM at the call site rather than a
guess. See docs/VECTRA9.md section 7.4.
*/
union_create_target :: proc(mp: ^Mount_Point) -> ^Chan {
	if mp == nil {
		return nil
	}
	sync.rlock(&mp.lock)
	defer sync.runlock(&mp.lock)

	for m := mp.members; m != nil; m = m.next {
		if .Create in m.flags {
			// A counted reference, because the answer outlives the lock and
			// the member could be unbound the instant it is released. The
			// caller closes it.
			return chan_incref(m.chan)
		}
	}
	return nil
}

// -- Binding by name ---------------------------------------------------------

/*
The three of these exist so that no caller has to remember which side of a bind
gets `resolve` and which gets `resolve_mount_point`.

Backwards, it produces a namespace that looks right and is not. The bind
succeeds. The name resolves to the same file it did before. And nothing ever
searches the new member, because it went under a key nothing looks up. An API a
caller can hold wrong, in a way that fails silently, is an API with a bug in
it. So this is the one to reach for.
*/
bind_path :: proc(
	ns: ^Namespace,
	source_path: string,
	target_path: string,
	order: Mount_Order = .Replace,
	flags: Mount_Flags = {},
) -> Errno {
	source, err := resolve(ns, source_path)
	if err != OK {
		return err
	}
	defer chan_close(source)

	over: ^Chan
	over, err = resolve_mount_point(ns, target_path)
	if err != OK {
		return err
	}
	defer chan_close(over)

	return bind(ns, source, over, order, flags)
}

/*
mount_device attaches a `#name` tree and binds it at a path.

The kernel-side half of what `mount` will be once `/srv` exists. It is the same
operation, and reaches the server through the device table rather than a posted
channel.
*/
mount_device :: proc(
	ns: ^Namespace,
	spec: string,
	target_path: string,
	order: Mount_Order = .Replace,
	flags: Mount_Flags = {},
) -> Errno {
	source, err := device_attach(spec)
	if err != OK {
		return err
	}
	defer chan_close(source)

	over: ^Chan
	over, err = resolve_mount_point(ns, target_path)
	if err != OK {
		return err
	}
	defer chan_close(over)

	return bind(ns, source, over, order, flags)
}

// unmount_path removes one member from a mount point, or every member when
// `source_path` is empty.
unmount_path :: proc(ns: ^Namespace, source_path: string, target_path: string) -> Errno {
	over, err := resolve_mount_point(ns, target_path)
	if err != OK {
		return err
	}
	defer chan_close(over)

	if source_path == "" {
		return unmount(ns, nil, over)
	}

	source: ^Chan
	source, err = resolve(ns, source_path)
	if err != OK {
		return err
	}
	defer chan_close(source)

	return unmount(ns, source, over)
}
